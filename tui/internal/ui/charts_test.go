package ui

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

func TestRenderDailySparkline_emptyInput_isEmptyOutput(t *testing.T) {
	if got := renderDailySparkline(nil); got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
	if got := renderDailySparkline([]agg.DailyTotal{}); got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
}

func TestRenderDailySparkline_includesHeaderAndBars(t *testing.T) {
	daily := []agg.DailyTotal{
		{Day: "2026-04-01", USD: 0},
		{Day: "2026-04-02", USD: 5},
		{Day: "2026-04-03", USD: 100}, // peak
		{Day: "2026-04-04", USD: 25},
	}
	out := renderDailySparkline(daily)

	if !strings.Contains(out, "last 30 days") {
		t.Errorf("expected header 'last 30 days' in output:\n%s", out)
	}
	// Range label should reflect first → last short-day forms.
	if !strings.Contains(out, "Apr 1") || !strings.Contains(out, "Apr 4") {
		t.Errorf("expected range 'Apr 1…Apr 4' in output:\n%s", out)
	}
	// Total = 0+5+100+25 = $130.00 — formatted via FormatUSD.
	if !strings.Contains(out, "$130.00") {
		t.Errorf("expected total '$130.00' in output:\n%s", out)
	}
	// At least one bar character. The peak day should produce '█'.
	if !strings.Contains(out, "█") {
		t.Errorf("expected '█' (full bar) for peak day in output:\n%s", out)
	}
}

func TestRenderDailySparkline_zeroSeries_doesNotCrash(t *testing.T) {
	daily := []agg.DailyTotal{
		{Day: "2026-04-01", USD: 0},
		{Day: "2026-04-02", USD: 0},
		{Day: "2026-04-03", USD: 0},
	}
	out := renderDailySparkline(daily)
	if !strings.Contains(out, "last 30 days") {
		t.Errorf("expected 'last 30 days' header even on zero series:\n%s", out)
	}
}

func TestShortDay_validInput_returnsAbbreviated(t *testing.T) {
	cases := map[string]string{
		"2026-04-01": "Apr 1",
		"2026-04-26": "Apr 26",
		"2026-12-09": "Dec 9",
		"2026-01-31": "Jan 31",
	}
	for in, want := range cases {
		if got := shortDay(in); got != want {
			t.Errorf("shortDay(%q): want %q, got %q", in, want, got)
		}
	}
}

func TestShortDay_malformedInput_passesThrough(t *testing.T) {
	cases := []string{"", "not a date", "2026/04/26", "2026-13-01"} // invalid month → pass through
	for _, in := range cases {
		got := shortDay(in)
		if got != in {
			t.Errorf("shortDay(%q) should pass through malformed input, got %q", in, got)
		}
	}
}
