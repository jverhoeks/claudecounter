package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

func TestGatherGaugesRendersConfiguredBudget(t *testing.T) {
	// Pin $HOME so planlimits.DefaultCodexRoot/DefaultGrokLog resolve
	// under an empty temp dir instead of this machine's real ~/.codex
	// or ~/.grok — otherwise this test's outcome depends on what is
	// installed on whatever machine runs it.
	t.Setenv("HOME", t.TempDir())

	dir := t.TempDir()
	cfg := filepath.Join(dir, "limits.toml")
	if err := os.WriteFile(cfg, []byte("[limits]\ndaily = 50.0\nweekly = 250.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	daily := []agg.DailyTotal{{Day: "2026-08-07", USD: 39}}

	out, err := gatherGauges(cfg, daily, now)
	if err != nil {
		t.Fatalf("gatherGauges: %v", err)
	}
	for _, want := range []string{"short window", "claude", "daily", "78%"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

// With no config and no vendor logs there is nothing to draw. The caller
// must get empty output rather than an error or an empty-looking gauge.
func TestGatherGaugesUnconfiguredIsEmpty(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	out, err := gatherGauges(filepath.Join(t.TempDir(), "absent.toml"), nil, time.Now())
	if err != nil {
		t.Fatalf("unconfigured must not error, got %v", err)
	}
	if strings.TrimSpace(out) != "" {
		t.Fatalf("unconfigured must render nothing, got:\n%s", out)
	}
}

// A malformed config must not take the gauge down silently AND must not
// break the caller: it reports the error, and the caller decides.
func TestGatherGaugesMalformedConfigErrors(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	dir := t.TempDir()
	cfg := filepath.Join(dir, "limits.toml")
	if err := os.WriteFile(cfg, []byte("[limits]\ndaily = = =\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := gatherGauges(cfg, nil, time.Now()); err == nil {
		t.Fatal("malformed config must return an error")
	}
}

// The live TUI no longer has a separate tuiGauges wrapper: main.go's
// refreshGauges calls gatherGauges directly and forwards both Gauges
// and Err into ui.GaugesMsg. The "never crashes, never exits, never
// spams" guarantee now lives in ui.Model's handling of GaugesMsg.Err —
// see model_test.go in internal/ui — rather than in a cmd/claudecounter
// wrapper function.

// TestRunLimitsUnconfiguredPrintsFallback exercises runLimits (not just
// gatherGauges) with no config and no vendor logs, so the whole --limits
// one-shot's "nothing to show" branch — not just the string it depends
// on — is under test. It also pins the fallback message to point at the
// --limits-config path it was actually given, not the package default:
// a prior version of this line hardcoded limits.DefaultConfigPath(),
// which told a user who passed a custom --limits-config to go create a
// file this run would never read.
func TestRunLimitsUnconfiguredPrintsFallback(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := filepath.Join(t.TempDir(), "projects")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	cfgPath := filepath.Join(t.TempDir(), "custom-limits.toml")

	out := captureStdout(t, func() {
		runLimits(root, pricing.Defaults(), cfgPath)
	})
	if !strings.Contains(out, "No limits configured") {
		t.Fatalf("expected fallback message, got:\n%s", out)
	}
	if !strings.Contains(out, cfgPath) {
		t.Fatalf("expected fallback message to point at the given --limits-config path %q, got:\n%s", cfgPath, out)
	}
}
