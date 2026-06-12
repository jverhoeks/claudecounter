package main

import (
	"encoding/csv"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/safety"
)

// gatherSafety runs the wide mode scan for a window. Shared by the CLI and
// the TUI's injected SafetyFunc.
func gatherSafety(root string, days int) ([]safety.Row, safety.Summary, error) {
	since := reportSince(time.Now().Local(), days)
	sessions, err := safety.Scan(root, since)
	if err != nil {
		return nil, safety.Summary{}, err
	}
	home, _ := os.UserHomeDir()
	rows, sum := safety.Build(sessions, home)
	return rows, sum, nil
}

// fmtModePct renders a mode share as integer percent, or "·" for zero so
// the BYPASS column stands out against quiet rows.
func fmtModePct(count, total int) string {
	if count == 0 || total == 0 {
		return "·"
	}
	return fmt.Sprintf("%d%%", int(100*float64(count)/float64(total)+0.5))
}

func fmtContainer(sessions int) string {
	if sessions == 0 {
		return "no"
	}
	return fmt.Sprintf("likely(%d)", sessions)
}

func safetySummaryLine(sum safety.Summary) string {
	if sum.BypassTurns == 0 {
		return fmt.Sprintf("No bypassPermissions turns in this window (%d turns total).", sum.TotalTurns)
	}
	line := fmt.Sprintf("⚠ %d turns (%.1f%%) ran with permissions bypassed, in %d project(s)",
		sum.BypassTurns, sum.BypassPct, sum.BypassProjects)
	if sum.ContainerSessions > 0 {
		line += fmt.Sprintf(" · %d likely-container session(s)", sum.ContainerSessions)
	}
	return line
}

// writeSafety renders the human table. Pure (io.Writer) so it's testable.
func writeSafety(w io.Writer, rows []safety.Row, sum safety.Summary, days int) {
	fmt.Fprintf(w, "Permission-mode safety report — last %d days\n", days)
	fmt.Fprintln(w, safetySummaryLine(sum))
	if len(rows) == 0 {
		return
	}
	fmt.Fprintf(w, "\n%-36s %6s %5s  %7s %6s %5s %5s %7s %7s  %-10s %s\n",
		"project", "turns", "sess", "default", "accept", "plan", "auto", "dontAsk", "BYPASS", "container?", "entry")
	for _, r := range rows {
		fmt.Fprintf(w, "%-36s %6d %5d  %7s %6s %5s %5s %7s %7s  %-10s %s\n",
			trimRight(shortProject(r.Project), 36),
			r.Turns, r.Sessions,
			fmtModePct(r.ModeTurns["default"], r.Turns),
			fmtModePct(r.ModeTurns["acceptEdits"], r.Turns),
			fmtModePct(r.ModeTurns["plan"], r.Turns),
			fmtModePct(r.ModeTurns["auto"], r.Turns),
			fmtModePct(r.ModeTurns["dontAsk"], r.Turns),
			fmtModePct(r.BypassTurns, r.Turns),
			fmtContainer(r.ContainerSessions),
			strings.Join(r.Entrypoints, ","),
		)
	}
	fmt.Fprintln(w, "\ncontainer? is a cwd-path heuristic (no hard signal exists) — read as a hint, not a fact")
}

// writeSafetyCSV emits one row per project, raw counts plus bypass_pct.
func writeSafetyCSV(w io.Writer, rows []safety.Row) error {
	cw := csv.NewWriter(w)
	if err := cw.Write([]string{
		"project", "turns", "sessions", "default", "accept_edits", "plan",
		"auto", "dont_ask", "bypass", "bypass_pct", "container_sessions", "entrypoints",
	}); err != nil {
		return err
	}
	for _, r := range rows {
		if err := cw.Write([]string{
			r.Project,
			strconv.Itoa(r.Turns), strconv.Itoa(r.Sessions),
			strconv.Itoa(r.ModeTurns["default"]), strconv.Itoa(r.ModeTurns["acceptEdits"]),
			strconv.Itoa(r.ModeTurns["plan"]), strconv.Itoa(r.ModeTurns["auto"]),
			strconv.Itoa(r.ModeTurns["dontAsk"]), strconv.Itoa(r.BypassTurns),
			strconv.FormatFloat(r.BypassPct, 'f', 1, 64),
			strconv.Itoa(r.ContainerSessions),
			strings.Join(r.Entrypoints, " "),
		}); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

func runSafety(root string, days int) {
	fmt.Fprintf(os.Stderr, "scanning %s (last %d days) …\n", root, days)
	rows, sum, err := gatherSafety(root, days)
	if err != nil {
		log.Fatalf("safety scan: %v", err)
	}
	writeSafety(os.Stdout, rows, sum, days)
}

func runSafetyCSV(root string, days int) {
	rows, _, err := gatherSafety(root, days)
	if err != nil {
		log.Fatalf("safety scan: %v", err)
	}
	if err := writeSafetyCSV(os.Stdout, rows); err != nil {
		log.Fatalf("csv: %v", err)
	}
}
