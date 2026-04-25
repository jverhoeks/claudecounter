package agg

import (
	"sync"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
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

// ModelDay holds aggregated tokens for a (day or month, model) cell
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

type Totals struct {
	Day        map[string]ModelDay   // model -> totals for today
	Month      map[string]ModelDay   // model -> totals for this month
	DayProj    map[string]ProjectDay // project -> totals for today
	MonthProj  map[string]ProjectDay // project -> totals for this month
	Unknown    int                   // distinct unpriced message ids
	Dupes      int                   // events skipped as msgid:reqid duplicates
	AsOf       time.Time
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

// cellKey identifies one storage cell: a (day, project, model, isSub)
// bucket of token counts. Cost is derived from these at snapshot time.
type cellKey struct {
	Day     civilDay
	Project string
	Model   string
	IsSub   bool
}

type Aggregator struct {
	mu          sync.Mutex
	pricing     pricing.Table
	cells       map[cellKey]TokenCounts
	perMsg      map[string]struct{} // msgid:reqid seen-set for dedupe
	unknownMsgs map[string]struct{}
	dupes       int
	now         func() time.Time
}

func New(p pricing.Table) *Aggregator {
	return NewWithClock(p, time.Now)
}

func NewWithClock(p pricing.Table, now func() time.Time) *Aggregator {
	return &Aggregator{
		pricing:     p,
		cells:       map[cellKey]TokenCounts{},
		perMsg:      map[string]struct{}{},
		unknownMsgs: map[string]struct{}{},
		now:         now,
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

	if !a.pricing.Has(e.Model) {
		uid := e.MessageID
		if uid == "" {
			uid = e.Model + ":" + e.Timestamp.String()
		}
		a.unknownMsgs[uid] = struct{}{}
	}

	k := cellKey{
		Day:     dayOf(e.Timestamp),
		Project: e.Project,
		Model:   e.Model,
		IsSub:   e.IsSubagent,
	}
	cur := a.cells[k]
	a.cells[k] = cur.Add(TokenCounts{
		In:          e.Usage.InputTokens,
		Out:         e.Usage.OutputTokens,
		CacheCreate: e.Usage.CacheCreationInputTokens,
		CacheRead:   e.Usage.CacheReadInputTokens,
	})
}

// Dupes returns the number of msgid:reqid duplicates skipped.
func (a *Aggregator) Dupes() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.dupes
}

// Snapshot computes per-model and per-project totals for today and this
// month from the accumulated token cells. Costs are computed exactly
// once per (model, scope) by summing tokens first then applying
// pricing — this is mathematically equivalent to summing per-event
// costs but avoids float accumulation noise over thousands of events.
func (a *Aggregator) Snapshot() Totals {
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now().Local()
	today := civilDay{now.Year(), now.Month(), now.Day()}

	// 1) Aggregate per-(scope, model) and per-(scope, project, isSub)
	//    in tokens. scope ∈ {"day","month"}.
	type modelKey struct{ Scope, Model string }
	type projKey struct {
		Scope, Project string
		IsSub          bool
	}
	modelTok := map[modelKey]TokenCounts{}
	projTok := map[projKey]TokenCounts{}

	inMonth := func(d civilDay) bool { return d.Y == now.Year() && d.M == now.Month() }

	for k, t := range a.cells {
		if k.Day == today {
			mk := modelKey{"day", k.Model}
			modelTok[mk] = modelTok[mk].Add(t)
			pk := projKey{"day", k.Project, k.IsSub}
			projTok[pk] = projTok[pk].Add(t)
		}
		if inMonth(k.Day) {
			mk := modelKey{"month", k.Model}
			modelTok[mk] = modelTok[mk].Add(t)
			pk := projKey{"month", k.Project, k.IsSub}
			projTok[pk] = projTok[pk].Add(t)
		}
	}

	// 2) Apply pricing once per cell to derive USD.
	out := Totals{
		Day:       map[string]ModelDay{},
		Month:     map[string]ModelDay{},
		DayProj:   map[string]ProjectDay{},
		MonthProj: map[string]ProjectDay{},
		Unknown:   len(a.unknownMsgs),
		Dupes:     a.dupes,
		AsOf:      now,
	}

	for mk, tok := range modelTok {
		usd := 0.0
		if a.pricing.Has(mk.Model) {
			usd = a.pricing.Cost(mk.Model, tok.ToUsage())
		}
		md := ModelDay{USD: usd, Tokens: tok}
		switch mk.Scope {
		case "day":
			out.Day[mk.Model] = md
		case "month":
			out.Month[mk.Model] = md
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
	pmTok := map[pmk]TokenCounts{}
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

	for k, tok := range pmTok {
		var usd float64
		if a.pricing.Has(k.Model) {
			usd = a.pricing.Cost(k.Model, tok.ToUsage())
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
			pd.Sub = pd.Sub.Add(tok)
			pd.SubUSD += usd
		} else {
			pd.Main = pd.Main.Add(tok)
			pd.MainUSD += usd
		}
		bucket[k.Project] = pd
	}

	return out
}
