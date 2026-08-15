package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// renderSeries draws one row per grouped series, ordered by spend. The
// share column is of the rendered total, so it always sums to 100%
// whichever mode is active.
//
// barWidth controls whether each row also gets a colour-coded inline
// bar (reusing view_split.go's inlineBar/modelBarStyle): 0 renders a
// plain table (viewMinimal), any positive width renders a bar of that
// width (viewSplit/viewFull, which pass splitBarWidth).
//
// rowCoverage carries each row's usage-bearing coverage (from
// agg.GroupCoverage, keyed the same way as series) so a row computed
// from partial data can be marked as a floor rather than a total.
func renderSeries(series map[string]agg.ModelDay, rowCoverage map[string]agg.Coverage, mode agg.Mode, barWidth int) string {
	if len(series) == 0 {
		return ""
	}
	names := make([]string, 0, len(series))
	var total float64
	for n, v := range series {
		names = append(names, n)
		total += v.USD
	}
	sort.Slice(names, func(i, j int) bool {
		if series[names[i]].USD != series[names[j]].USD {
			return series[names[i]].USD > series[names[j]].USD
		}
		return names[i] < names[j] // stable for equal spend
	})

	var b strings.Builder
	for _, n := range names {
		frac := 0.0
		if total > 0 {
			frac = series[n].USD / total
		}
		bar := ""
		if barWidth > 0 {
			bar = inlineBar(barWidth, frac, modelBarStyle(n)) + " "
		}
		// The name is not shortened: a source label like "claude/work"
		// loses its meaning if truncated to its vendor.
		b.WriteString(fmt.Sprintf("  %-22s %s%10s  %3.0f%%%s\n",
			n, bar, FormatUSD(series[n].USD), frac*100, coverageSuffix(rowCoverage[n])))
	}
	return b.String()
}

// coverageSuffix marks a figure computed from partial data. Rendered
// inline rather than as a footnote: a user scanning the table for a
// dollar amount must see the caveat attached to that amount, not at the
// bottom of the pane.
func coverageSuffix(c agg.Coverage) string {
	if !c.Partial() {
		return ""
	}
	return styleDim.Render(fmt.Sprintf(" ~%.0f%%", c.Fraction()*100))
}

// renderModeBar shows the four modes with the active one bracketed, so
// the cycle key is discoverable without a legend.
func renderModeBar(mode agg.Mode) string {
	parts := make([]string, 0, 4)
	for _, m := range []agg.Mode{agg.GroupModel, agg.GroupVendor, agg.GroupSource, agg.GroupTotal} {
		if m == mode {
			parts = append(parts, "["+m.String()+"]")
			continue
		}
		parts = append(parts, m.String())
	}
	return styleDim.Render("group: "+strings.Join(parts, " ")+"   (v)") + "\n"
}
