package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/internal/agg"
)

// modelBarStyle assigns a consistent colour per model family so the
// horizontal bars are readable at a glance.
func modelBarStyle(model string) lipgloss.Style {
	switch {
	case strings.Contains(model, "opus"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("13")) // magenta
	case strings.Contains(model, "sonnet"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("12")) // blue
	case strings.Contains(model, "haiku"):
		return lipgloss.NewStyle().Foreground(lipgloss.Color("10")) // green
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

func viewSplit(t agg.Totals) string {
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

	names := make([]string, 0, len(t.Day))
	for name := range t.Day {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		return t.Day[names[i]].USD > t.Day[names[j]].USD
	})

	const barW = 24
	for _, n := range names {
		md := t.Day[n]
		frac := 0.0
		if dayTotal > 0 {
			frac = md.USD / dayTotal
		}
		bar := inlineBar(barW, frac, modelBarStyle(n))
		line := fmt.Sprintf("  %-7s %s %9s  %4.0f%%\n",
			shortModel(n), bar, FormatUSD(md.USD), frac*100)
		b.WriteString(line)
	}
	return b.String()
}
