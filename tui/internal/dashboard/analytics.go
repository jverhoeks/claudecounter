package dashboard

import (
	"sort"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

// Dimension is the dashboard's grouping axis.
type Dimension string

const (
	DimModel   Dimension = "model"
	DimVendor  Dimension = "vendor"
	DimSource  Dimension = "source"
	DimProject Dimension = "project"
	DimAgent   Dimension = "agent"
	DimTotal   Dimension = "total"
)

var Dimensions = []Dimension{DimModel, DimVendor, DimSource, DimProject, DimAgent, DimTotal}

// Label is the control's name for d.
func (d Dimension) Label() string {
	if d == DimAgent {
		return "main/sub"
	}
	return string(d)
}

func (d Dimension) name(k Key) string {
	switch d {
	case DimVendor:
		return k.Vendor
	case DimSource:
		return k.Source
	case DimProject:
		return ShortProject(k.Project)
	case DimAgent:
		if k.IsSub {
			return "subagent"
		}
		return "main"
	case DimTotal:
		return "total"
	default:
		return k.Model
	}
}

// Ranges are the range picker's choices, in days.
var Ranges = []int{7, 30, 90, 365}

// TopSeries is how many series the chart draws before folding the rest
// into "other".
const TopSeries = 8

// Days is count consecutive local days ending at end, oldest first.
// Gap-filled, so a chart drops to zero on idle days.
func Days(end time.Time, count int) []string {
	end = end.Local()
	out := make([]string, 0, max(count, 0))
	for i := count - 1; i >= 0; i-- {
		out = append(out, DayKey(time.Date(end.Year(), end.Month(), end.Day()-i, 12, 0, 0, 0, time.Local)))
	}
	return out
}

func add(a, b agg.ModelDay) agg.ModelDay {
	return agg.ModelDay{USD: a.USD + b.USD, Tokens: a.Tokens.Add(b.Tokens)}
}

// Grouped is day → series name → value under d. Every dimension
// partitions the same rows, so all six sum to the same total per day.
func Grouped(s Snapshot, d Dimension) map[string]map[string]agg.ModelDay {
	out := map[string]map[string]agg.ModelDay{}
	for _, r := range s.Rows {
		day := out[r.Day]
		if day == nil {
			day = map[string]agg.ModelDay{}
			out[r.Day] = day
		}
		n := d.name(r.Key)
		day[n] = add(day[n], r.ModelDay)
	}
	return out
}

// Sum totals grouped over days, per series name.
func Sum(grouped map[string]map[string]agg.ModelDay, days []string) map[string]agg.ModelDay {
	out := map[string]agg.ModelDay{}
	for _, day := range days {
		for k, v := range grouped[day] {
			out[k] = add(out[k], v)
		}
	}
	return out
}

// Series is one chart line: values aligned with the days it was built for.
type Series struct {
	Name   string         `json:"name"`
	Values []agg.ModelDay `json:"-"`
}

// BuildSeries ranks series by spend over days, keeps the top n and
// folds the rest into "other" so a long project tail doesn't turn the
// chart into noise.
func BuildSeries(grouped map[string]map[string]agg.ModelDay, days []string, n int) []Series {
	ranked := ranked(Sum(grouped, days))
	kept := map[string]bool{}
	for i, r := range ranked {
		if i < n {
			kept[r.Name] = true
		}
	}
	vals := map[string][]agg.ModelDay{}
	for i, day := range days {
		for name, v := range grouped[day] {
			if !kept[name] {
				name = "other"
			}
			if vals[name] == nil {
				vals[name] = make([]agg.ModelDay, len(days))
			}
			vals[name][i] = add(vals[name][i], v)
		}
	}
	var out []Series
	for i, r := range ranked {
		if i == n {
			break
		}
		if v, ok := vals[r.Name]; ok {
			out = append(out, Series{Name: r.Name, Values: v})
		}
	}
	if v, ok := vals["other"]; ok && !kept["other"] {
		out = append(out, Series{Name: "other", Values: v})
	}
	return out
}

type named struct {
	Name string
	agg.ModelDay
}

// ranked is m by spend, largest first, ties by name.
func ranked(m map[string]agg.ModelDay) []named {
	out := make([]named, 0, len(m))
	for k, v := range m {
		out = append(out, named{k, v})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].USD == out[j].USD {
			return out[i].Name < out[j].Name
		}
		return out[i].USD > out[j].USD
	})
	return out
}

// CoverageFor is model-row coverage over days, by agg's worst-vendor rule.
// Empty for every other dimension.
func CoverageFor(s Snapshot, days []string, d Dimension) map[string]agg.Coverage {
	if d != DimModel {
		return map[string]agg.Coverage{}
	}
	in := map[string]bool{}
	for _, day := range days {
		in[day] = true
	}
	perVendor := map[string]agg.Coverage{}
	keys := map[agg.SeriesKey]agg.ModelDay{}
	for _, day := range days {
		for v, c := range s.Coverage[day] {
			cur := perVendor[v]
			cur.Turns += c.Turns
			cur.WithUsage += c.WithUsage
			perVendor[v] = cur
		}
	}
	for _, r := range s.Rows {
		if in[r.Day] {
			keys[agg.SeriesKey{Source: r.Key.Source, Vendor: r.Key.Vendor, Model: r.Key.Model}] = agg.ModelDay{}
		}
	}
	return agg.GroupCoverage(keys, perVendor, agg.GroupModel)
}

// HeatmapDays is the depth of the weekday × hour heatmap.
const HeatmapDays = 30

// Heatmap is spend by weekday (0 = Monday) × local hour over days.
// filter, when non-empty, keeps only series named filter under d.
func Heatmap(s Snapshot, days []string, d Dimension, filter string) [7][24]float64 {
	var grid [7][24]float64
	wd := map[string]int{}
	for _, day := range days {
		t, err := time.ParseInLocation("2006-01-02", day, time.Local)
		if err == nil {
			wd[day] = (int(t.Weekday()) + 6) % 7
		}
	}
	for _, r := range s.Rows {
		w, ok := wd[r.Day]
		if !ok || r.Hour < 0 || r.Hour > 23 || (filter != "" && d.name(r.Key) != filter) {
			continue
		}
		grid[w][r.Hour] += r.USD
	}
	return grid
}

// Period is one of the subscription table's columns.
type Period string

const (
	PeriodDay   Period = "day"
	PeriodWeek  Period = "week"
	PeriodMonth Period = "month"
)

var Periods = []Period{PeriodDay, PeriodWeek, PeriodMonth}

// ProratedFee is a monthly fee prorated onto p, on a 365-day year so the
// three periods agree.
func ProratedFee(monthly float64, p Period) float64 {
	switch p {
	case PeriodDay:
		return monthly * 12 / 365
	case PeriodWeek:
		return monthly * 12 * 7 / 365
	default:
		return monthly
	}
}

// PeriodDays is the local days of p containing now: today, the ISO week
// (Monday first) so far, or the month so far.
func PeriodDays(now time.Time, p Period) []string {
	now = now.Local()
	switch p {
	case PeriodDay:
		return Days(now, 1)
	case PeriodWeek:
		return Days(now, (int(now.Weekday())+6)%7+1)
	default:
		return Days(now, now.Day())
	}
}

// ProjectedMonth runs month-to-date spend forward at its daily average.
// Today counts as a full day, so this runs low early in the day.
func ProjectedMonth(monthToDate float64, now time.Time) float64 {
	now = now.Local()
	length := time.Date(now.Year(), now.Month()+1, 0, 0, 0, 0, 0, time.Local).Day()
	return monthToDate / float64(max(now.Day(), 1)) * float64(length)
}

// TotalTokens is every token kind summed — the figure token readouts show.
func TotalTokens(t agg.TokenCounts) uint64 { return t.In + t.Out + t.CacheCreate + t.CacheRead }

// CacheHitRate is the share of prompt-side tokens served from cache.
func CacheHitRate(t agg.TokenCounts) float64 {
	p := t.In + t.CacheCreate + t.CacheRead
	if p == 0 {
		return 0
	}
	return float64(t.CacheRead) / float64(p)
}

// TokensPerUSD is nil for a $0 row rather than infinity.
func TokensPerUSD(v agg.ModelDay) *float64 {
	if v.USD <= 0 {
		return nil
	}
	r := float64(TotalTokens(v.Tokens)) / v.USD
	return &r
}

// SpendQuery is the Spend tab's controls.
type SpendQuery struct {
	RangeDays int
	Dim       Dimension
	// Focus scopes the KPIs (and, under DimModel, the heatmap) to one
	// series. Ignored when no row has that name.
	Focus string
}

type KPIs struct {
	USD            float64  `json:"usd"`
	Tokens         uint64   `json:"tokens"`
	TokensPerUSD   *float64 `json:"tokensPerUSD"`
	AvgPerDay      float64  `json:"avgPerDay"`
	CacheHit       float64  `json:"cacheHit"`
	MonthProjected float64  `json:"monthProjected"`
}

type TableRow struct {
	Name         string   `json:"name"`
	USD          float64  `json:"usd"`
	Share        float64  `json:"share"`
	Tokens       uint64   `json:"tokens"`
	TokensPerUSD *float64 `json:"tokensPerUSD"`
	Output       uint64   `json:"output"`
	CacheHit     float64  `json:"cacheHit"`
	// Coverage is the usage-bearing fraction; < agg.PartialCoverageThreshold
	// means the spend is a floor.
	Coverage float64 `json:"coverage"`
}

type SubPeriod struct {
	Period Period  `json:"period"`
	APIUSD float64 `json:"apiUSD"`
	FeeUSD float64 `json:"feeUSD"`
}

type SubRow struct {
	Source  string      `json:"source"`
	FeeUSD  float64     `json:"feeUSD"`
	Periods []SubPeriod `json:"periods"`
}

type ChartSeries struct {
	Name   string    `json:"name"`
	USD    []float64 `json:"usd"`
	Tokens []uint64  `json:"tokens"`
}

// SpendView is everything the Spend tab draws, for one query.
type SpendView struct {
	RangeDays int           `json:"rangeDays"`
	Dim       Dimension     `json:"dim"`
	Focus     string        `json:"focus"`
	Days      []string      `json:"days"`
	KPIs      KPIs          `json:"kpis"`
	Series    []ChartSeries `json:"series"`
	Rows      []TableRow    `json:"rows"`
	// HistoryStart is the first day with any data, when it falls inside
	// the range ("" otherwise): the scan only reaches so far back.
	HistoryStart string         `json:"historyStart"`
	Heatmap      [7][24]float64 `json:"heatmap"`
	HeatmapFocus string         `json:"heatmapFocus"`
	Subs         []SubRow       `json:"subs"`
	AsOf         time.Time      `json:"asOf"`
}

// Spend builds the Spend tab for q.
func Spend(s Snapshot, q SpendQuery, srcs []sources.Source) SpendView {
	if q.RangeDays <= 0 {
		q.RangeDays = 30
	}
	if q.Dim == "" {
		q.Dim = DimModel
	}
	now := s.AsOf
	days := Days(now, q.RangeDays)
	grouped := Grouped(s, q.Dim)
	sums := Sum(grouped, days)
	if _, ok := sums[q.Focus]; !ok {
		q.Focus = ""
	}
	v := SpendView{RangeDays: q.RangeDays, Dim: q.Dim, Focus: q.Focus, Days: days, AsOf: now}

	var total agg.ModelDay
	for _, x := range sums {
		total = add(total, x)
	}
	cov := CoverageFor(s, days, q.Dim)
	for _, r := range ranked(sums) {
		row := TableRow{
			Name: r.Name, USD: r.USD, Tokens: TotalTokens(r.Tokens), TokensPerUSD: TokensPerUSD(r.ModelDay),
			Output: r.Tokens.Out, CacheHit: CacheHitRate(r.Tokens), Coverage: 1,
		}
		if total.USD > 0 {
			row.Share = r.USD / total.USD
		}
		if c, ok := cov[r.Name]; ok {
			row.Coverage = c.Fraction()
		}
		v.Rows = append(v.Rows, row)
	}

	scope := total
	if q.Focus != "" {
		scope = sums[q.Focus]
	}
	month := Sum(grouped, PeriodDays(now, PeriodMonth))
	monthUSD := 0.0
	for k, x := range month {
		if q.Focus == "" || k == q.Focus {
			monthUSD += x.USD
		}
	}
	v.KPIs = KPIs{
		USD: scope.USD, Tokens: TotalTokens(scope.Tokens), TokensPerUSD: TokensPerUSD(scope),
		AvgPerDay: scope.USD / float64(max(len(days), 1)), CacheHit: CacheHitRate(scope.Tokens),
		MonthProjected: ProjectedMonth(monthUSD, now),
	}

	for _, sr := range BuildSeries(grouped, days, TopSeries) {
		cs := ChartSeries{Name: sr.Name, USD: make([]float64, len(days)), Tokens: make([]uint64, len(days))}
		for i, x := range sr.Values {
			cs.USD[i] = x.USD
			cs.Tokens[i] = TotalTokens(x.Tokens)
		}
		v.Series = append(v.Series, cs)
	}

	first := ""
	for _, r := range s.Rows {
		if first == "" || r.Day < first {
			first = r.Day
		}
	}
	if first > days[0] {
		v.HistoryStart = first
	}

	if q.Dim == DimModel {
		v.HeatmapFocus = q.Focus
	}
	v.Heatmap = Heatmap(s, Days(now, HeatmapDays), DimModel, v.HeatmapFocus)

	bySource := map[Period]map[string]agg.ModelDay{}
	srcGrouped := Grouped(s, DimSource)
	for _, p := range Periods {
		bySource[p] = Sum(srcGrouped, PeriodDays(now, p))
	}
	for _, src := range srcs {
		row := SubRow{Source: src.ID(), FeeUSD: src.MonthlyFeeUSD}
		for _, p := range Periods {
			row.Periods = append(row.Periods, SubPeriod{
				Period: p, APIUSD: bySource[p][src.ID()].USD, FeeUSD: ProratedFee(src.MonthlyFeeUSD, p),
			})
		}
		v.Subs = append(v.Subs, row)
	}
	return v
}
