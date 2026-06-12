package ui

import (
	"fmt"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/safety"
)

// safetyHeader renders the fixed title + key-hint lines above the viewport.
func safetyHeader(days int) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n",
		styleHead.Render(fmt.Sprintf("Permission-mode safety — last %d days", days)))
	b.WriteString(styleDim.Render("[/]: window   ↑/↓ PgUp/PgDn g/G: scroll   container? is a cwd heuristic, not a fact") + "\n\n")
	return b.String()
}

// safetyPct renders a mode share as integer percent, "·" for zero.
func safetyPct(count, total int) string {
	if count == 0 || total == 0 {
		return "·"
	}
	return fmt.Sprintf("%d%%", int(100*float64(count)/float64(total)+0.5))
}

// shortProjectKey trims the encoded project key (cwd with separators
// replaced by '-') down to its meaningful tail, same rule as the CLI.
func shortProjectKey(encoded string) string {
	if encoded == "" {
		return "(unknown)"
	}
	parts := strings.Split(strings.TrimPrefix(encoded, "-"), "-")
	if len(parts) <= 4 {
		return encoded
	}
	tail := strings.Join(parts[4:], "-")
	if tail == "" {
		return encoded
	}
	return tail
}

// safetyTable renders the scrollable body fed into the viewport.
func safetyTable(rows []safety.Row, sum safety.Summary) string {
	var b strings.Builder

	if sum.BypassTurns == 0 {
		b.WriteString(fmt.Sprintf("No bypassPermissions turns in this window (%d turns total).\n\n", sum.TotalTurns))
	} else {
		line := fmt.Sprintf("⚠ %d turns (%.1f%%) ran with permissions bypassed, in %d project(s)",
			sum.BypassTurns, sum.BypassPct, sum.BypassProjects)
		if sum.ContainerSessions > 0 {
			line += fmt.Sprintf(" · %d likely-container session(s)", sum.ContainerSessions)
		}
		b.WriteString(styleHead.Render(line) + "\n\n")
	}

	fmt.Fprintf(&b, "  %-32s %6s %5s  %7s %6s %5s %5s %7s %7s  %-10s %s\n",
		"project", "turns", "sess", "default", "accept", "plan", "auto", "dontAsk", "BYPASS", "container?", "entry")
	for _, r := range rows {
		// Pad before styling: ANSI escape codes would defeat %7s width.
		bypass := fmt.Sprintf("%7s", safetyPct(r.BypassTurns, r.Turns))
		if r.BypassTurns > 0 {
			bypass = styleMoney.Render(bypass)
		}
		name := shortProjectKey(r.Project)
		if len(name) > 32 {
			name = name[:31] + "…"
		}
		container := "no"
		if r.ContainerSessions > 0 {
			container = fmt.Sprintf("likely(%d)", r.ContainerSessions)
		}
		fmt.Fprintf(&b, "  %-32s %6d %5d  %7s %6s %5s %5s %7s %s  %-10s %s\n",
			name, r.Turns, r.Sessions,
			safetyPct(r.ModeTurns["default"], r.Turns),
			safetyPct(r.ModeTurns["acceptEdits"], r.Turns),
			safetyPct(r.ModeTurns["plan"], r.Turns),
			safetyPct(r.ModeTurns["auto"], r.Turns),
			safetyPct(r.ModeTurns["dontAsk"], r.Turns),
			bypass,
			container,
			strings.Join(r.Entrypoints, ","),
		)
	}
	return b.String()
}
