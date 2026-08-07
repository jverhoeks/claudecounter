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
