package main

import (
	"fmt"
	"log"
	"os"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/planlimits"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
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
	return ui.RenderGauges(st, gs), nil
}

// tuiGauges is the live TUI's gauge refresh. Unlike runLimits it never
// exits on a bad config: the counting path must survive a typo in
// limits.toml. A load error is logged once and reported to the caller
// as ok=false, meaning "leave whatever gauge block is already showing
// alone" — never a crash, never a blank overwrite mid-session.
func tuiGauges(cfgPath string, daily []agg.DailyTotal, now time.Time) (out string, ok bool) {
	out, err := gatherGauges(cfgPath, daily, now)
	if err != nil {
		log.Printf("limits config: %v (leaving gauges as-is)", err)
		return "", false
	}
	return out, true
}

// runLimits is the --limits one-shot: scan, print the gauges, exit. A
// malformed limits.toml is fatal here — this is a one-shot command, and
// exiting non-zero with the parse error is more useful than silently
// showing no gauges. Contrast runTUI's gauge refresh, which must never
// take the live counting path down over a config typo.
func runLimits(root string, table pricing.Table, cfgPath string) {
	snap, _, _ := scanSnapshot(root, table)
	out, err := gatherGauges(cfgPath, snap.Daily, time.Now())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if out == "" {
		fmt.Println("No limits configured and no vendor plan data found.")
		fmt.Println("Set limits in " + limits.DefaultConfigPath())
		return
	}
	fmt.Print(out)
}
