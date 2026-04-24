package ui

import (
	"strings"

	"github.com/jjverhoeks/claudecounter/internal/agg"
)

func viewFull(t agg.Totals, recent []string) string {
	var b strings.Builder
	b.WriteString(viewSplit(t))
	b.WriteString(styleDim.Render(strings.Repeat("─", 48)) + "\n")
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
