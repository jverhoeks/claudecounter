package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/internal/agg"
)

var (
	styleMoney = lipgloss.NewStyle().Foreground(lipgloss.Color("10")).Bold(true)
	styleDim   = lipgloss.NewStyle().Foreground(lipgloss.Color("244"))
	styleHead  = lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true)
)

func sumUSD(m map[string]agg.ModelDay) float64 {
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

func viewMinimal(t agg.Totals) string {
	var b strings.Builder
	b.WriteString(styleHead.Render("Today") + "     " + styleMoney.Render(FormatUSD(sumUSD(t.Day))) + "\n")
	b.WriteString(styleHead.Render("Month") + "     " + styleMoney.Render(FormatUSD(sumUSD(t.Month))) + "\n")

	names := make([]string, 0, len(t.Day))
	for name := range t.Day {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		return t.Day[names[i]].USD > t.Day[names[j]].USD
	})
	parts := make([]string, 0, len(names))
	for _, n := range names {
		parts = append(parts, fmt.Sprintf("%s %s", shortModel(n), FormatUSD(t.Day[n].USD)))
	}
	if len(parts) > 0 {
		b.WriteString(styleDim.Render(strings.Join(parts, " · ")) + "\n")
	}
	return b.String()
}
