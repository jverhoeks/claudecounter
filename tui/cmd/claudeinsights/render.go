package main

import (
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
)

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

func shortProj(encoded string) string {
	if encoded == "" {
		return "(unknown)"
	}
	parts := strings.Split(strings.TrimPrefix(encoded, "-"), "-")
	if len(parts) <= 4 {
		return encoded
	}
	return strings.Join(parts[4:], "-")
}

// writeCorpus renders the ranked leaderboard. Pure (takes io.Writer).
func writeCorpus(w io.Writer, c insights.CorpusReport, topN int) {
	fmt.Fprintf(w, "Corpus  %s spent · %s estimated waste · %d sessions\n",
		ui.FormatUSD(c.TotalUSD), ui.FormatUSD(c.TotalWasteUSD), len(c.Sessions))
	fmt.Fprintln(w, strings.Repeat("─", 72))
	fmt.Fprintf(w, "Worst sessions (top %d):\n", topN)
	fmt.Fprintf(w, "  %-8s %-26s %9s %9s %8s %s\n", "session", "project", "$", "waste$", "findings", "top finding")
	for i, s := range c.Sessions {
		if i >= topN {
			break
		}
		top := ""
		if len(s.Findings) > 0 {
			top = string(s.Findings[0].Category) + ": " + s.Findings[0].Detail
		}
		fmt.Fprintf(w, "  %-8s %-26s %9s %9s %8d %s\n",
			shortID(s.ID), trimRunes(shortProj(s.Project), 26),
			ui.FormatUSD(s.USD), ui.FormatUSD(s.WasteUSD), len(s.Findings), trimRunes(top, 40))
	}
	fmt.Fprintln(w, strings.Repeat("─", 72))
	fmt.Fprintln(w, "By project (most waste first):")
	for _, p := range c.Projects {
		fmt.Fprintf(w, "  %-30s %9s · waste %9s · %d sessions · %d findings\n",
			trimRunes(shortProj(p.Project), 30), ui.FormatUSD(p.USD), ui.FormatUSD(p.WasteUSD), p.Sessions, p.Findings)
	}
}

// writeSession renders one session's drill-down. Pure.
func writeSession(w io.Writer, r insights.SessionReport) {
	fmt.Fprintf(w, "Session %s — %s\n", r.ID, filepath.Base(r.Cwd))
	fmt.Fprintf(w, "  %d prompts · %d tool calls · %s · waste %s · peak ctx %.0f%%\n",
		r.Prompts, r.ToolCalls, ui.FormatUSD(r.USD), ui.FormatUSD(r.WasteUSD), r.CtxPct)
	fmt.Fprintf(w, "  tokens: in %s · out %s · cache-w %s · cache-r %s\n",
		ui.FormatTokShort(r.Tokens.InputTokens), ui.FormatTokShort(r.Tokens.OutputTokens),
		ui.FormatTokShort(r.Tokens.CacheCreationInputTokens), ui.FormatTokShort(r.Tokens.CacheReadInputTokens))
	if len(r.Findings) == 0 {
		fmt.Fprintln(w, "\n  no structural findings 🎉")
		return
	}
	fmt.Fprintln(w, "\nFindings:")
	for _, f := range r.Findings {
		usd := ""
		if f.USD > 0 {
			usd = " (" + ui.FormatUSD(f.USD) + ")"
		}
		fmt.Fprintf(w, "  [%-7s] %s%s\n", f.Category, f.Detail, usd)
	}
}

func trimRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}
