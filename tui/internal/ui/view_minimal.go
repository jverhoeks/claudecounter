package ui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

var (
	styleMoney = lipgloss.NewStyle().Foreground(lipgloss.Color("10")).Bold(true)
	styleDim   = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	styleHead  = lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true)
)

func sumUSD(m map[agg.SeriesKey]agg.ModelDay) float64 {
	var s float64
	for _, v := range m {
		s += v.USD
	}
	return s
}

// shortModel returns a compact model id, e.g. "Opus" or "Sonnet".
func shortModel(id string) string {
	switch {
	case strings.Contains(id, "opus"):
		return "Opus"
	case strings.Contains(id, "sonnet"):
		return "Sonnet"
	case strings.Contains(id, "haiku"):
		return "Haiku"
	default:
		return id
	}
}

func viewMinimal(t agg.Totals, gauges string, mode agg.Mode) string {
	var b strings.Builder
	b.WriteString(styleHead.Render("Today") + "     " + styleMoney.Render(FormatUSD(sumUSD(t.Day))) + "\n")
	b.WriteString(styleHead.Render("Month") + "     " + styleMoney.Render(FormatUSD(sumUSD(t.Month))) + "\n")
	if gauges != "" {
		b.WriteString(gauges)
	}

	// 30-day spend trend, then the parallel 30-day token-volume trend.
	// Same renderers as view_split / view_full so the charts are
	// consistent across all three modes.
	b.WriteString(renderDailySparkline(t.Daily))
	b.WriteString(renderDailyTokensSparkline(t.Daily))

	b.WriteString(renderModeBar(mode))
	b.WriteString(renderSeries(agg.Group(t.Day, mode), agg.GroupCoverage(t.Day, t.Coverage, mode), mode, 0))
	return b.String()
}
