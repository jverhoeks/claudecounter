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

// TestTUIGaugesSurvivesMalformedConfig is the live-TUI-side counterpart
// to TestGatherGaugesMalformedConfigErrors: gatherGauges surfacing the
// error is fine, but the TUI's own wrapper around it must swallow that
// error rather than propagate it — a malformed limits.toml must never
// take the live counting path down. runLimits (the --limits one-shot),
// by contrast, is expected to fail loudly; that path is exercised by
// exit-code assertions elsewhere, not here.
func TestTUIGaugesSurvivesMalformedConfig(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	dir := t.TempDir()
	cfg := filepath.Join(dir, "limits.toml")
	if err := os.WriteFile(cfg, []byte("[limits]\ndaily = = =\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	out, ok := tuiGauges(cfg, nil, time.Now())
	if ok {
		t.Fatal("malformed config must report ok=false")
	}
	if out != "" {
		t.Fatalf("malformed config must report empty output, got %q", out)
	}
}

// A well-formed config must still flow through tuiGauges unchanged.
func TestTUIGaugesRendersConfiguredBudget(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	dir := t.TempDir()
	cfg := filepath.Join(dir, "limits.toml")
	if err := os.WriteFile(cfg, []byte("[limits]\ndaily = 50.0\nweekly = 250.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	daily := []agg.DailyTotal{{Day: "2026-08-07", USD: 39}}

	out, ok := tuiGauges(cfg, daily, now)
	if !ok {
		t.Fatal("valid config must report ok=true")
	}
	if !strings.Contains(out, "78%") {
		t.Fatalf("output missing expected percentage:\n%s", out)
	}
}

// TestRunLimitsUnconfiguredPrintsFallback exercises runLimits (not just
// gatherGauges) with no config and no vendor logs, so the whole --limits
// one-shot's "nothing to show" branch — not just the string it depends
// on — is under test.
func TestRunLimitsUnconfiguredPrintsFallback(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := filepath.Join(t.TempDir(), "projects")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}

	out := captureStdout(t, func() {
		runLimits(root, pricing.Defaults(), filepath.Join(t.TempDir(), "nonexistent.toml"))
	})
	if !strings.Contains(out, "No limits configured") {
		t.Fatalf("expected fallback message, got:\n%s", out)
	}
}
