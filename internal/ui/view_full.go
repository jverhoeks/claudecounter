package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jjverhoeks/claudecounter/internal/agg"
)

func viewFull(t agg.Totals, recent []string) string {
	var b strings.Builder
	b.WriteString(viewSplit(t))

	// Per-project section (this month, sorted by descending cost).
	b.WriteString(styleDim.Render(strings.Repeat("─", 60)) + "\n")
	b.WriteString(styleHead.Render("By project (this month) — main · subagent") + "\n")
	if len(t.MonthProj) == 0 {
		b.WriteString(styleDim.Render("  (no project activity yet this month)") + "\n")
	} else {
		names := make([]string, 0, len(t.MonthProj))
		for n := range t.MonthProj {
			names = append(names, n)
		}
		sort.Slice(names, func(i, j int) bool {
			return t.MonthProj[names[i]].USD() > t.MonthProj[names[j]].USD()
		})
		for _, n := range names {
			p := t.MonthProj[n]
			line := fmt.Sprintf("  %-32s %9s   main %s · sub %s\n",
				shortProject(n),
				FormatUSD(p.USD()),
				FormatUSD(p.MainUSD),
				FormatUSD(p.SubUSD),
			)
			if p.USD() < 1 {
				line = styleDim.Render(line)
			}
			b.WriteString(line)
		}
	}

	// Live tail.
	b.WriteString(styleDim.Render(strings.Repeat("─", 60)) + "\n")
	b.WriteString(styleHead.Render("Live") + "\n")
	if len(recent) == 0 {
		b.WriteString(styleDim.Render("  (waiting for events…)") + "\n")
		return b.String()
	}
	for _, line := range recent {
		b.WriteString("  " + line + "\n")
	}
	return b.String()
}

// shortProject turns the encoded project key (e.g.
// "-Users-jjverhoeks-src-tries-2026-04-24-claudecounter") into a short
// readable name ("2026-04-24-claudecounter") by taking the trailing
// segment after the last '-' run. Leaves unrecognised inputs as-is.
func shortProject(encoded string) string {
	if encoded == "" {
		return "(unknown)"
	}
	// The encoded form is the absolute cwd with '/' → '-'. Take
	// everything after the last "-Users-<user>-" prefix path; failing
	// that, just take the last 40 chars.
	if i := strings.LastIndex(encoded, "/"); i >= 0 {
		return encoded[i+1:]
	}
	parts := strings.Split(strings.TrimPrefix(encoded, "-"), "-")
	if len(parts) <= 4 {
		return encoded
	}
	// Heuristic: drop the leading 3-4 system path segments (Users, jjverhoeks, src, …).
	tail := strings.Join(parts[4:], "-")
	if tail == "" {
		return encoded
	}
	return tail
}
