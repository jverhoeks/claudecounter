package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
)

// loadSession resolves --session (id prefix, empty = most recent) and parses
// the transcript plus its subagent files.
func loadSession(root, idPrefix string) *session.Session {
	path, err := session.Find(root, idPrefix)
	if err != nil {
		log.Fatalf("session: %v", err)
	}
	s, err := session.Parse(path)
	if err != nil {
		log.Fatalf("parse %s: %v", path, err)
	}
	return s
}

// sessionCost sums the priced turns; unpriced is how many turns use a model
// missing from the pricing table (their cost is unknown, not zero).
func sessionCost(s *session.Session, table pricing.Table) (usd float64, unpriced int) {
	for _, t := range s.Turns {
		if !table.Has(t.Model) {
			unpriced++
			continue
		}
		usd += table.Cost(t.Model, t.Usage)
	}
	return usd, unpriced
}

// modeChain renders the session's permission-mode history, flagging any hop
// into bypassPermissions.
func modeChain(changes []session.ModeChange) string {
	if len(changes) == 0 {
		return "(none recorded)"
	}
	parts := make([]string, 0, len(changes))
	for _, c := range changes {
		m := c.To
		if m == "bypassPermissions" {
			m += "(!)"
		}
		parts = append(parts, m)
	}
	return strings.Join(parts, " → ")
}

func fmtDuration(d time.Duration) string {
	d = d.Round(time.Minute)
	if h := int(d.Hours()); h > 0 {
		return fmt.Sprintf("%dh%02dm", h, int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dm", int(d.Minutes()))
}

// writeScorecard renders the per-session quality stats. Pure for testing.
func writeScorecard(w io.Writer, s *session.Session, table pricing.Table) {
	entry := s.Entrypoint
	if entry == "" {
		entry = "?"
	}
	fmt.Fprintf(w, "Session %s\n", s.ID)
	fmt.Fprintf(w, "  %s · %s · %s · %d prompts · modes: %s\n",
		filepath.Base(s.Cwd), fmtDuration(s.End.Sub(s.Start)), entry, s.Prompts, modeChain(s.ModeChanges))

	// Execution: totals + per-tool counts, most-used first.
	failed := 0
	byTool := map[string]int{}
	for _, c := range s.ToolCalls {
		byTool[c.Name]++
		if c.IsErr {
			failed++
		}
	}
	names := make([]string, 0, len(byTool))
	for n := range byTool {
		names = append(names, n)
	}
	sort.Slice(names, func(i, j int) bool {
		if byTool[names[i]] != byTool[names[j]] {
			return byTool[names[i]] > byTool[names[j]]
		}
		return names[i] < names[j]
	})
	failPct := 0.0
	if len(s.ToolCalls) > 0 {
		failPct = 100 * float64(failed) / float64(len(s.ToolCalls))
	}
	fmt.Fprintf(w, "\nExecution  %d tool calls · %d failed (%.1f%%)\n", len(s.ToolCalls), failed, failPct)
	const topTools = 8
	for i, n := range names {
		if i >= topTools {
			fmt.Fprintf(w, "           … %d more tools\n", len(names)-topTools)
			break
		}
		fmt.Fprintf(w, "           %-22s %d\n", n, byTool[n])
	}

	// Waste: files Read more than once (per distinct target).
	reads := map[string]int{}
	for _, c := range s.ToolCalls {
		if c.Name == "Read" && c.Target != "" {
			reads[c.Target]++
		}
	}
	type rr struct {
		target string
		n      int
	}
	var dups []rr
	for t, n := range reads {
		if n > 1 {
			dups = append(dups, rr{t, n})
		}
	}
	sort.Slice(dups, func(i, j int) bool {
		if dups[i].n != dups[j].n {
			return dups[i].n > dups[j].n
		}
		return dups[i].target < dups[j].target
	})
	if len(dups) == 0 {
		fmt.Fprintf(w, "\nWaste      no files were Read more than once\n")
	} else {
		fmt.Fprintf(w, "\nWaste      %d file(s) Read 2+ times:\n", len(dups))
		for i, d := range dups {
			if i >= 5 {
				fmt.Fprintf(w, "           … %d more\n", len(dups)-5)
				break
			}
			fmt.Fprintf(w, "           %-50s ×%d\n", trimRight(filepath.Base(d.target), 50), d.n)
		}
	}

	usd, unpriced := sessionCost(s, table)
	cost := ui.FormatUSD(usd)
	if unpriced > 0 {
		cost += fmt.Sprintf(" ⚠ +%d unpriced turn(s) — model not in pricing table", unpriced)
	}
	fmt.Fprintf(w, "\nTokens     in %s · out %s · cache-w %s · cache-r %s · %s\n",
		ui.FormatTokShort(s.Tokens.InputTokens),
		ui.FormatTokShort(s.Tokens.OutputTokens),
		ui.FormatTokShort(s.Tokens.CacheCreationInputTokens),
		ui.FormatTokShort(s.Tokens.CacheReadInputTokens),
		cost)
	fmt.Fprintf(w, "Context    peak ≈ %s tok (input+cache, single request)\n", ui.FormatTokShort(s.PeakContext))
}

// timelineEvent is one merged line: tool call, mode change, or priced turn.
type timelineEvent struct {
	time time.Time
	line string
}

// writeTimeline renders the chronological audit log. Pure for testing.
func writeTimeline(w io.Writer, s *session.Session, table pricing.Table) {
	tsFmt := "15:04:05"
	if s.End.Sub(s.Start) > 24*time.Hour {
		tsFmt = "01-02 15:04:05"
	}

	subTag := func(sub bool) string {
		if sub {
			return "  (sub)"
		}
		return ""
	}

	events := make([]timelineEvent, 0, len(s.ToolCalls)+len(s.ModeChanges)+len(s.Turns))
	for _, c := range s.ToolCalls {
		status := "ok"
		switch {
		case c.IsErr:
			status = "ERR"
		case !c.HasResult:
			status = "?"
		}
		target := strings.ReplaceAll(c.Target, "\n", " ")
		events = append(events, timelineEvent{c.Time, fmt.Sprintf("%-10s %-52s %-3s%s",
			c.Name, trimRight(target, 52), status, subTag(c.Sub))})
	}
	for _, m := range s.ModeChanges {
		warn := ""
		if m.To == "bypassPermissions" {
			warn = "  ⚠"
		}
		from := m.From
		if from == "" {
			from = "(start)"
		}
		events = append(events, timelineEvent{m.Time, fmt.Sprintf("%-10s %s → %s%s", "mode", from, m.To, warn)})
	}
	for _, t := range s.Turns {
		cost := "+$?" // model missing from the pricing table: unknown, not free
		if table.Has(t.Model) {
			cost = "+" + ui.FormatUSD(table.Cost(t.Model, t.Usage))
		}
		events = append(events, timelineEvent{t.Time, fmt.Sprintf("%-10s %-52s %s%s",
			"turn", shortModelTag(t.Model), cost, subTag(t.Sub))})
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].time.Before(events[j].time) })

	fmt.Fprintf(w, "Session %s — %s → %s · %d events\n\n",
		s.ID, s.Start.Local().Format("2006-01-02 15:04"), s.End.Local().Format("2006-01-02 15:04"), len(events))
	for _, e := range events {
		fmt.Fprintf(w, "%s  %s\n", e.time.Local().Format(tsFmt), strings.TrimRight(e.line, " "))
	}
}

func runScorecard(root string, table pricing.Table, idPrefix string) {
	writeScorecard(os.Stdout, loadSession(root, idPrefix), table)
}

func runTimeline(root string, table pricing.Table, idPrefix string) {
	writeTimeline(os.Stdout, loadSession(root, idPrefix), table)
}
