package agg

import (
	"sync"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
)

type TokenCounts struct {
	In, Out, CacheCreate, CacheRead uint64
}

func (a TokenCounts) Add(b TokenCounts) TokenCounts {
	return TokenCounts{
		In:          a.In + b.In,
		Out:         a.Out + b.Out,
		CacheCreate: a.CacheCreate + b.CacheCreate,
		CacheRead:   a.CacheRead + b.CacheRead,
	}
}

func (a TokenCounts) ToUsage() pricing.Usage {
	return pricing.Usage{
		InputTokens:              a.In,
		OutputTokens:             a.Out,
		CacheCreationInputTokens: a.CacheCreate,
		CacheReadInputTokens:     a.CacheRead,
	}
}

// ModelDay holds aggregated tokens for a (day or month, series) cell
// plus the cost computed once at snapshot time from those tokens.
// Storing tokens (uint64) and computing cost only at snapshot avoids
// per-event float64 accumulation drift over many thousands of events.
type ModelDay struct {
	USD    float64
	Tokens TokenCounts
}

// ProjectDay holds the per-project breakdown with main vs subagent
// tokens kept separate so the UI can show their split.
type ProjectDay struct {
	Main    TokenCounts
	Sub     TokenCounts
	MainUSD float64
	SubUSD  float64
}

// USD returns total cost (main + subagent).
func (p ProjectDay) USD() float64 { return p.MainUSD + p.SubUSD }

// Tokens returns total tokens (main + subagent).
func (p ProjectDay) Tokens() TokenCounts { return p.Main.Add(p.Sub) }

// DailyTotal is one day's aggregate cost AND token usage across all
// models/projects. Used for both the daily-spend sparkline and the
// token-volume sparkline in the minimal/split views.
type DailyTotal struct {
	Day    string // YYYY-MM-DD in local time
	USD    float64
	Tokens uint64 // sum of input + output + cacheCreate + cacheRead
}

// SeriesKey identifies one chartable series. Source and Vendor are both
// stored rather than Vendor being derived from Source at snapshot time:
// the macapp persists cells between runs, so a label removed from the
// config would otherwise leave its cached cells unattributable.
type SeriesKey struct {
	Source string // "vendor/label"
	Vendor string
	Model  string
}

// PartialCoverageThreshold is the usage-bearing fraction below which a
// vendor's figures are presented as a floor rather than a total.
const PartialCoverageThreshold = 0.95

// Coverage is how much of a vendor's activity carried usable usage data.
// Grok added its usage object to turn_completed only recently, so an old
// month's total is a fraction of the truth while looking exactly as
// authoritative as a correct one. This is what lets the UI say so.
type Coverage struct {
	Turns     int // turns seen
	WithUsage int // turns that carried usage
}

// Fraction returns the usage-bearing share. A vendor that reported no
// turns at all is complete by definition, not 0% — Claude emits no
// coverage events and must never render as a partial figure.
func (c Coverage) Fraction() float64 {
	if c.Turns == 0 {
		return 1
	}
	return float64(c.WithUsage) / float64(c.Turns)
}

func (c Coverage) Partial() bool { return c.Fraction() < PartialCoverageThreshold }

type Totals struct {
	Day       map[SeriesKey]ModelDay // series (source, vendor, model) -> totals for today
	Month     map[SeriesKey]ModelDay // series (source, vendor, model) -> totals for this month
	DayProj   map[string]ProjectDay  // project -> totals for today
	MonthProj map[string]ProjectDay  // project -> totals for this month
	Daily     []DailyTotal           // last N days (ascending), N set by Snapshot caller via DailyWindow
	Unknown   int                    // distinct unpriced message ids
	Dupes     int                    // events skipped as msgid:reqid duplicates
	// Coverage is keyed by vendor and scoped to the current month, the
	// same scope as Month.
	Coverage map[string]Coverage
	AsOf     time.Time
}

type civilDay struct {
	Y int
	M time.Month
	D int
}

func dayOf(t time.Time) civilDay {
	lt := t.Local()
	return civilDay{lt.Year(), lt.Month(), lt.Day()}
}

// cellKey identifies one storage cell: a (day, project, source, vendor,
// model, isSub) bucket of token counts. Cost is derived from these at
// snapshot time.
type cellKey struct {
	Day     civilDay
	Project string
	Source  string
	Vendor  string
	Model   string
	IsSub   bool
}

// covKey scopes a coverage tally to a (day, vendor) so Snapshot can
// restrict it to the displayed month rather than the whole scan range.
type covKey struct {
	Day    civilDay
	Vendor string
}

// cellVal is one cell's accumulated contribution. Tokens is everything
// the cell saw and drives the token charts. The dollar side is split in
// two because a cell may hold both kinds of contribution: CostedUSD is
// summed as-is from vendor-reported figures, PricedTokens is the subset
// that must go through the pricing table at snapshot time.
//
// Keeping them separate rather than branching on "is this series costed"
// matters for the per-project and per-day aggregations, which key on
// Model alone — there, a costed and a priced contribution can land in
// one bucket, and summing both sides is correct without assuming they
// never mix.
type cellVal struct {
	Tokens       TokenCounts
	CostedUSD    float64
	PricedTokens TokenCounts
}

func (a cellVal) Add(b cellVal) cellVal {
	return cellVal{
		Tokens:       a.Tokens.Add(b.Tokens),
		CostedUSD:    a.CostedUSD + b.CostedUSD,
		PricedTokens: a.PricedTokens.Add(b.PricedTokens),
	}
}

type Aggregator struct {
	mu          sync.Mutex
	pricing     pricing.Table
	cells       map[cellKey]cellVal
	coverage    map[covKey]Coverage
	perMsg      map[string]struct{} // msgid:reqid seen-set for dedupe
	unknownMsgs map[string]struct{}
	dupes       int
	now         func() time.Time
	projectCwd  map[string]string // project key -> first non-empty cwd seen
}

func New(p pricing.Table) *Aggregator {
	return NewWithClock(p, time.Now)
}

func NewWithClock(p pricing.Table, now func() time.Time) *Aggregator {
	return &Aggregator{
		pricing:     p,
		cells:       map[cellKey]cellVal{},
		coverage:    map[covKey]Coverage{},
		perMsg:      map[string]struct{}{},
		unknownMsgs: map[string]struct{}{},
		now:         now,
		projectCwd:  map[string]string{},
	}
}

// Apply records an event's contribution. Dedupe rule mirrors ccusage:
// the unique key is "messageID:requestID"; if either is missing the
// event is always counted (no dedup); first-seen wins.
func (a *Aggregator) Apply(e reader.Event) {
	a.mu.Lock()
	defer a.mu.Unlock()

	if e.MessageID != "" && e.RequestID != "" {
		key := e.MessageID + ":" + e.RequestID
		if _, seen := a.perMsg[key]; seen {
			a.dupes++
			return
		}
		a.perMsg[key] = struct{}{}
	}

	if e.CoverageOnly {
		// Bookkeeping only: a coverage event records that a turn
		// happened and whether it carried usable cost. It must never
		// reach the cell write — the fields it shares with a real event
		// (Usage, CostUSD) are not spend. It has already been through
		// dedupe above, which is what keeps a re-scan from inflating it.
		k := covKey{Day: dayOf(e.Timestamp), Vendor: e.Vendor}
		c := a.coverage[k]
		c.Turns++
		if e.HasUsage {
			c.WithUsage++
		}
		a.coverage[k] = c
		return
	}

	// A costed event has no pricing lookup to miss, so it can never be
	// "unknown". Only priced events feed the diagnostic.
	if !e.Costed && !a.pricing.Has(e.Model) {
		uid := e.MessageID
		if uid == "" {
			uid = e.Model + ":" + e.Timestamp.String()
		}
		a.unknownMsgs[uid] = struct{}{}
	}

	k := cellKey{
		Day:     dayOf(e.Timestamp),
		Project: e.Project,
		Source:  e.Source,
		Vendor:  e.Vendor,
		Model:   e.Model,
		IsSub:   e.IsSubagent,
	}
	if e.Cwd != "" {
		if _, ok := a.projectCwd[e.Project]; !ok {
			a.projectCwd[e.Project] = e.Cwd
		}
	}
	tok := TokenCounts{
		In:          e.Usage.InputTokens,
		Out:         e.Usage.OutputTokens,
		CacheCreate: e.Usage.CacheCreationInputTokens,
		CacheRead:   e.Usage.CacheReadInputTokens,
	}
	contrib := cellVal{Tokens: tok}
	if e.Costed {
		contrib.CostedUSD = e.CostUSD
	} else {
		contrib.PricedTokens = tok
	}
	a.cells[k] = a.cells[k].Add(contrib)
}

// Dupes returns the number of msgid:reqid duplicates skipped.
func (a *Aggregator) Dupes() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.dupes
}

// DailyWindow controls how many trailing days the next Snapshot
// fills into Totals.Daily. Default is 30; the minimal-view sparkline
// reads from this slice.
const DailyWindow = 30

// Snapshot computes per-series and per-project totals for today and this
// month from the accumulated token cells. Costs are computed exactly
// once per (series, scope) by summing tokens first then applying
// pricing — this is mathematically equivalent to summing per-event
// costs but avoids float accumulation noise over thousands of events.
func (a *Aggregator) Snapshot() Totals {
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now().Local()
	today := civilDay{now.Year(), now.Month(), now.Day()}

	// 1) Aggregate per-(scope, series) and per-(scope, project, isSub)
	//    in tokens. scope ∈ {"day","month"}.
	type modelKey struct {
		Scope string
		Key   SeriesKey
	}
	type projKey struct {
		Scope, Project string
		IsSub          bool
	}
	modelTok := map[modelKey]cellVal{}
	projTok := map[projKey]cellVal{}

	inMonth := func(d civilDay) bool { return d.Y == now.Year() && d.M == now.Month() }

	for k, t := range a.cells {
		sk := SeriesKey{Source: k.Source, Vendor: k.Vendor, Model: k.Model}
		if k.Day == today {
			mk := modelKey{"day", sk}
			modelTok[mk] = modelTok[mk].Add(t)
			pk := projKey{"day", k.Project, k.IsSub}
			projTok[pk] = projTok[pk].Add(t)
		}
		if inMonth(k.Day) {
			mk := modelKey{"month", sk}
			modelTok[mk] = modelTok[mk].Add(t)
			pk := projKey{"month", k.Project, k.IsSub}
			projTok[pk] = projTok[pk].Add(t)
		}
	}

	// 2) Apply pricing once per cell to derive USD.
	out := Totals{
		Day:       map[SeriesKey]ModelDay{},
		Month:     map[SeriesKey]ModelDay{},
		DayProj:   map[string]ProjectDay{},
		MonthProj: map[string]ProjectDay{},
		Unknown:   len(a.unknownMsgs),
		Dupes:     a.dupes,
		Coverage:  map[string]Coverage{},
		AsOf:      now,
	}

	for mk, v := range modelTok {
		usd := v.CostedUSD
		if a.pricing.Has(mk.Key.Model) {
			usd += a.pricing.Cost(mk.Key.Model, v.PricedTokens.ToUsage())
		}
		md := ModelDay{USD: usd, Tokens: v.Tokens}
		switch mk.Scope {
		case "day":
			out.Day[mk.Key] = md
		case "month":
			out.Month[mk.Key] = md
		}
	}

	// Per-project: also need to attribute cost per (project, model)
	// because a project may use multiple models. The projTok map has
	// (scope, project, isSub) → tokens BUT we lost the model. Walk the
	// raw cells again to compute per-project cost correctly.
	type pmk struct {
		Scope, Project string
		IsSub          bool
		Model          string
	}
	pmTok := map[pmk]cellVal{}
	for k, t := range a.cells {
		if k.Day == today {
			pmTok[pmk{"day", k.Project, k.IsSub, k.Model}] =
				pmTok[pmk{"day", k.Project, k.IsSub, k.Model}].Add(t)
		}
		if inMonth(k.Day) {
			pmTok[pmk{"month", k.Project, k.IsSub, k.Model}] =
				pmTok[pmk{"month", k.Project, k.IsSub, k.Model}].Add(t)
		}
	}

	for k, v := range pmTok {
		usd := v.CostedUSD
		if a.pricing.Has(k.Model) {
			usd += a.pricing.Cost(k.Model, v.PricedTokens.ToUsage())
		}
		var bucket map[string]ProjectDay
		switch k.Scope {
		case "day":
			bucket = out.DayProj
		case "month":
			bucket = out.MonthProj
		}
		pd := bucket[k.Project]
		if k.IsSub {
			pd.Sub = pd.Sub.Add(v.Tokens)
			pd.SubUSD += usd
		} else {
			pd.Main = pd.Main.Add(v.Tokens)
			pd.MainUSD += usd
		}
		bucket[k.Project] = pd
	}

	// Last DailyWindow days, oldest→newest. We sum tokens per day
	// across all (project, model, isSub) cells, then apply pricing per
	// model so the per-day USD is exact.
	type dmKey struct {
		Day   civilDay
		Model string
	}
	byDM := map[dmKey]cellVal{}
	for k, t := range a.cells {
		byDM[dmKey{k.Day, k.Model}] = byDM[dmKey{k.Day, k.Model}].Add(t)
	}
	// Cost counts vendor-reported dollars plus priced models, so the
	// dollar sparkline matches the rest of the UI; tokens count ALL
	// models so the token chart reflects raw activity even when an
	// unpriced model is in use.
	dayCost := map[civilDay]float64{}
	dayTokens := map[civilDay]uint64{}
	for k, v := range byDM {
		dayCost[k.Day] += v.CostedUSD
		if a.pricing.Has(k.Model) {
			dayCost[k.Day] += a.pricing.Cost(k.Model, v.PricedTokens.ToUsage())
		}
		t := v.Tokens
		dayTokens[k.Day] += t.In + t.Out + t.CacheCreate + t.CacheRead
	}
	out.Daily = make([]DailyTotal, 0, DailyWindow)
	for i := DailyWindow - 1; i >= 0; i-- {
		d := now.AddDate(0, 0, -i)
		cd := civilDay{d.Year(), d.Month(), d.Day()}
		out.Daily = append(out.Daily, DailyTotal{
			Day:    d.Format("2006-01-02"),
			USD:    dayCost[cd],
			Tokens: dayTokens[cd],
		})
	}

	// Coverage is scoped to the displayed month, matching out.Month.
	for k, c := range a.coverage {
		if !inMonth(k.Day) {
			continue
		}
		cur := out.Coverage[k.Vendor]
		cur.Turns += c.Turns
		cur.WithUsage += c.WithUsage
		out.Coverage[k.Vendor] = cur
	}

	return out
}

// ProjDayCost is one (project, local-day) cost+token cell, with the
// project's working directory attached so a downstream report can map it
// to a git repo. Cost counts only priced models (matching the rest of the
// UI); tokens count all models.
type ProjDayCost struct {
	Project string
	Cwd     string
	Day     time.Time // local midnight of the day
	USD     float64
	Tokens  TokenCounts
}

// ProjectDaily collapses the accumulated cells into one row per
// (project, local-day) across the aggregator's full range. Pricing is
// applied once per (project, day, model) bucket exactly as Snapshot does
// — tokens are summed first then priced — so dollar figures match the
// live views. The range is bounded by whatever was scanned in.
func (a *Aggregator) ProjectDaily() []ProjDayCost {
	a.mu.Lock()
	defer a.mu.Unlock()

	type key struct {
		proj string
		day  civilDay
	}
	type acc struct {
		usd float64
		tok TokenCounts
	}

	// Two-pass to mirror Snapshot(): first sum tokens per
	// (project, day, model) — merging the main/subagent IsSub split —
	// then price once per that bucket. This keeps cost identical to the
	// live views and avoids a hazard if pricing ever becomes non-linear.
	type pdmKey struct {
		proj  string
		day   civilDay
		model string
	}
	byPDM := map[pdmKey]cellVal{}
	for ck, t := range a.cells {
		pk := pdmKey{ck.Project, ck.Day, ck.Model}
		byPDM[pk] = byPDM[pk].Add(t)
	}

	m := map[key]*acc{}
	for pk, v := range byPDM {
		kk := key{pk.proj, pk.day}
		e := m[kk]
		if e == nil {
			e = &acc{}
			m[kk] = e
		}
		e.usd += v.CostedUSD
		if a.pricing.Has(pk.model) {
			e.usd += a.pricing.Cost(pk.model, v.PricedTokens.ToUsage())
		}
		e.tok = e.tok.Add(v.Tokens)
	}

	out := make([]ProjDayCost, 0, len(m))
	for kk, v := range m {
		out = append(out, ProjDayCost{
			Project: kk.proj,
			Cwd:     a.projectCwd[kk.proj],
			Day:     time.Date(kk.day.Y, kk.day.M, kk.day.D, 0, 0, 0, 0, time.Local),
			USD:     v.usd,
			Tokens:  v.tok,
		})
	}
	return out
}
