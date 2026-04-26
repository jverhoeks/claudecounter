package ui

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/internal/agg"
)

// TestViewMinimal_SparklineRenders is a smoke test: with a non-empty
// daily series, viewMinimal must include the "last 30 days" header and
// a sparkline body (non-empty extra lines below the totals).
func TestViewMinimal_SparklineRenders(t *testing.T) {
	totals := agg.Totals{
		Day:   map[string]agg.ModelDay{"claude-opus-4-7": {USD: 12.34}},
		Month: map[string]agg.ModelDay{"claude-opus-4-7": {USD: 100.00}},
		Daily: []agg.DailyTotal{
			{Day: "2026-04-01", USD: 5},
			{Day: "2026-04-02", USD: 12},
			{Day: "2026-04-03", USD: 8},
			{Day: "2026-04-04", USD: 20},
			{Day: "2026-04-05", USD: 0},
			{Day: "2026-04-06", USD: 16},
		},
	}
	out := viewMinimal(totals)
	if !strings.Contains(out, "last 30 days") {
		t.Errorf("expected sparkline header in output:\n%s", out)
	}
	// Sparkline View() returns at least one non-empty rune line.
	lines := strings.Split(out, "\n")
	hasChartLine := false
	for _, l := range lines {
		stripped := strings.TrimSpace(l)
		if stripped != "" && !strings.Contains(l, "Today") && !strings.Contains(l, "Month") &&
			!strings.Contains(l, "last 30 days") && !strings.Contains(l, "Opus") {
			hasChartLine = true
			break
		}
	}
	if !hasChartLine {
		t.Errorf("expected at least one chart body line below the sparkline header:\n%s", out)
	}
}
