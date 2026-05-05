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

// MARK: - Token sparkline + FormatTokens

func TestRenderDailyTokensSparkline_emptyInput_isEmptyOutput(t *testing.T) {
	if got := renderDailyTokensSparkline(nil); got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
	if got := renderDailyTokensSparkline([]agg.DailyTotal{}); got != "" {
		t.Errorf("expected empty string, got %q", got)
	}
}

func TestRenderDailyTokensSparkline_includesHeaderTotalsAndBars(t *testing.T) {
	daily := []agg.DailyTotal{
		{Day: "2026-04-01", Tokens: 0, USD: 0},
		{Day: "2026-04-02", Tokens: 100_000, USD: 1.50},
		{Day: "2026-04-03", Tokens: 5_000_000, USD: 75.00}, // peak
		{Day: "2026-04-04", Tokens: 1_000_000, USD: 15.00},
	}
	out := renderDailyTokensSparkline(daily)

	if !strings.Contains(out, "last 30 days · tokens") {
		t.Errorf("expected token-chart header in output:\n%s", out)
	}
	if !strings.Contains(out, "Apr 1") || !strings.Contains(out, "Apr 4") {
		t.Errorf("expected range 'Apr 1…Apr 4' in output:\n%s", out)
	}
	// Header must show BOTH total tokens and total USD so the user
	// can answer "did spending track usage?" at a glance.
	// Total tokens = 0 + 100K + 5M + 1M = 6,100,000 → "6.1M"
	if !strings.Contains(out, "6.1M") {
		t.Errorf("expected total '6.1M' in output:\n%s", out)
	}
	// Total USD = $91.50
	if !strings.Contains(out, "$91.50") {
		t.Errorf("expected total '$91.50' in output:\n%s", out)
	}
	// Peak day should produce the full block.
	if !strings.Contains(out, "█") {
		t.Errorf("expected '█' (full bar) for peak day in output:\n%s", out)
	}
}

func TestRenderDailyTokensSparkline_zeroSeries_doesNotCrash(t *testing.T) {
	daily := []agg.DailyTotal{
		{Day: "2026-04-01"},
		{Day: "2026-04-02"},
		{Day: "2026-04-03"},
	}
	out := renderDailyTokensSparkline(daily)
	if !strings.Contains(out, "last 30 days · tokens") {
		t.Errorf("expected token header even on zero series:\n%s", out)
	}
}

func TestFormatTokens(t *testing.T) {
	cases := []struct {
		in   uint64
		want string
	}{
		{0, "0"},
		{1, "1"},
		{999, "999"},
		{1_000, "1K"},
		{12_345, "12K"},
		{1_000_000, "1.0M"},
		{1_234_567, "1.2M"},
		{1_000_000_000, "1.00B"},
		{1_234_567_890, "1.23B"},
	}
	for _, c := range cases {
		if got := FormatTokens(c.in); got != c.want {
			t.Errorf("FormatTokens(%d): got %q want %q", c.in, got, c.want)
		}
	}
}
