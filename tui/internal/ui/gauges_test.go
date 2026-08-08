package ui

import (
	"strings"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/planlimits"
)

func statuses() []limits.Status {
	return []limits.Status{
		{Window: limits.WindowDay, SpentUSD: 39, LimitUSD: 50, Pct: 78, State: limits.StateOK},
		{Window: limits.WindowWeek, SpentUSD: 130, LimitUSD: 250, Pct: 52, State: limits.StateOK},
	}
}

func gauges() []planlimits.Gauge {
	return []planlimits.Gauge{
		{Vendor: "codex", WindowLbl: "5h", Pct: 92, ResetsAt: time.Now().Add(2 * time.Hour)},
		{Vendor: "codex", WindowLbl: "7d", Pct: 100, ResetsAt: time.Now().Add(48 * time.Hour)},
		{Vendor: "grok", WindowLbl: "wk", Pct: 14, ResetsAt: time.Now().Add(6 * time.Hour)},
	}
}

func vendors(rows []Row) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.Vendor
	}
	return out
}

// Display order is fixed regardless of value, so a vendor never moves
// between refreshes and the popover cannot disagree with the TUI.
func TestBuildRowsFixedDisplayOrder(t *testing.T) {
	rows := BuildRows(BandShort, statuses(), gauges())
	got := strings.Join(vendors(rows), ",")
	if got != "claude,codex,grok" {
		t.Fatalf("order = %q, want claude,codex,grok", got)
	}
}

// Grok reports no short window. That gap must be visible, not an absent
// row that reads as "no usage".
func TestBuildRowsSynthesisesNotApplicable(t *testing.T) {
	rows := BuildRows(BandShort, statuses(), gauges())
	last := rows[len(rows)-1]
	if last.Vendor != "grok" || last.NotApplicable == "" {
		t.Fatalf("grok short-window row must be n/a, got %+v", last)
	}
	if last.Plan != nil {
		t.Fatal("an n/a row must carry no gauge")
	}
}

// A vendor that is not installed at all is omitted entirely — only a
// vendor present in another band gets the n/a placeholder.
func TestBuildRowsOmitsAbsentVendor(t *testing.T) {
	only := []planlimits.Gauge{{Vendor: "codex", WindowLbl: "5h", Pct: 10, ResetsAt: time.Now().Add(time.Hour)}}
	rows := BuildRows(BandShort, statuses(), only)
	if got := strings.Join(vendors(rows), ","); got != "claude,codex" {
		t.Fatalf("order = %q, want claude,codex (grok not installed)", got)
	}
}

func TestBuildRowsOmitsUnsetBudget(t *testing.T) {
	unset := []limits.Status{
		{Window: limits.WindowDay, State: limits.StateUnset},
		{Window: limits.WindowWeek, State: limits.StateUnset},
	}
	rows := BuildRows(BandShort, unset, gauges())
	if got := strings.Join(vendors(rows), ","); got != "codex,grok" {
		t.Fatalf("order = %q, want codex,grok (no budget configured)", got)
	}
}

// The band title groups by rough duration; each row still carries its
// own window label, because the weekly band mixes an ISO week, a 7-day
// rolling window and a Thu-Thu billing period.
func TestRenderGaugesAlwaysLabelsWindows(t *testing.T) {
	out := RenderGauges(statuses(), gauges())
	for _, want := range []string{"short window", "weekly", "daily", "5h", "7d", "wk", "$39", "$50"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

// Escalation is value-ordered over non-stale rows only. A stale 100%
// must never win, or an expired window paints the menu bar red.
func TestWorstPctIgnoresStale(t *testing.T) {
	gs := []planlimits.Gauge{
		{Vendor: "codex", WindowLbl: "7d", Pct: 100, Stale: true},
		{Vendor: "grok", WindowLbl: "wk", Pct: 14},
	}
	if got := WorstPct(statuses(), gs); got != 78 {
		t.Fatalf("WorstPct = %v, want 78 (stale 100 excluded, day budget wins)", got)
	}
}

// A stale plan window must render once, dimmed, with no live reset
// countdown and no over-threshold glyph — either would wrongly imply the
// window is still open. (Fixes: renderRow previously built the stale
// string twice, discarding the first, styled-only-bar result.)
func TestRenderGaugesStaleRowHasNoLiveMarkers(t *testing.T) {
	stale := []planlimits.Gauge{
		{Vendor: "codex", WindowLbl: "5h", Pct: 100, Stale: true, ResetsAt: time.Now().Add(-time.Hour)},
	}
	out := RenderGauges(statuses(), stale)
	if !strings.Contains(out, "stale · ended") {
		t.Fatalf("stale row missing %q:\n%s", "stale · ended", out)
	}
	if strings.Contains(out, "↻") {
		t.Fatalf("stale row must not show the live reset marker ↻:\n%s", out)
	}
	if strings.Contains(out, "⚠") {
		t.Fatalf("stale row must not show the over-threshold glyph ⚠:\n%s", out)
	}
}

// segmentCells must split gaugeCells across segments proportional to
// each segment's USD share of the limit, using cumulative rather than
// independent rounding so the per-segment counts always sum to the same
// total a single non-stacked bar would show for that total USD.
func TestSegmentCellsProportional(t *testing.T) {
	segs := []Segment{
		{Label: "claude", USD: 30, Style: styleBarFill},
		{Label: "codex", USD: 10, Style: styleBarWarn},
	}
	cells := segmentCells(segs, 50)
	if len(cells) != 2 || cells[0] != 6 || cells[1] != 2 {
		t.Fatalf("segmentCells = %v, want [6 2] (30/50=60%% -> 6 cells, 10/50=20%% -> 2 cells)", cells)
	}

	stackedTotal := cells[0] + cells[1]
	singleTotal := filledCells(40, 50) // same 40 USD as one combined segment
	if stackedTotal != singleTotal {
		t.Fatalf("stacked total filled = %d, want %d (must match a single 40 USD segment)", stackedTotal, singleTotal)
	}
}

// A budget row renders its bar from Segments — not from a scalar
// percentage — so a later spec can add a second (Codex USD) segment to
// the same rows without touching the renderer. This is what makes that
// claim true today rather than aspirational.
func TestRenderRowRendersMultipleSegments(t *testing.T) {
	row := Row{
		Vendor:    "claude",
		WindowLbl: "daily",
		Budget:    &limits.Status{SpentUSD: 40, LimitUSD: 50, Pct: 80, State: limits.StateWarn},
		Segments: []Segment{
			{Label: "claude", USD: 30, Style: styleBarFill},
			{Label: "codex", USD: 10, Style: styleBarWarn},
		},
	}
	out := renderRow(row)
	if got := strings.Count(out, "█"); got != 8 {
		t.Fatalf("filled cells = %d, want 8 (40/50 = 80%%):\n%s", got, out)
	}
	if got := strings.Count(out, "░"); got != 2 {
		t.Fatalf("empty cells = %d, want 2:\n%s", got, out)
	}
}

// A single-segment budget row must render byte-identical to the old
// non-stacked bar over the same percentage, so introducing stacking
// doesn't change today's output.
func TestStackedBarSingleSegmentMatchesPlainBar(t *testing.T) {
	got := stackedBar([]Segment{{Label: "claude", USD: 39, Style: styleBarFill}}, 50)
	want := styleBarFill.Render(plainBar(78))
	if got != want {
		t.Fatalf("stackedBar single-segment = %q, want %q (byte-identical to plain bar)", got, want)
	}
}
