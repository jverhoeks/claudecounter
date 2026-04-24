package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jjverhoeks/claudecounter/internal/agg"
)

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
