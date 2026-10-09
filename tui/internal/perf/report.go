package perf

import (
	"math"
	"sort"
	"time"
)

// Agent filters main sessions, subagents, or both.
type Agent string

const (
	AgentAll      Agent = "all"
	AgentMain     Agent = "main"
	AgentSubagent Agent = "subagent"
)

// Filters are the Performance view's controls.
type Filters struct {
	Model     string `json:"model"`
	RangeDays int    `json:"rangeDays"`
	// Bucket "" = pick from the range: hourly up to a week, daily beyond.
	Bucket Bucket `json:"bucket"`
	Agent  Agent  `json:"agent"`
	// Effort "" = all; "none" = requests whose client recorded no effort.
	Effort string `json:"effort"`
}

func (f Filters) ResolvedBucket() Bucket {
	if f.Bucket != "" {
		return f.Bucket
	}
	if f.RangeDays <= 7 {
		return BucketHour
	}
	return BucketDay
}

type Percentile struct {
	Q     float64
	Label string
}

var Percentiles = []Percentile{{0.5, "p50"}, {0.9, "p90"}, {0.95, "p95"}, {0.99, "p99"}}

// Efforts are the effort levels in display order.
var Efforts = []string{"none", "low", "medium", "high", "xhigh"}

type ContextBin struct {
	Lo, Hi uint64
	Label  string
}

var ContextBins = []ContextBin{
	{0, 25_000, "<25k"}, {25_000, 50_000, "25–50k"}, {50_000, 100_000, "50–100k"},
	{100_000, 150_000, "100–150k"}, {150_000, 250_000, "150–250k"}, {250_000, math.MaxUint64, "250k+"},
}

// ModelRow is one row of the cross-model table.
type ModelRow struct {
	Model         string   `json:"model"`
	Requests      int      `json:"requests"`
	E2EP50        *float64 `json:"e2eP50"`
	FirstBlockP50 *float64 `json:"firstBlockP50"`
	Fit           *Fit     `json:"fit"`
	Misuse        *float64 `json:"misuse"`
	TTFTDrift     *Drift   `json:"ttftDrift"`
	ITLDrift      *Drift   `json:"itlDrift"`
	MisuseDrift   *Drift   `json:"misuseDrift"`
}

// EffortCell is one model × effort cell: how often that model ran at that
// effort and what it produced there.
type EffortCell struct {
	Model  string `json:"model"`
	Effort string `json:"effort"`
	Count  int    `json:"count"`
	// Share of the model's requests in range.
	Share       float64  `json:"share"`
	E2EP50      *float64 `json:"e2eP50"`
	OutputP50   *float64 `json:"outputP50"`
	ThinkingP50 *float64 `json:"thinkingP50"`
}

// Report is everything the Performance view draws, computed in one pass.
// Every per-bucket slice is len(Buckets) long; nil = too few samples.
type Report struct {
	Filters Filters `json:"filters"`
	Model   string  `json:"model"`
	// EffortMatrix is every model × effort level in range. It ignores
	// the effort filter — comparing efforts is the point.
	EffortMatrix  []EffortCell `json:"effortMatrix"`
	Models        []ModelRow   `json:"models"`
	Requests      int          `json:"requests"`
	SubagentShare float64      `json:"subagentShare"`

	// KPIs for the selected model
	E2EP50        *float64 `json:"e2eP50"`
	E2EP90        *float64 `json:"e2eP90"`
	FirstBlockP50 *float64 `json:"firstBlockP50"`
	FirstBlockP90 *float64 `json:"firstBlockP90"`
	Fit           *Fit     `json:"fit"`
	CacheHit      *float64 `json:"cacheHit"`
	Rebuilds      int      `json:"rebuilds"`
	ToolCalls     int      `json:"toolCalls"`
	Misuse        *float64 `json:"misuse"`
	TTFTDrift     *Drift   `json:"ttftDrift"`
	ITLDrift      *Drift   `json:"itlDrift"`
	MisuseDrift   *Drift   `json:"misuseDrift"`
	ContextBefore *float64 `json:"contextBefore"`
	ContextAfter  *float64 `json:"contextAfter"`

	Buckets          []time.Time           `json:"-"`
	BucketMs         []int64               `json:"buckets"`
	Counts           []int                 `json:"counts"`
	E2E              map[string][]*float64 `json:"e2e"` // percentile label / "mean"
	FirstBlock       map[string][]*float64 `json:"firstBlock"`
	Fits             []*Fit                `json:"fits"`
	PeakInFlight     []*float64            `json:"peakInFlight"`
	MeanInFlight     []*float64            `json:"meanInFlight"`
	OutputPerMinute  []*float64            `json:"outputPerMinute"`
	CacheHitRate     []*float64            `json:"cacheHitRate"`
	RebuildCount     []int                 `json:"rebuildCount"`
	MisuseRate       []*float64            `json:"misuseRate"`
	ExitRate         []*float64            `json:"exitRate"`
	OutputP50        []*float64            `json:"outputP50"`
	ThinkingP50      []*float64            `json:"thinkingP50"`
	ContextP50       []*float64            `json:"contextP50"`
	ContextP90       []*float64            `json:"contextP90"`
	EffortShare      map[string][]*float64 `json:"effortShare"`
	SubagentByBucket []*float64            `json:"subagentShareByBucket"`

	// Whole range
	HourE2E         []*float64 `json:"hourE2E"` // 24, local hour
	HourFirstBlock  []*float64 `json:"hourFirstBlock"`
	MisuseByContext []*float64 `json:"misuseByContext"` // per ContextBins
}

func EffortKey(s Sample) string {
	for _, e := range Efforts {
		if s.Effort == e && e != "none" {
			return e
		}
	}
	return "none"
}

// MinDriftSamples: below this many requests (or tool calls) per third, a
// drift figure is noise dressed up as a percentage — a 381-request month
// produced "−188%" — so none is shown.
const MinDriftSamples = 500

// thirds returns the first and last third of a time-sorted sample — what
// "has it changed?" compares. Thirds rather than halves so the two never
// touch.
func thirds(xs []Sample) ([]Sample, []Sample) {
	n := len(xs) / 3
	return xs[:n], xs[len(xs)-n:]
}

func fitDrift(a, b *Fit, v func(Fit) (float64, float64)) *Drift {
	if a == nil || b == nil || min(a.N, b.N) < MinDriftSamples {
		return nil
	}
	va, sa := v(*a)
	vb, sb := v(*b)
	d := NewDrift(va, sa, vb, sb)
	return &d
}

func ttftOf(f Fit) (float64, float64) { return f.TTFT, f.TTFTSD }
func itlOf(f Fit) (float64, float64)  { return f.ITLMs, f.ITLSD }

func misuseDriftGated(a, b []Sample) *Drift {
	ca, _ := toolTotals(a)
	cb, _ := toolTotals(b)
	if min(ca, cb) < MinDriftSamples {
		return nil
	}
	d := MisuseDrift(a, b)
	return &d
}

func ptr(v float64) *float64 { return &v }

func mapF(xs []Sample, f func(Sample) float64) []float64 {
	out := make([]float64, len(xs))
	for i, x := range xs {
		out[i] = f(x)
	}
	return out
}

func thinkingValues(xs []Sample) []float64 {
	var out []float64
	for _, x := range xs {
		if x.Thinking != nil {
			out = append(out, float64(*x.Thinking))
		}
	}
	return out
}

func duration(s Sample) float64   { return s.Duration }
func firstBlock(s Sample) float64 { return s.FirstBlock }
func output(s Sample) float64     { return float64(s.Output) }
func context(s Sample) float64    { return float64(s.Context) }

// BuildReport computes the report for samples (time-sorted) under filters.
func BuildReport(all []Sample, filters Filters, now time.Time) Report {
	if filters.RangeDays <= 0 {
		filters.RangeDays = 30
	}
	if filters.Agent == "" {
		filters.Agent = AgentAll
	}
	start := now.Add(-time.Duration(filters.RangeDays) * 24 * time.Hour)
	agentOK := func(s Sample) bool {
		return filters.Agent == AgentAll || s.IsSubagent == (filters.Agent == AgentSubagent)
	}
	var inScope, anyEffort []Sample
	for _, s := range all {
		if s.Time.Before(start) || !agentOK(s) {
			continue
		}
		anyEffort = append(anyEffort, s)
		if filters.Effort == "" || EffortKey(s) == filters.Effort {
			inScope = append(inScope, s)
		}
	}
	byModel := map[string][]Sample{}
	for _, s := range inScope {
		byModel[s.Model] = append(byModel[s.Model], s)
	}

	var matrix []EffortCell
	anyByModel := map[string][]Sample{}
	for _, s := range anyEffort {
		anyByModel[s.Model] = append(anyByModel[s.Model], s)
	}
	for m, xs := range anyByModel {
		byEffort := map[string][]Sample{}
		for _, s := range xs {
			byEffort[EffortKey(s)] = append(byEffort[EffortKey(s)], s)
		}
		for e, g := range byEffort {
			matrix = append(matrix, EffortCell{
				Model: m, Effort: e, Count: len(g), Share: float64(len(g)) / float64(len(xs)),
				E2EP50:      quantilePtr(mapF(g, duration), 0.5),
				OutputP50:   quantilePtr(mapF(g, output), 0.5),
				ThinkingP50: quantilePtr(thinkingValues(g), 0.5),
			})
		}
	}
	sort.Slice(matrix, func(i, j int) bool {
		if matrix[i].Model != matrix[j].Model {
			return matrix[i].Model < matrix[j].Model
		}
		return effortIndex(matrix[i].Effort) < effortIndex(matrix[j].Effort)
	})

	rows := make([]ModelRow, 0, len(byModel))
	for m, xs := range byModel {
		a, b := thirds(xs)
		fa, fb := FitSamples(a), FitSamples(b)
		rows = append(rows, ModelRow{
			Model: m, Requests: len(xs),
			E2EP50:        quantilePtr(mapF(xs, duration), 0.5),
			FirstBlockP50: quantilePtr(mapF(xs, firstBlock), 0.5),
			Fit:           FitSamples(xs),
			Misuse:        MisuseRate(xs),
			TTFTDrift:     fitDrift(fa, fb, ttftOf),
			ITLDrift:      fitDrift(fa, fb, itlOf),
			MisuseDrift:   misuseDriftGated(a, b),
		})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Requests != rows[j].Requests {
			return rows[i].Requests > rows[j].Requests
		}
		return rows[i].Model < rows[j].Model
	})

	// Default to whichever model was used most in the last two weeks.
	model := ""
	if _, ok := byModel[filters.Model]; ok && filters.Model != "" {
		model = filters.Model
	} else {
		recent := map[string]int{}
		cut := now.Add(-14 * 24 * time.Hour)
		for _, s := range inScope {
			if s.Time.After(cut) {
				recent[s.Model]++
			}
		}
		best := -1
		for m, n := range recent {
			if n > best || (n == best && m < model) {
				model, best = m, n
			}
		}
		if model == "" && len(rows) > 0 {
			model = rows[0].Model
		}
	}
	xs := byModel[model]

	unit := filters.ResolvedBucket()
	first := start
	if len(xs) > 0 && xs[0].Time.After(start) {
		first = xs[0].Time
	}
	buckets := Buckets(first, now, unit)
	groups := Group(xs, buckets, unit)
	peak, mean := Concurrency(xs, buckets, unit)

	pct := func(f func(Sample) float64) map[string][]*float64 {
		out := map[string][]*float64{}
		for _, p := range Percentiles {
			vals := make([]*float64, len(groups))
			for i, g := range groups {
				if len(g) >= MinSamples(p.Q) {
					vals[i] = quantilePtr(mapF(g, f), p.Q)
				}
			}
			out[p.Label] = vals
		}
		means := make([]*float64, len(groups))
		for i, g := range groups {
			if len(g) >= 20 {
				sum := 0.0
				for _, x := range g {
					sum += f(x)
				}
				means[i] = ptr(sum / float64(len(g)))
			}
		}
		out["mean"] = means
		return out
	}
	rate := func(g []Sample, count func(Sample) int) *float64 {
		t, n := 0, 0
		for _, x := range g {
			t += x.ToolCalls
			n += count(x)
		}
		if t < 100 {
			return nil
		}
		return ptr(float64(n) / float64(t))
	}
	median := func(vals []float64) *float64 {
		if len(vals) < 20 {
			return nil
		}
		return quantilePtr(vals, 0.5)
	}
	share := func(g []Sample, include func(Sample) bool) *float64 {
		if len(g) == 0 {
			return nil
		}
		n := 0
		for _, x := range g {
			if include(x) {
				n++
			}
		}
		return ptr(float64(n) / float64(len(g)))
	}
	ctxQ := func(g []Sample, q float64) *float64 {
		if len(g) < 20 {
			return nil
		}
		return quantilePtr(mapF(g, context), q)
	}
	misuseOf := func(s Sample) int { return s.ToolErrors.Misuse }
	exitOf := func(s Sample) int { return s.ToolErrors.Exit }

	n := len(buckets)
	r := Report{
		Filters: filters, Model: model, EffortMatrix: matrix, Models: rows, Requests: len(xs),
		Buckets: buckets, BucketMs: make([]int64, n), Counts: make([]int, n),
		Fits: make([]*Fit, n), PeakInFlight: make([]*float64, n), MeanInFlight: make([]*float64, n),
		OutputPerMinute: make([]*float64, n), CacheHitRate: make([]*float64, n), RebuildCount: make([]int, n),
		MisuseRate: make([]*float64, n), ExitRate: make([]*float64, n), OutputP50: make([]*float64, n),
		ThinkingP50: make([]*float64, n), ContextP50: make([]*float64, n), ContextP90: make([]*float64, n),
		EffortShare: map[string][]*float64{}, SubagentByBucket: make([]*float64, n),
		E2E: pct(duration), FirstBlock: pct(firstBlock),
	}
	for _, e := range Efforts {
		r.EffortShare[e] = make([]*float64, n)
	}
	for i, g := range groups {
		r.BucketMs[i] = buckets[i].UnixMilli()
		r.Counts[i] = len(g)
		r.Fits[i] = FitSamples(g)
		r.CacheHitRate[i] = CacheHitRate(g)
		r.MisuseRate[i] = rate(g, misuseOf)
		r.ExitRate[i] = rate(g, exitOf)
		r.OutputP50[i] = median(mapF(g, output))
		r.ThinkingP50[i] = median(thinkingValues(g))
		r.ContextP50[i] = ctxQ(g, 0.5)
		r.ContextP90[i] = ctxQ(g, 0.9)
		r.SubagentByBucket[i] = share(g, func(s Sample) bool { return s.IsSubagent })
		for _, e := range Efforts {
			e := e
			r.EffortShare[e][i] = share(g, func(s Sample) bool { return EffortKey(s) == e })
		}
		for _, x := range g {
			if x.Rebuild != RebuildNone {
				r.RebuildCount[i]++
			}
		}
		if len(g) == 0 {
			continue
		}
		r.PeakInFlight[i] = ptr(float64(peak[i]))
		r.MeanInFlight[i] = ptr(mean[i])
		end := nextBucket(buckets[i], unit)
		if i+1 < n {
			end = buckets[i+1]
		}
		var out uint64
		for _, x := range g {
			out += x.Output
		}
		r.OutputPerMinute[i] = ptr(float64(out) / (end.Sub(buckets[i]).Minutes()))
	}

	hours := make([][]Sample, 24)
	for _, s := range xs {
		h := s.Time.Local().Hour()
		hours[h] = append(hours[h], s)
	}
	r.HourE2E = make([]*float64, 24)
	r.HourFirstBlock = make([]*float64, 24)
	for h, g := range hours {
		if len(g) >= 20 {
			r.HourE2E[h] = quantilePtr(mapF(g, duration), 0.5)
			r.HourFirstBlock[h] = quantilePtr(mapF(g, firstBlock), 0.5)
		}
	}
	for _, bin := range ContextBins {
		var in []Sample
		for _, s := range xs {
			if s.Context >= bin.Lo && s.Context < bin.Hi {
				in = append(in, s)
			}
		}
		r.MisuseByContext = append(r.MisuseByContext, rate(in, misuseOf))
	}

	if sh := share(xs, func(s Sample) bool { return s.IsSubagent }); sh != nil {
		r.SubagentShare = *sh
	}
	r.E2EP50 = quantilePtr(mapF(xs, duration), 0.5)
	r.E2EP90 = quantilePtr(mapF(xs, duration), 0.9)
	r.FirstBlockP50 = quantilePtr(mapF(xs, firstBlock), 0.5)
	r.FirstBlockP90 = quantilePtr(mapF(xs, firstBlock), 0.9)
	r.Fit = FitSamples(xs)
	r.CacheHit = CacheHitRate(xs)
	for _, x := range xs {
		r.ToolCalls += x.ToolCalls
		if x.Rebuild != RebuildNone {
			r.Rebuilds++
		}
	}
	r.Misuse = MisuseRate(xs)
	a, b := thirds(xs)
	fa, fb := FitSamples(a), FitSamples(b)
	r.TTFTDrift = fitDrift(fa, fb, ttftOf)
	r.ITLDrift = fitDrift(fa, fb, itlOf)
	r.MisuseDrift = misuseDriftGated(a, b)
	r.ContextBefore = quantilePtr(mapF(a, context), 0.5)
	r.ContextAfter = quantilePtr(mapF(b, context), 0.5)
	return r
}

func effortIndex(e string) int {
	for i, x := range Efforts {
		if x == e {
			return i
		}
	}
	return len(Efforts)
}
