package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// modelBarStyle assigns a consistent colour per model family so the
// horizontal bars are readable at a glance. The model-specific cases
// come first and the vendor-level ones after, since a model id like
// "claude-opus-4-7" contains both "claude" and "opus" — checking vendor
// first would flatten every Claude model to one colour.
func modelBarStyle(model string) lipgloss.Style {
	switch {
	case strings.Contains(model, "opus"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("13")) // magenta
	case strings.Contains(model, "sonnet"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("12")) // blue
	case strings.Contains(model, "haiku"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("10")) // green
	case strings.Contains(model, "claude"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("5")) // purple
	case strings.Contains(model, "codex"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("11")) // yellow
	case strings.Contains(model, "grok"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("9")) // bright red
	}
	return lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
}

// inlineBar renders a fixed-width bar where `frac` (0..1) of the cells
// are filled with the styled glyph and the rest with a dim track. This
// replaces ntcharts' horizontal barchart for the split view: that
// component required a separate canvas and produced misaligned
// rendering for the small (≤4 bars) chart we want here.
func inlineBar(width int, frac float64, style lipgloss.Style) string {
	if frac < 0 {
		frac = 0
	}
	if frac > 1 {
		frac = 1
	}
	filled := int(float64(width)*frac + 0.5)
	if filled > width {
		filled = width
	}
	bar := style.Render(strings.Repeat("█", filled))
	track := styleDim.Render(strings.Repeat("░", width-filled))
	return bar + track
}

// splitBarWidth is the inline-bar width passed to renderSeries so the
// split view keeps its colour-coded bar chart; viewMinimal passes 0 for
// the same call to render a plain table instead.
const splitBarWidth = 24

func viewSplit(t agg.Totals, gauges string, mode agg.Mode) string {
	var b strings.Builder
	dayTotal := sumUSD(t.Day)
	monthTotal := sumUSD(t.Month)

	b.WriteString(fmt.Sprintf("%s  %s    %s %s\n",
		styleHead.Render("Today"),
		styleMoney.Render(FormatUSD(dayTotal)),
		styleHead.Render("Month"),
		styleMoney.Render(FormatUSD(monthTotal)),
	))
	b.WriteString(styleDim.Render(strings.Repeat("─", 60)) + "\n")
	// The rule above closes the headline, not the gauge block — so
	// gauges render after it, the same relative position viewMinimal
	// puts them in (right after the totals, before anything else).
	if gauges != "" {
		b.WriteString(gauges)
	}

	b.WriteString(renderModeBar(mode))
	b.WriteString(renderSeries(agg.Group(t.Day, mode), agg.GroupCoverage(t.Day, t.Coverage, mode), mode, splitBarWidth))

	// 30-day spend trend, then the parallel 30-day token-volume trend.
	// Same renderers as the minimal view so the charts are visually
	// consistent across the three view modes (minimal · split · full —
	// full inherits this via viewSplit).
	if chart := renderDailySparkline(t.Daily); chart != "" {
		b.WriteString(styleDim.Render(strings.Repeat("─", 60)) + "\n")
		b.WriteString(chart)
	}
	if chart := renderDailyTokensSparkline(t.Daily); chart != "" {
		b.WriteString(chart)
	}
	return b.String()
}
