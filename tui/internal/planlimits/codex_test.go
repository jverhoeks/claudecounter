package planlimits

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func now() time.Time { return time.Date(2026, 8, 7, 13, 0, 0, 0, time.UTC) }

// copyFixture places a fixture into a temp dir under the session-file
// layout ScanCodex walks, with a controlled mtime.
func copyFixture(t *testing.T, name string, mtime time.Time) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "2026", "08", "07")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, "rollout-"+name)
	if err := os.WriteFile(dst, body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(dst, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	return root
}

func byLabel(gs []Gauge) map[string]Gauge {
	m := map[string]Gauge{}
	for _, g := range gs {
		m[g.WindowLbl] = g
	}
	return m
}

// The old layout puts 5h in primary and weekly in secondary. Keying on
// the slot name instead of window_minutes would mislabel both.
func TestScanCodexOldLayoutBothWindows(t *testing.T) {
	root := copyFixture(t, "codex_old_layout.jsonl", now().Add(-time.Hour))
	gs, err := ScanCodex(root, now())
	if err != nil {
		t.Fatalf("ScanCodex: %v", err)
	}
	m := byLabel(gs)
	if len(m) != 2 {
		t.Fatalf("want 2 windows, got %d: %+v", len(m), gs)
	}
	if m["5h"].Pct != 92 {
		t.Fatalf("5h Pct = %v, want 92 (newest observation wins)", m["5h"].Pct)
	}
	if m["7d"].Pct != 30 {
		t.Fatalf("7d Pct = %v, want 30", m["7d"].Pct)
	}
	if m["5h"].Vendor != "codex" || m["5h"].Plan != "plus" {
		t.Fatalf("vendor/plan wrong: %+v", m["5h"])
	}
}

// The new layout puts the weekly window in primary. It must still be
// labelled 7d, proving the reader keys on window_minutes.
func TestScanCodexNewLayoutWeeklyInPrimary(t *testing.T) {
	root := copyFixture(t, "codex_new_layout.jsonl", now().Add(-time.Hour))
	gs, err := ScanCodex(root, now())
	if err != nil {
		t.Fatalf("ScanCodex: %v", err)
	}
	m := byLabel(gs)
	if len(m) != 1 {
		t.Fatalf("want 1 window, got %d: %+v", len(m), gs)
	}
	if m["7d"].Pct != 100 {
		t.Fatalf("7d Pct = %v, want 100", m["7d"].Pct)
	}
}

func TestScanCodexMarksExpiredWindowStale(t *testing.T) {
	root := copyFixture(t, "codex_new_layout.jsonl", now().Add(-time.Hour))
	// resets_at in the fixture is far future; evaluate as if now is later.
	future := time.Unix(4102444800, 0).Add(time.Hour)
	gs, err := ScanCodex(root, future)
	if err != nil {
		t.Fatalf("ScanCodex: %v", err)
	}
	if len(gs) != 1 || !gs[0].Stale {
		t.Fatalf("expired window must be Stale, got %+v", gs)
	}
}

func TestScanCodexMissingRootIsNotAnError(t *testing.T) {
	gs, err := ScanCodex(filepath.Join(t.TempDir(), "absent"), now())
	if err != nil {
		t.Fatalf("absent root must not error, got %v", err)
	}
	if len(gs) != 0 {
		t.Fatalf("absent root must yield no gauges, got %+v", gs)
	}
}

func TestWindowLabel(t *testing.T) {
	for _, c := range []struct {
		min  int
		want string
	}{{300, "5h"}, {10080, "7d"}, {60, "1h"}, {1440, "24h"}} {
		if got := WindowLabel(c.min); got != c.want {
			t.Errorf("WindowLabel(%d) = %q, want %q", c.min, got, c.want)
		}
	}
}
