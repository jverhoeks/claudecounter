package dashboard

import (
	"math"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

// Wednesday 7 Oct 2026, 15:00 local.
var now = time.Date(2026, 10, 7, 15, 0, 0, 0, time.Local)

func ev(id string, t time.Time, model, project string, sub bool, out uint64) reader.Event {
	return reader.Event{
		Timestamp: t, MessageID: id, RequestID: "q" + id, Model: model, Project: project, IsSubagent: sub,
		Vendor: "claude", Source: "claude/personal", Usage: pricing.Usage{InputTokens: 1000, OutputTokens: out, CacheReadInputTokens: 9000},
	}
}

func history() *History {
	h := NewHistory(pricing.Defaults())
	h.Apply(ev("1", now.Add(-time.Hour), "claude-opus-5-5", "-Users-me-src-tries-foo-bar", false, 1000))
	h.Apply(ev("1", now.Add(-time.Hour), "claude-opus-5-5", "-Users-me-src-tries-foo-bar", false, 1000)) // dupe
	h.Apply(ev("2", now.Add(-24*time.Hour), "claude-sonnet-5", "-Users-me-src-tries-foo-bar", true, 500))
	h.Apply(ev("3", now.Add(-48*time.Hour), "claude-sonnet-5", "-Users-me-src-baz", false, 500))
	g := ev("4", now.Add(-2*time.Hour), "grok-5", "p", false, 0)
	g.Vendor, g.Source, g.Costed, g.CostUSD = "grok", "grok/x", true, 1.25
	h.Apply(g)
	c := ev("5", now.Add(-2*time.Hour), "grok-5", "p", false, 0)
	c.Vendor, c.CoverageOnly, c.HasUsage = "grok", true, true
	h.Apply(c)
	c2 := ev("6", now.Add(-2*time.Hour), "grok-5", "p", false, 0)
	c2.Vendor, c2.CoverageOnly = "grok", true
	h.Apply(c2)
	return h
}

func TestEveryDimensionSumsToTheSameTotal(t *testing.T) {
	s := history().Snapshot(now)
	days := Days(now, 7)
	var want float64
	for _, d := range Dimensions {
		total := 0.0
		for _, v := range Sum(Grouped(s, d), days) {
			total += v.USD
		}
		if d == DimModel {
			want = total
		} else if math.Abs(total-want) > 1e-9 {
			t.Errorf("%s total %v, model %v", d, total, want)
		}
	}
	if want <= 1.25 {
		t.Errorf("total %v should include priced and costed spend", want)
	}
	if n := len(s.Rows); n != 4 {
		t.Errorf("rows = %d, want 4 (dupe and coverage dropped)", n)
	}
}

func TestSeriesFoldTheTailIntoOther(t *testing.T) {
	s := history().Snapshot(now)
	days := Days(now, 7)
	ser := BuildSeries(Grouped(s, DimModel), days, 1)
	if len(ser) != 2 || ser[1].Name != "other" || len(ser[0].Values) != 7 {
		t.Fatalf("series = %+v", ser)
	}
	proj := Sum(Grouped(s, DimProject), days)
	if _, ok := proj["foo-bar"]; !ok {
		t.Errorf("projects = %v", proj)
	}
}

func TestHeatmapPutsSpendOnWeekdayAndHour(t *testing.T) {
	s := history().Snapshot(now)
	g := Heatmap(s, Days(now, HeatmapDays), DimModel, "claude-opus-5-5")
	if g[2][14] <= 0 { // Wednesday, 14:00
		t.Errorf("wed 14h = %v", g[2][14])
	}
	sum := 0.0
	for _, r := range g {
		for _, v := range r {
			sum += v
		}
	}
	if sum != g[2][14] {
		t.Error("focus should keep only that model")
	}
}

func TestSpendView(t *testing.T) {
	s := history().Snapshot(now)
	v := Spend(s, SpendQuery{RangeDays: 7, Dim: DimModel, Focus: "gone"}, []sources.Source{
		{Vendor: "claude", Label: "personal", MonthlyFeeUSD: 100},
	})
	if v.Focus != "" || len(v.Rows) != 3 || v.Rows[0].Share <= 0 {
		t.Fatalf("view = %+v", v)
	}
	for _, r := range v.Rows {
		if r.Name == "grok-5" && r.Coverage != 0.5 {
			t.Errorf("grok coverage = %v", r.Coverage)
		}
	}
	if v.HistoryStart != DayKey(now.Add(-48*time.Hour)) {
		t.Errorf("history start = %q", v.HistoryStart)
	}
	sub := v.Subs[0]
	if sub.Periods[0].APIUSD <= 0 || math.Abs(sub.Periods[1].FeeUSD-100*12*7/365.0) > 1e-9 {
		t.Errorf("subs = %+v", sub)
	}
	// Wednesday: the ISO week so far is Mon..Wed.
	if n := len(PeriodDays(now, PeriodWeek)); n != 3 {
		t.Errorf("week days = %d", n)
	}
}

func TestProjectedMonth(t *testing.T) {
	if got := ProjectedMonth(70, now); math.Abs(got-310) > 1e-9 { // 10/day × 31
		t.Errorf("projected = %v", got)
	}
}

func TestShortProject(t *testing.T) {
	for in, want := range map[string]string{"": "(unknown)", "-Users-me-src-tries-foo-bar": "foo-bar", "-a-b": "-a-b"} {
		if got := ShortProject(in); got != want {
			t.Errorf("%q → %q", in, got)
		}
	}
}
