package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/NimbleMarkets/ntcharts/barchart"
	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/internal/agg"
)

// modelBarPalette assigns a consistent colour per model family so the
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
	b.WriteString(styleDim.Render(strings.Repeat("─", 48)) + "\n")

	names := make([]string, 0, len(t.Day))
	for name := range t.Day {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		return t.Day[names[i]].USD > t.Day[names[j]].USD
	})

	// Horizontal barchart, one bar per model. Width is generous so the
	// labels (left) and values (right) breathe; height = number of bars.
	if len(names) > 0 && dayTotal > 0 {
		const chartW = 48
		bars := make([]barchart.BarData, 0, len(names))
		for _, n := range names {
			md := t.Day[n]
			bars = append(bars, barchart.BarData{
				Label: fmt.Sprintf("%-7s", shortModel(n)),
				Values: []barchart.BarValue{{
					Name:  n,
					Value: md.USD,
					Style: modelBarStyle(n),
				}},
			})
		}
		bc := barchart.New(chartW, len(bars), barchart.WithHorizontalBars())
		bc.PushAll(bars)
		bc.Draw()
		b.WriteString(bc.View() + "\n")
	}

	// Keep the per-model amount + percentage list below the chart so
	// you still get the exact dollar values at a glance.
	for _, n := range names {
		md := t.Day[n]
		pct := 0.0
		if dayTotal > 0 {
			pct = md.USD / dayTotal * 100
		}
		line := fmt.Sprintf("  %-14s %9s  %4.0f%%\n", shortModel(n), FormatUSD(md.USD), pct)
		if pct < 10 {
			line = styleDim.Render(line)
		}
		b.WriteString(line)
	}
	return b.String()
}
