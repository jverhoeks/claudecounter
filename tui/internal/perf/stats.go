package perf

import (
	"math"
	"sort"
	"time"
)

// Quantile is the linear-interpolated quantile, q in [0,1]; ok=false for
// no data.
func Quantile(xs []float64, q float64) (float64, bool) {
	if len(xs) == 0 {
		return 0, false
	}
	s := append([]float64(nil), xs...)
	sort.Float64s(s)
	p := float64(len(s)-1) * q
	lo := int(math.Floor(p))
	hi := lo + 1
	if hi > len(s)-1 {
		hi = len(s) - 1
	}
	return s[lo] + (s[hi]-s[lo])*(p-float64(lo)), true
}

// quantilePtr is Quantile as an optional, the shape the report carries.
func quantilePtr(xs []float64, q float64) *float64 {
	v, ok := Quantile(xs, q)
	if !ok {
		return nil
	}
	return &v
}

// MinSamples is the smallest sample count a percentile is shown at: a p99
// of twenty requests is just their maximum.
func MinSamples(q float64) int {
	switch {
	case q >= 0.99:
		return 200
	case q >= 0.95:
		return 100
	default:
		return 20
	}
}

// Fit is the per-bucket latency model's estimate.
type Fit struct {
	// TTFT is the estimated time to first token at ReferenceContextK,
	// seconds.
	TTFT   float64 `json:"ttft"`
	TTFTSD float64 `json:"ttftSD"`
	// ITLMs is the estimated inter-token latency, ms per output token.
	ITLMs float64 `json:"itlMs"`
	ITLSD float64 `json:"itlSD"`
	// ContextCostPer100k is seconds added per 100k tokens of context.
	ContextCostPer100k float64 `json:"contextCostPer100k"`
	N                  int     `json:"n"`
}

func (f Fit) TokensPerSecond() float64 { return 1000 / f.ITLMs }

const ReferenceContextK = 50.0

// FitSamples is a trimmed least squares of duration = a + s·output +
// c·context_k. The worst 1% of durations go first (stalls of hours —
// laptop sleep, resumed sessions — would otherwise flatten the slope),
// then three rounds keep the best-fitting 80%: tool waits and queueing
// only ever add time, so the residuals are one-sided. The ±σ comes from
// the trimmed set and so understates the true uncertainty.
func FitSamples(samples []Sample) *Fit {
	if len(samples) < 100 {
		return nil
	}
	lo, hi := math.Inf(1), math.Inf(-1)
	durs := make([]float64, len(samples))
	for i, s := range samples {
		o := float64(s.Output)
		lo, hi = math.Min(lo, o), math.Max(hi, o)
		durs[i] = s.Duration
	}
	if hi-lo < 200 {
		return nil
	}
	limit, _ := Quantile(durs, 0.99)
	type row struct{ o, c, y float64 }
	var rows []row
	for _, s := range samples {
		if s.Duration <= limit {
			rows = append(rows, row{float64(s.Output), float64(s.Context) / 1000, s.Duration})
		}
	}
	var beta [3]float64
	var inv [9]float64
	for round := 0; round < 4; round++ {
		var xtx [9]float64
		var xty [3]float64
		for _, r := range rows {
			v := [3]float64{1, r.o, r.c}
			for i := 0; i < 3; i++ {
				xty[i] += v[i] * r.y
				for j := 0; j < 3; j++ {
					xtx[i*3+j] += v[i] * v[j]
				}
			}
		}
		m, ok := invert3(xtx)
		if !ok {
			return nil
		}
		inv = m
		for i := 0; i < 3; i++ {
			beta[i] = m[i*3]*xty[0] + m[i*3+1]*xty[1] + m[i*3+2]*xty[2]
		}
		if round == 3 {
			break
		}
		res := make([]float64, len(rows))
		for i, r := range rows {
			res[i] = math.Abs(r.y - (beta[0] + beta[1]*r.o + beta[2]*r.c))
		}
		lim, ok := Quantile(res, 0.8)
		if !ok {
			lim = math.Inf(1)
		}
		kept := rows[:0:0]
		for i, r := range rows {
			if res[i] <= lim {
				kept = append(kept, r)
			}
		}
		rows = kept
	}
	if beta[1] <= 0 || len(rows) <= 3 {
		return nil
	}
	ssr := 0.0
	for _, r := range rows {
		e := r.y - (beta[0] + beta[1]*r.o + beta[2]*r.c)
		ssr += e * e
	}
	s2 := ssr / float64(len(rows)-3)
	var cov [9]float64
	for i := range inv {
		cov[i] = inv[i] * s2
	}
	k := ReferenceContextK
	return &Fit{
		TTFT:               beta[0] + beta[2]*k,
		TTFTSD:             math.Sqrt(math.Max(0, cov[0]+k*k*cov[8]+2*k*cov[2])),
		ITLMs:              1000 * beta[1],
		ITLSD:              1000 * math.Sqrt(math.Max(0, cov[4])),
		ContextCostPer100k: beta[2] * 100,
		N:                  len(samples),
	}
}

func invert3(m [9]float64) ([9]float64, bool) {
	a, b, c, d, e, f, g, h, k := m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8]
	A, B, C := e*k-f*h, -(d*k - f*g), d*h-e*g
	det := a*A + b*B + c*C
	if math.Abs(det) <= 1e-12 {
		return [9]float64{}, false
	}
	out := [9]float64{A, -(b*k - c*h), b*f - c*e,
		B, a*k - c*g, -(a*f - c*d),
		C, -(a*h - b*g), a*e - b*d}
	for i := range out {
		out[i] /= det
	}
	return out, true
}

// Drift is the change between an earlier and a later estimate, called
// significant only when it exceeds twice the combined standard error.
type Drift struct {
	Before   float64 `json:"before"`
	After    float64 `json:"after"`
	TwoSigma float64 `json:"twoSigma"`
}

func (d Drift) Relative() float64 {
	if d.Before == 0 {
		return 0
	}
	return (d.After - d.Before) / d.Before
}

func (d Drift) Significant() bool { return math.Abs(d.After-d.Before) > d.TwoSigma }

func NewDrift(a, sa, b, sb float64) Drift {
	return Drift{Before: a, After: b, TwoSigma: 2 * math.Sqrt(sa*sa+sb*sb)}
}

func toolTotals(s []Sample) (calls, misuse int) {
	for _, x := range s {
		calls += x.ToolCalls
		misuse += x.ToolErrors.Misuse
	}
	return
}

// MisuseDrift is a two-proportion test on misuse per tool call.
func MisuseDrift(a, b []Sample) Drift {
	ta, ma := toolTotals(a)
	tb, mb := toolTotals(b)
	rate := func(m, t int) float64 {
		if t == 0 {
			return 0
		}
		return float64(m) / float64(t)
	}
	pool := rate(ma+mb, ta+tb)
	se := math.Sqrt(pool * (1 - pool) * (1/math.Max(float64(ta), 1) + 1/math.Max(float64(tb), 1)))
	return Drift{Before: rate(ma, ta), After: rate(mb, tb), TwoSigma: 2 * se}
}

func MisuseRate(s []Sample) *float64 {
	t, m := toolTotals(s)
	if t == 0 {
		return nil
	}
	v := float64(m) / float64(t)
	return &v
}

func CacheHitRate(s []Sample) *float64 {
	var p, r uint64
	for _, x := range s {
		p += x.Context
		r += x.CacheRead
	}
	if p == 0 {
		return nil
	}
	v := float64(r) / float64(p)
	return &v
}

// Bucket is the time axis granularity.
type Bucket string

const (
	BucketHour Bucket = "hour"
	BucketDay  Bucket = "day"
	BucketWeek Bucket = "week"
)

// BucketStart is the local start of the bucket holding t; weeks start on
// Monday.
func BucketStart(t time.Time, b Bucket) time.Time {
	t = t.Local()
	switch b {
	case BucketHour:
		return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), 0, 0, 0, time.Local)
	case BucketWeek:
		day := time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.Local)
		back := (int(day.Weekday()) + 6) % 7
		return day.AddDate(0, 0, -back)
	default:
		return time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.Local)
	}
}

func nextBucket(t time.Time, b Bucket) time.Time {
	switch b {
	case BucketHour:
		return t.Add(time.Hour)
	case BucketWeek:
		return t.AddDate(0, 0, 7)
	default:
		return t.AddDate(0, 0, 1)
	}
}

// Buckets lists every bucket from `from` to `to`, gap-filled, so charts
// break on idle buckets instead of drawing a line across them.
func Buckets(from, to time.Time, b Bucket) []time.Time {
	var out []time.Time
	for cur := BucketStart(from, b); !cur.After(to) && len(out) < 5000; cur = nextBucket(cur, b) {
		out = append(out, cur)
	}
	return out
}

// Group puts samples onto starts (which must come from Buckets).
func Group(s []Sample, starts []time.Time, b Bucket) [][]Sample {
	idx := make(map[int64]int, len(starts))
	for i, d := range starts {
		idx[d.Unix()] = i
	}
	out := make([][]Sample, len(starts))
	for _, x := range s {
		if i, ok := idx[BucketStart(x.Time, b).Unix()]; ok {
			out[i] = append(out[i], x)
		}
	}
	return out
}

// Concurrency is the peak and mean number of requests in flight per
// bucket.
func Concurrency(s []Sample, starts []time.Time, b Bucket) (peak []int, mean []float64) {
	if len(starts) == 0 {
		return nil, nil
	}
	idx := make(map[int64]int, len(starts))
	for i, d := range starts {
		idx[d.Unix()] = i
	}
	ends := make([]time.Time, len(starts))
	for i := range starts {
		if i+1 < len(starts) {
			ends[i] = starts[i+1]
		} else {
			ends[i] = nextBucket(starts[i], b)
		}
	}
	busy := make([]float64, len(starts))
	peak = make([]int, len(starts))
	type event struct {
		t time.Time
		d int
	}
	var events []event
	for _, x := range s {
		a := x.Start()
		e := x.Time.Add(secs(x.Duration - x.FirstBlock))
		events = append(events, event{a, 1}, event{e, -1})
		i := idx[BucketStart(a, b).Unix()]
		for ; i < len(starts) && starts[i].Before(e); i++ {
			lo, hi := a, e
			if starts[i].After(lo) {
				lo = starts[i]
			}
			if ends[i].Before(hi) {
				hi = ends[i]
			}
			if hi.After(lo) {
				busy[i] += hi.Sub(lo).Seconds()
			}
		}
	}
	sort.Slice(events, func(i, j int) bool {
		if events[i].t.Equal(events[j].t) {
			return events[i].d < events[j].d
		}
		return events[i].t.Before(events[j].t)
	})
	cur := 0
	for _, ev := range events {
		cur += ev.d
		if i, ok := idx[BucketStart(ev.t, b).Unix()]; ok && cur > peak[i] {
			peak[i] = cur
		}
	}
	mean = make([]float64, len(starts))
	for i := range starts {
		mean[i] = busy[i] / ends[i].Sub(starts[i]).Seconds()
	}
	return peak, mean
}
