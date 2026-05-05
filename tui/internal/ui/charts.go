package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// renderDailySparkline returns a 3-line block-character sparkline of
// the last 30 days of spend, plus a leading header line summarising
// the window. Used by both the minimal and split views so the same
// "last 30 days" diagram is reachable from any TUI mode.
//
// The output is empty when daily is empty (caller should skip rendering
// to avoid a hanging header). Stateless: rebuilds from the snapshot
// each tick, no hidden bubbles.
func renderDailySparkline(daily []agg.DailyTotal) string {
	if len(daily) == 0 {
		return ""
	}

	// Find the largest USD value for normalisation. A floor of 0.0001
	// keeps the math safe when every day is zero.
	var maxV float64
	for _, d := range daily {
		if d.USD > maxV {
			maxV = d.USD
		}
	}
	if maxV <= 0 {
		maxV = 0.0001
	}

	// 8-level block characters: each cell maps `usd/maxV` into one of
	//   space, ▁ ▂ ▃ ▄ ▅ ▆ ▇ █
	// Today (the last entry) gets a brighter style so the user knows
	// where "now" is on the chart. We need a rune slice (not a string
	// indexed by byte) because the block chars are multi-byte UTF-8.
	levels := []rune(" ▁▂▃▄▅▆▇█")
	bars := make([]rune, 0, len(daily))
	for _, d := range daily {
		idx := int(d.USD / maxV * 8)
		if idx < 0 {
			idx = 0
		}
		if idx >= len(levels) {
			idx = len(levels) - 1
		}
		bars = append(bars, levels[idx])
	}

	// Color the bars: today (last) bright green, the rest dim green.
	bright := lipgloss.NewStyle().Foreground(lipgloss.Color("10")).Bold(true)
	dim := lipgloss.NewStyle().Foreground(lipgloss.Color("78"))

	var sb strings.Builder
	for i, r := range bars {
		if i == len(bars)-1 {
			sb.WriteString(bright.Render(string(r)))
		} else {
			sb.WriteString(dim.Render(string(r)))
		}
	}
	chart := sb.String()

	// Header: range + window total. Mirrors the Swift app's static
	// summary when nothing is hovered.
	var total float64
	for _, d := range daily {
		total += d.USD
	}
	header := fmt.Sprintf("last 30 days  %s…%s · %s",
		shortDay(daily[0].Day),
		shortDay(daily[len(daily)-1].Day),
		FormatUSD(total),
	)
	return styleDim.Render(header) + "\n" + chart + "\n"
}

// renderDailyTokensSparkline mirrors `renderDailySparkline` but plots
// total tokens per day (input + output + cache-create + cache-read)
// and tints in blue so the two stacked charts read as distinct rows
// at a glance — green for cost, blue for tokens. The header shows the
// window range, total token volume AND total cost so a quick glance
// answers "did spending track usage?" in one row.
func renderDailyTokensSparkline(daily []agg.DailyTotal) string {
	if len(daily) == 0 {
		return ""
	}

	// Largest token count for normalisation; floor of 1 keeps the
	// math safe when every day is zero-token (cold install).
	var maxV uint64
	for _, d := range daily {
		if d.Tokens > maxV {
			maxV = d.Tokens
		}
	}
	if maxV == 0 {
		maxV = 1
	}

	// Same 8-level block ramp as the cost chart so both sparklines
	// have identical visual weight per cell — only the colour differs.
	levels := []rune(" ▁▂▃▄▅▆▇█")
	bars := make([]rune, 0, len(daily))
	for _, d := range daily {
		idx := int(float64(d.Tokens) / float64(maxV) * 8)
		if idx < 0 {
			idx = 0
		}
		if idx >= len(levels) {
			idx = len(levels) - 1
		}
		bars = append(bars, levels[idx])
	}

	// Blue palette mirrors the Swift app's `MonthlyTokenChartRow`:
	// today is bright (color 12 = bold blue), the rest dim (color 75
	// = soft slate-blue). Distinct enough from the cost chart's
	// greens (10 / 78) that a quick glance can't mix them up.
	bright := lipgloss.NewStyle().Foreground(lipgloss.Color("12")).Bold(true)
	dim := lipgloss.NewStyle().Foreground(lipgloss.Color("75"))

	var sb strings.Builder
	for i, r := range bars {
		if i == len(bars)-1 {
			sb.WriteString(bright.Render(string(r)))
		} else {
			sb.WriteString(dim.Render(string(r)))
		}
	}
	chart := sb.String()

	var totalTokens uint64
	var totalUSD float64
	for _, d := range daily {
		totalTokens += d.Tokens
		totalUSD += d.USD
	}
	header := fmt.Sprintf("last 30 days · tokens  %s…%s · %s · %s",
		shortDay(daily[0].Day),
		shortDay(daily[len(daily)-1].Day),
		FormatTokens(totalTokens),
		FormatUSD(totalUSD),
	)
	return styleDim.Render(header) + "\n" + chart + "\n"
}

// FormatTokens renders a token count in the K / M / B convention used
// across both the TUI and the macapp so the two stay visually consistent.
//
//	0          → "0"
//	1234       → "1K"
//	12345      → "12K"
//	1234567    → "1.2M"
//	1234567890 → "1.23B"
func FormatTokens(n uint64) string {
	switch {
	case n >= 1_000_000_000:
		return fmt.Sprintf("%.2fB", float64(n)/1_000_000_000)
	case n >= 1_000_000:
		return fmt.Sprintf("%.1fM", float64(n)/1_000_000)
	case n >= 1_000:
		return fmt.Sprintf("%.0fK", float64(n)/1_000)
	default:
		return fmt.Sprintf("%d", n)
	}
}

// shortDay turns "2026-04-26" into "Apr 26". Falls back to the input
// when parsing fails (so a misshapen day key never crashes a render).
func shortDay(ymd string) string {
	if len(ymd) != 10 || ymd[4] != '-' || ymd[7] != '-' {
		return ymd
	}
	month := monthsShort[ymd[5:7]]
	if month == "" {
		return ymd
	}
	day := ymd[8:10]
	if day[0] == '0' {
		day = day[1:]
	}
	return month + " " + day
}

var monthsShort = map[string]string{
	"01": "Jan", "02": "Feb", "03": "Mar", "04": "Apr",
	"05": "May", "06": "Jun", "07": "Jul", "08": "Aug",
	"09": "Sep", "10": "Oct", "11": "Nov", "12": "Dec",
}
