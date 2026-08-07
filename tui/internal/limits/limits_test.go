package limits

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

func at(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02T15:04:05", s, time.Local)
	if err != nil {
		panic(err)
	}
	return t
}

// Friday 2026-08-07 sits in ISO week 32, whose Monday is 2026-08-03.
var week = []agg.DailyTotal{
	{Day: "2026-08-03", USD: 10}, // Mon, in week
	{Day: "2026-08-06", USD: 20}, // Thu, in week
	{Day: "2026-08-07", USD: 39}, // Fri, today
	{Day: "2026-08-02", USD: 99}, // Sun, PREVIOUS ISO week — must be excluded
}

func TestEvaluateDayUsesLocalCalendarDay(t *testing.T) {
	got := Evaluate(week, Config{Daily: 50, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	day := got[0]
	if day.Window != WindowDay {
		t.Fatalf("first status must be WindowDay, got %v", day.Window)
	}
	if day.SpentUSD != 39 {
		t.Fatalf("SpentUSD = %v, want 39 (only today)", day.SpentUSD)
	}
	if day.Pct != 78 {
		t.Fatalf("Pct = %v, want 78", day.Pct)
	}
	if day.State != StateOK {
		t.Fatalf("State = %v, want OK (78 < warn 80)", day.State)
	}
}

func TestEvaluateWeekExcludesPreviousISOWeek(t *testing.T) {
	got := Evaluate(week, Config{Daily: 50, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	wk := got[1]
	if wk.SpentUSD != 69 {
		t.Fatalf("SpentUSD = %v, want 69 (10+20+39; the 99 on 2026-08-02 is last ISO week)", wk.SpentUSD)
	}
}

func TestEvaluateWarnAndOverThresholds(t *testing.T) {
	in := []agg.DailyTotal{{Day: "2026-08-07", USD: 40}}
	warn := Evaluate(in, Config{Daily: 50, WarnPct: 80}, at("2026-08-07T12:00:00"))[0]
	if warn.State != StateWarn {
		t.Fatalf("40/50 = 80%% must be Warn, got %v", warn.State)
	}
	over := Evaluate([]agg.DailyTotal{{Day: "2026-08-07", USD: 50}},
		Config{Daily: 50, WarnPct: 80}, at("2026-08-07T12:00:00"))[0]
	if over.State != StateOver {
		t.Fatalf("exactly at limit must be Over, got %v", over.State)
	}
}

func TestEvaluateUnsetLimit(t *testing.T) {
	got := Evaluate(week, Config{Daily: 0, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	if got[0].State != StateUnset {
		t.Fatalf("zero limit must be Unset, got %v", got[0].State)
	}
	if got[0].Pct != 0 {
		t.Fatalf("Unset must not compute a percentage, got %v", got[0].Pct)
	}
	if got[1].State == StateUnset {
		t.Fatal("the other window must still evaluate")
	}
}

// 2026-12-28 is a Monday in ISO week 53 of ISO year 2026, but its
// calendar year is still 2026 while 2027-01-01 falls in the SAME ISO
// week. Grouping by calendar year would split this week in two.
func TestEvaluateWeekAcrossISOYearBoundary(t *testing.T) {
	in := []agg.DailyTotal{
		{Day: "2026-12-28", USD: 5}, // Mon, ISO 2026-W53
		{Day: "2027-01-01", USD: 7}, // Fri, ISO 2026-W53
		{Day: "2027-01-04", USD: 9}, // Mon, ISO 2027-W01 — excluded
	}
	got := Evaluate(in, Config{Weekly: 100, WarnPct: 80}, at("2027-01-01T12:00:00"))
	if got[1].SpentUSD != 12 {
		t.Fatalf("SpentUSD = %v, want 12 (5+7 share ISO week 2026-W53)", got[1].SpentUSD)
	}
}

func TestEvaluateResetTimes(t *testing.T) {
	got := Evaluate(week, Config{Daily: 50, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	if want := at("2026-08-08T00:00:00"); !got[0].ResetsAt.Equal(want) {
		t.Fatalf("day ResetsAt = %v, want next local midnight %v", got[0].ResetsAt, want)
	}
	if want := at("2026-08-10T00:00:00"); !got[1].ResetsAt.Equal(want) {
		t.Fatalf("week ResetsAt = %v, want next Monday %v", got[1].ResetsAt, want)
	}
}
