package main

import (
	"fmt"
	"os"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/planlimits"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
)

// gatherGauges evaluates budgets and scans the vendor logs, returning the
// rendered gauge block. Vendor scans never fail the call — an absent CLI
// is the common case — but a malformed config does surface, so a typo in
// limits.toml is not mistaken for "no limits set".
func gatherGauges(cfgPath string, daily []agg.DailyTotal, now time.Time) (string, error) {
	cfg, err := limits.Load(cfgPath)
	if err != nil {
		return "", fmt.Errorf("limits config: %w", err)
	}
	st := limits.Evaluate(daily, cfg, now)

	var gs []planlimits.Gauge
	if codex, err := planlimits.ScanCodex(planlimits.DefaultCodexRoot(), now); err == nil {
		gs = append(gs, codex...)
	}
	if grok, err := planlimits.ScanGrok(planlimits.DefaultGrokLog(), now); err == nil {
		gs = append(gs, grok...)
	}
	return ui.RenderGauges(st, gs, cfg.WarnPct), nil
}

// runLimits is the --limits one-shot: scan, print the gauges, exit. A
// malformed limits.toml is fatal here — this is a one-shot command, and
// exiting non-zero with the parse error is more useful than silently
// showing no gauges. Contrast runTUI's gauge refresh (main.go), which
// routes the same error into the model as a footer warning instead:
// the live counting path must never exit, or spam the alt screen, over
// a config typo.
func runLimits(srcs []sources.Source, table pricing.Table, cfgPath string) {
	snap, _, _ := scanSnapshotSources(srcs, table)
	out, err := gatherGauges(cfgPath, snap.Daily, time.Now())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if out == "" {
		fmt.Println("No limits configured and no vendor plan data found.")
		fmt.Println("Set limits in " + cfgPath)
		return
	}
	fmt.Print(out)
}
