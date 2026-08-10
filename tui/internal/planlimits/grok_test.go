package planlimits

import (
	"path/filepath"
	"testing"
	"time"
)

func grokFixture() string { return filepath.Join("testdata", "grok_unified.jsonl") }

func TestScanGrokTakesNewestBillingLine(t *testing.T) {
	// Period ends 2026-08-07T20:00Z; evaluate an hour before that.
	at := time.Date(2026, 8, 7, 19, 0, 0, 0, time.UTC)
	gs, err := ScanGrok(grokFixture(), at)
	if err != nil {
		t.Fatalf("ScanGrok: %v", err)
	}
	if len(gs) != 1 {
		t.Fatalf("want 1 gauge, got %d: %+v", len(gs), gs)
	}
	g := gs[0]
	if g.Pct != 14 {
		t.Fatalf("Pct = %v, want 14 (the later billing line wins)", g.Pct)
	}
	if g.Vendor != "grok" || g.WindowLbl != "wk" {
		t.Fatalf("vendor/label wrong: %+v", g)
	}
	if g.Plan != "SuperGrok" {
		t.Fatalf("Plan = %q, want SuperGrok", g.Plan)
	}
	if g.Stale {
		t.Fatal("period has not ended yet, must not be stale")
	}
}

// Grok's period is vendor-anchored (Thursday 20:00 UTC). Once it closes,
// the percentage describes a window that has ended and must not read as
// current.
func TestScanGrokMarksClosedPeriodStale(t *testing.T) {
	at := time.Date(2026, 8, 8, 9, 0, 0, 0, time.UTC)
	gs, err := ScanGrok(grokFixture(), at)
	if err != nil {
		t.Fatalf("ScanGrok: %v", err)
	}
	if len(gs) != 1 || !gs[0].Stale {
		t.Fatalf("closed period must be Stale, got %+v", gs)
	}
}

func TestScanGrokMissingLogIsNotAnError(t *testing.T) {
	gs, err := ScanGrok(filepath.Join(t.TempDir(), "absent.jsonl"), time.Now())
	if err != nil {
		t.Fatalf("absent log must not error, got %v", err)
	}
	if len(gs) != 0 {
		t.Fatalf("absent log must yield no gauges, got %+v", gs)
	}
}
