package dashtui

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/NimbleMarkets/ntcharts/linechart/timeserieslinechart"
	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/dashboard"
	"github.com/jverhoeks/claudecounter/tui/internal/hints"
	"github.com/jverhoeks/claudecounter/tui/internal/perf"
)

// Ink and chrome, from the dark chart palette: terminals are mostly dark.
var (
	inkPrimary   = lipgloss.Color("#ffffff")
	inkSecondary = lipgloss.Color("#c3c2b7")
	inkMuted     = lipgloss.Color("#898781")
	hairline     = lipgloss.Color("#383835")
	good         = lipgloss.Color("#0ca30c")
	serious      = lipgloss.Color("#ec835a")

	title       = lipgloss.NewStyle().Bold(true).Foreground(inkPrimary).Background(lipgloss.Color("#256abf"))
	activeTab   = lipgloss.NewStyle().Bold(true).Foreground(inkPrimary).Underline(true)
	inactiveTab = lipgloss.NewStyle().Foreground(inkMuted)
	muted       = lipgloss.NewStyle().Foreground(inkMuted)
	secondary   = lipgloss.NewStyle().Foreground(inkSecondary)
	bold        = lipgloss.NewStyle().Bold(true).Foreground(inkPrimary)
	rule        = lipgloss.NewStyle().Foreground(hairline)
	warnStyle   = lipgloss.NewStyle().Foreground(serious)
	goodStyle   = lipgloss.NewStyle().Foreground(good)
	section     = lipgloss.NewStyle().Bold(true).Foreground(inkSecondary)
	selected    = lipgloss.NewStyle().Background(lipgloss.Color("#2c2c2a"))
	tile        = lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).BorderForeground(hairline).Padding(0, 1)
)

// Categorical slots in fixed order (dark steps); "other" is muted gray.
var seriesColors = []string{"#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"}

const otherColor = "#898781"

func seriesColor(name string, i int) string {
	if name == "other" || i >= len(seriesColors) {
		return otherColor
	}
	return seriesColors[i]
}

// usd matches the macapp: whole dollars from $1,000, cents below.
func usd(v float64) string {
	neg := v < 0
	v = math.Abs(v)
	var s string
	if v >= 1000 {
		s = commas(int64(math.Round(v)))
	} else {
		s = fmt.Sprintf("%.2f", v)
	}
	if neg {
		return "-$" + s
	}
	return "$" + s
}

func commas(n int64) string {
	s := strconv.FormatInt(n, 10)
	for i := len(s) - 3; i > 0; i -= 3 {
		s = s[:i] + "," + s[i:]
	}
	return s
}

func tokens(v float64) string {
	switch {
	case v >= 1e9:
		return fmt.Sprintf("%.2fB", v/1e9)
	case v >= 1e6:
		return fmt.Sprintf("%.1fM", v/1e6)
	case v >= 1e3:
		return fmt.Sprintf("%.1fK", v/1e3)
	default:
		return fmt.Sprintf("%.0f", v)
	}
}

func pct(v float64) string { return fmt.Sprintf("%.0f%%", v*100) }

func optSecs(v *float64) string {
	if v == nil {
		return "—"
	}
	return fmt.Sprintf("%.1fs", *v)
}

func optNum(v *float64) string {
	if v == nil {
		return "—"
	}
	return tokens(*v)
}

func optPct(v *float64) string {
	if v == nil {
		return "—"
	}
	return fmt.Sprintf("%.1f%%", *v*100)
}

// pad right-aligns (w > 0) or left-aligns (w < 0) s in |w| cells.
func pad(s string, w int) string {
	n := lipgloss.Width(s)
	if w < 0 {
		w = -w
		if n > w {
			return truncate(s, w)
		}
		return s + strings.Repeat(" ", w-n)
	}
	if n > w {
		return truncate(s, w)
	}
	return strings.Repeat(" ", w-n) + s
}

func (m *Model) controls(parts ...string) string {
	return secondary.Render(strings.Join(parts, muted.Render("  ·  ")))
}

func ctl(label, value, key string) string {
	return muted.Render(label+" ") + bold.Render(value) + muted.Render(" ("+key+")")
}

// ── Spend ─────────────────────────────────────────────────────────────

func (m *Model) spendTab(h int) string {
	v := m.spendView()
	unit := "$"
	if m.showTokens {
		unit = "tokens"
	}
	lines := []string{m.controls(
		ctl("range", rangeLabel(v.RangeDays), "d"),
		ctl("group", v.Dim.Label(), "g"),
		ctl("show", unit, "t"),
	)}
	kpiTitle := "All series"
	if v.Focus != "" {
		kpiTitle = v.Focus + muted.Render("  (esc shows all)")
	}
	lines = append(lines, "", section.Render(kpiTitle))
	k := v.KPIs
	tpu := "—"
	if k.TokensPerUSD != nil {
		tpu = tokens(*k.TokensPerUSD)
	}
	lines = append(lines, m.tiles([][2]string{
		{"Spend", usd(k.USD)}, {"Tokens", tokens(float64(k.Tokens))}, {"Tokens / $", tpu},
		{"Avg / day", usd(k.AvgPerDay)}, {"Cache hit", pct(k.CacheHit)}, {"Month projected", usd(k.MonthProjected)},
	}))
	legend := m.legend(v.Series, m.w-2)
	note := ""
	if v.HistoryStart != "" {
		note = muted.Render("History starts " + v.HistoryStart + ": the scan reads a year back, and only what is still on disk.")
	}
	used := lipgloss.Height(strings.Join(lines, "\n")) + lipgloss.Height(legend) + 2
	if note != "" {
		used++
	}
	chartH := max(h-used, 6)
	lines = append(lines, "", m.lineChart(v, m.w-2, chartH), legend)
	if note != "" {
		lines = append(lines, note)
	}
	return strings.Join(lines, "\n")
}

func rangeLabel(days int) string {
	if days == 365 {
		return "1y"
	}
	return fmt.Sprintf("%dd", days)
}

func (m *Model) tiles(items [][2]string) string {
	w := max((m.w-2)/len(items)-4, 8)
	var out []string
	for _, it := range items {
		out = append(out, tile.Width(w).Render(muted.Render(truncate(it[0], w-2))+"\n"+bold.Render(truncate(it[1], w-2))))
	}
	return lipgloss.JoinHorizontal(lipgloss.Top, out...)
}

func (m *Model) legend(series []dashboard.ChartSeries, w int) string {
	var items []string
	for i, s := range series {
		key := lipgloss.NewStyle().Foreground(lipgloss.Color(seriesColor(s.Name, i))).Render("━━")
		name := secondary.Render(" " + truncate(s.Name, 28))
		if m.focus != "" && s.Name == m.focus {
			name = bold.Render(" " + truncate(s.Name, 28))
		}
		items = append(items, key+name)
	}
	// Wrap onto as many lines as needed.
	var lines []string
	line := ""
	for _, it := range items {
		if line != "" && lipgloss.Width(line)+3+lipgloss.Width(it) > w {
			lines = append(lines, line)
			line = ""
		}
		if line != "" {
			line += "   "
		}
		line += it
	}
	return strings.Join(append(lines, line), "\n")
}

func (m *Model) lineChart(v *dashboard.SpendView, w, h int) string {
	if len(v.Series) == 0 {
		return muted.Render("No spend in this range.")
	}
	day := func(s string) time.Time {
		t, _ := time.ParseInLocation("2006-01-02", s, time.Local)
		return t.Add(12 * time.Hour)
	}
	value := func(s dashboard.ChartSeries, i int) float64 {
		if m.showTokens {
			return float64(s.Tokens[i])
		}
		return s.USD[i]
	}
	top := 0.0
	for _, s := range v.Series {
		for i := range v.Days {
			top = max(top, value(s, i))
		}
	}
	yfmt := func(_ int, f float64) string {
		if m.showTokens {
			return tokens(f)
		}
		if top < 10 {
			return fmt.Sprintf("$%.1f", f)
		}
		return "$" + commas(int64(math.Round(f)))
	}
	c := timeserieslinechart.New(w, h,
		timeserieslinechart.WithTimeRange(day(v.Days[0]), day(v.Days[len(v.Days)-1])),
		timeserieslinechart.WithYRange(0, max(top*1.05, 0.01)),
		timeserieslinechart.WithYLabelFormatter(yfmt),
		timeserieslinechart.WithXLabelFormatter(func(_ int, f float64) string {
			return time.Unix(int64(f), 0).Format("01/02")
		}),
		timeserieslinechart.WithAxesStyles(rule, muted),
		timeserieslinechart.WithXYSteps(max(w/14, 2), max(h/4, 2)),
	)
	// Focused series last, so it draws on top; the rest dim behind it.
	var order []string
	for i, s := range v.Series {
		color := seriesColor(s.Name, i)
		if v.Focus != "" && s.Name != v.Focus {
			color = "#383835"
		}
		c.SetDataSetStyle(s.Name, lipgloss.NewStyle().Foreground(lipgloss.Color(color)))
		for d := range v.Days {
			c.PushDataSet(s.Name, timeserieslinechart.TimePoint{Time: day(v.Days[d]), Value: value(s, d)})
		}
		if s.Name != v.Focus {
			order = append(order, s.Name)
		}
	}
	if v.Focus != "" {
		order = append(order, v.Focus)
	}
	c.DrawBrailleDataSets(order)
	return c.View()
}

// ── Heatmap ───────────────────────────────────────────────────────────

var weekdays = []string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

func (m *Model) heatmapTab(h int) string {
	v := m.spendView()
	grid := v.Heatmap
	capV := dashboard.HeatCap(grid)
	head := fmt.Sprintf("When you spend · last %d days, weekday × hour", dashboard.HeatmapDays)
	if v.HeatmapFocus != "" {
		head += " · " + v.HeatmapFocus
	} else if v.Dim == dashboard.DimModel {
		head += muted.Render(" · focus a model on the Tables tab to see just its spend")
	}
	cellW := min(max((m.w-2-5-14)/24, 2), 6)
	rowH := min(max((h-8)/7, 1), 3)
	var rows []string
	for d := 0; d < 7; d++ {
		for r := 0; r < rowH; r++ {
			label := "    "
			if r == rowH/2 {
				label = weekdays[d] + " "
			}
			var b strings.Builder
			b.WriteString(muted.Render(label))
			for hr := 0; hr < 24; hr++ {
				col := dashboard.HeatColor(grid[d][hr] / capV)
				b.WriteString(lipgloss.NewStyle().Background(lipgloss.Color(col)).Render(strings.Repeat(" ", cellW)))
			}
			rows = append(rows, b.String())
		}
	}
	var axis strings.Builder
	axis.WriteString("    ")
	for hr := 0; hr < 24; hr += 3 {
		axis.WriteString(pad(fmt.Sprintf("%02d", hr), -3*cellW))
	}
	rows = append(rows, muted.Render(axis.String()))

	// Vertical legend: cap at the top, $0 at the bottom.
	n := len(rows) - 1
	legend := make([]string, n)
	for i := 0; i < n; i++ {
		t := 1 - float64(i)/float64(max(n-1, 1))
		legend[i] = "  " + lipgloss.NewStyle().Background(lipgloss.Color(dashboard.HeatColor(t))).Render("  ")
	}
	legend[0] += " " + muted.Render(usd(capV)+"+")
	legend[n-1] += " " + muted.Render(usd(0))
	field := lipgloss.JoinHorizontal(lipgloss.Top, strings.Join(rows, "\n"), strings.Join(legend, "\n"))

	// The terminal has no hover: list the busiest hours instead.
	type cell struct {
		d, h int
		v    float64
	}
	var cells []cell
	total := 0.0
	for d := 0; d < 7; d++ {
		for hr := 0; hr < 24; hr++ {
			total += grid[d][hr]
			if grid[d][hr] > 0 {
				cells = append(cells, cell{d, hr, grid[d][hr]})
			}
		}
	}
	sort.Slice(cells, func(i, j int) bool { return cells[i].v > cells[j].v })
	var busiest []string
	for i, c := range cells {
		if i == 5 {
			break
		}
		busiest = append(busiest, fmt.Sprintf("%s %02d:00 %s", weekdays[c.d], c.h, bold.Render(usd(c.v))))
	}
	summary := secondary.Render(fmt.Sprintf("Total %s over %d days.", usd(total), dashboard.HeatmapDays))
	if len(busiest) > 0 {
		summary += secondary.Render("  Busiest: ") + strings.Join(busiest, muted.Render(" · "))
	}
	return strings.Join([]string{section.Render(head), "", field, "", summary}, "\n")
}

// ── Effort map ────────────────────────────────────────────────────────

func (m *Model) effortTab(h int) string {
	r := m.perfReport()
	effort := m.effort
	if effort == "" {
		effort = "all"
	}
	lines := []string{m.controls(
		ctl("range", fmt.Sprintf("%dd", perfRanges[m.perfRangeIdx]), "d"),
		ctl("agent", string(perfAgents[m.agentIdx]), "a"),
		ctl("effort", effort, "e"),
		ctl("cells", metricNames[m.metric], "m"),
	)}
	if r.Requests == 0 {
		return strings.Join(append(lines, "", muted.Render("No requests in this range.")), "\n")
	}
	ttft, itl := "—", "—"
	if r.Fit != nil {
		ttft = fmt.Sprintf("%.1fs ±%.1f", r.Fit.TTFT, 2*r.Fit.TTFTSD)
		itl = fmt.Sprintf("%.1fms · %.0f t/s", r.Fit.ITLMs, r.Fit.TokensPerSecond())
	}
	lines = append(lines, "", m.tiles([][2]string{
		{"Requests", commas(int64(r.Requests))},
		{"E2E p50 / p90", optSecs(r.E2EP50) + " / " + optSecs(r.E2EP90)},
		{"First block p50", optSecs(r.FirstBlockP50)},
		{"Est. TTFT @50k", ttft},
		{"Est. ITL", itl},
		{"Cache hit", optPct(r.CacheHit)},
		{"Tool misuse", optPct(r.Misuse)},
	}))
	lines = append(lines, "", section.Render("Model × effort · "+metricNames[m.metric]))
	lines = append(lines, m.effortMatrix(r)...)
	lines = append(lines, "", section.Render("All models"))
	lines = append(lines, m.modelsTable(r)...)
	return strings.Join(lines, "\n")
}

func (m *Model) cellValue(c perf.EffortCell) (float64, string, bool) {
	switch m.metric {
	case metricE2E:
		if c.E2EP50 == nil {
			return 0, "—", false
		}
		return *c.E2EP50, fmt.Sprintf("%.1fs", *c.E2EP50), true
	case metricOutput:
		if c.OutputP50 == nil {
			return 0, "—", false
		}
		return *c.OutputP50, tokens(*c.OutputP50), true
	case metricThinking:
		if c.ThinkingP50 == nil {
			return 0, "—", false
		}
		return *c.ThinkingP50, tokens(*c.ThinkingP50), true
	default:
		return c.Share, fmt.Sprintf("%.0f%% · %s", c.Share*100, tokens(float64(c.Count))), true
	}
}

// seqColor is the sequential blue ramp for the dark surface: near zero
// recedes toward the surface, the maximum is the lightest step.
func seqColor(t float64) (bg, fg string) {
	stops := []uint32{0x1f2a3a, 0x184f95, 0x256abf, 0x3987e5, 0x6da7ec, 0x9ec5f4, 0xcde2fb}
	t = min(max(t, 0), 1)
	p := t * float64(len(stops)-1)
	i := min(int(p), len(stops)-2)
	f := p - float64(i)
	ch := func(sh uint) float64 {
		a, b := float64(stops[i]>>sh&0xff), float64(stops[i+1]>>sh&0xff)
		return a + (b-a)*f
	}
	r, g, b := ch(16), ch(8), ch(0)
	fg = "#ffffff"
	if 0.2126*r+0.7152*g+0.0722*b > 140 {
		fg = "#0b0b0b"
	}
	return fmt.Sprintf("#%02x%02x%02x", int(r), int(g), int(b)), fg
}

func (m *Model) effortMatrix(r *perf.Report) []string {
	var models []string
	cells := map[string]perf.EffortCell{}
	top := 0.0
	for _, c := range r.EffortMatrix {
		if _, ok := cells[c.Model+"\x00"]; !ok {
			cells[c.Model+"\x00"] = c
			models = append(models, c.Model)
		}
		cells[c.Model+"\x00"+c.Effort] = c
		if v, _, ok := m.cellValue(c); ok {
			top = max(top, v)
		}
	}
	nameW := 22
	cellW := min(max((m.w-4-nameW)/len(perf.Efforts), 10), 18)
	head := pad("", -nameW)
	for _, e := range perf.Efforts {
		head += muted.Render(pad(e, cellW))
	}
	out := []string{head}
	for _, model := range models {
		line := secondary.Render(pad(model, -nameW))
		for _, e := range perf.Efforts {
			c, ok := cells[model+"\x00"+e]
			if !ok {
				line += muted.Render(pad("·", cellW))
				continue
			}
			v, label, has := m.cellValue(c)
			if !has || top <= 0 {
				line += muted.Render(pad(label, cellW))
				continue
			}
			bg, fg := seqColor(v / top)
			line += " " + lipgloss.NewStyle().Background(lipgloss.Color(bg)).Foreground(lipgloss.Color(fg)).
				Render(pad(label+" ", cellW-1))
		}
		out = append(out, line)
	}
	return out
}

func (m *Model) modelsTable(r *perf.Report) []string {
	head := pad("Model", -22) + pad("Requests", 10) + pad("E2E p50", 10) + pad("1st blk", 10) +
		pad("TTFT@50k", 12) + pad("ITL ms", 9) + pad("tok/s", 8) + pad("Misuse", 9) + "  Drift"
	out := []string{muted.Render(head)}
	for _, row := range r.Models {
		ttft, itl, tps := "—", "—", "—"
		if row.Fit != nil {
			ttft = fmt.Sprintf("%.1fs", row.Fit.TTFT)
			itl = fmt.Sprintf("%.1f", row.Fit.ITLMs)
			tps = fmt.Sprintf("%.0f", row.Fit.TokensPerSecond())
		}
		var drift []string
		for _, d := range []struct {
			name string
			v    *perf.Drift
		}{{"TTFT", row.TTFTDrift}, {"ITL", row.ITLDrift}, {"misuse", row.MisuseDrift}} {
			if d.v != nil && d.v.Significant() {
				drift = append(drift, fmt.Sprintf("%s %+.0f%%", d.name, d.v.Relative()*100))
			}
		}
		line := pad(row.Model, -22) + pad(commas(int64(row.Requests)), 10) + pad(optSecs(row.E2EP50), 10) +
			pad(optSecs(row.FirstBlockP50), 10) + pad(ttft, 12) + pad(itl, 9) + pad(tps, 8) + pad(optPct(row.Misuse), 9)
		out = append(out, secondary.Render(line)+"  "+warnStyle.Render(strings.Join(drift, " ")))
	}
	return out
}

// ── Tables ────────────────────────────────────────────────────────────

func (m *Model) tablesTab(h int) string {
	v := m.spendView()
	rows := m.sortedRows()
	sortName := "name"
	if m.sortCol >= 0 {
		sortName = columns[m.sortCol]
	}
	lines := []string{m.controls(
		ctl("range", rangeLabel(v.RangeDays), "d"),
		ctl("group", v.Dim.Label(), "g"),
		ctl("sort", sortName, "s"),
	), "", section.Render(fmt.Sprintf("By %s · last %d days · enter focuses a row", v.Dim.Label(), v.RangeDays))}

	nameW := max(min(m.w-2-6*12-2, 40), 16)
	head := "  " + pad(v.Dim.Label(), -nameW)
	for i, c := range columns {
		if i == m.sortCol {
			c += "▾"
		}
		head += pad(c, 12)
	}
	lines = append(lines, muted.Render(head))

	subLines := m.subscriptions(v)
	room := max(h-len(lines)-len(subLines)-3, 3)
	start := 0
	if m.cursor >= room {
		start = m.cursor - room + 1
	}
	for i := start; i < len(rows) && i < start+room; i++ {
		r := rows[i]
		spend := usd(r.USD)
		if r.Coverage < agg.PartialCoverageThreshold {
			spend = fmt.Sprintf("~%.0f%% %s", r.Coverage*100, spend)
		}
		tpu := "—"
		if r.TokensPerUSD != nil {
			tpu = tokens(*r.TokensPerUSD)
		}
		marker := "  "
		if r.Name == m.focus {
			marker = "● "
		}
		line := marker + pad(r.Name, -nameW) + pad(spend, 12) + pad(pct(r.Share), 12) + pad(tokens(float64(r.Tokens)), 12) +
			pad(tpu, 12) + pad(tokens(float64(r.Output)), 12) + pad(pct(r.CacheHit), 12)
		if i == m.cursor {
			line = selected.Render(pad(line, -(m.w - 2)))
		} else {
			line = secondary.Render(line)
		}
		lines = append(lines, line)
	}
	if len(rows) == 0 {
		lines = append(lines, muted.Render("  No spend in this range."))
	} else if len(rows) > room {
		lines = append(lines, muted.Render(fmt.Sprintf("  %d of %d rows · ↑↓ to scroll", min(room, len(rows)), len(rows))))
	}
	lines = append(lines, "")
	lines = append(lines, subLines...)
	return strings.Join(lines, "\n")
}

func (m *Model) subscriptions(v *dashboard.SpendView) []string {
	out := []string{section.Render("Subscriptions · API-equivalent spend vs fee")}
	head := pad("Source", -28) + pad("Fee / month", 13)
	for _, p := range dashboard.Periods {
		head += pad("This "+string(p), 26)
	}
	out = append(out, muted.Render(head))
	for _, s := range v.Subs {
		fee := "—"
		if s.FeeUSD > 0 {
			fee = usd(s.FeeUSD)
		}
		line := secondary.Render(pad(s.Source, -28) + pad(fee, 13))
		for _, p := range s.Periods {
			cell := usd(p.APIUSD)
			if p.FeeUSD > 0 {
				ratio := p.APIUSD / p.FeeUSD
				style := warnStyle
				if p.APIUSD >= p.FeeUSD {
					style = goodStyle
				}
				extra := fmt.Sprintf(" %.1f× of %s", ratio, usd(p.FeeUSD))
				line += pad(secondary.Render(cell)+style.Render(extra), 26)
			} else {
				line += secondary.Render(pad(cell, 26))
			}
		}
		out = append(out, line)
	}
	out = append(out, muted.Render("Spend is what the same usage would cost at API prices; set monthly_fee_usd per source in sources.toml. The fee is prorated (a week is 7/365 of a year's fees)."))
	return out
}

// ── Hints ─────────────────────────────────────────────────────────────

func (m *Model) hintsTab(h int) string {
	days := hints.Periods[m.hintsIdx]
	hs := m.hintsFor()
	period := hints.InPeriod(m.data.Samples, days, m.data.Spend.AsOf)
	w := min(m.w-4, 100)
	wrapS := lipgloss.NewStyle().Width(w)
	lines := []string{
		m.controls(ctl("period", fmt.Sprintf("last %d days", days), "d")) + "   " +
			secondary.Render(usd(hints.Spend(period, m.data.Pricing))+" spent in the period at API prices"),
		"",
		muted.Render(wrapS.Render(hints.Disclaimer)),
	}
	if len(hs) == 0 {
		lines = append(lines, "", goodStyle.Render("✓ Nothing worth changing in this period."))
	}
	for _, x := range hs {
		saving := "≈ " + usd(x.SavingUSD)
		per := fmt.Sprintf("in %d days · ≈ %s/month", days, usd(hints.PerMonth(x.SavingUSD, days)))
		if days == 30 {
			per = "in 30 days"
		}
		card := []string{
			bold.Render(x.Title) + "   " + bold.Render(saving) + " " + muted.Render(per),
			wrapS.Render(x.Finding),
			secondary.Render(wrapS.Render(x.Fix)),
		}
		if x.Snippet != "" {
			card = append(card, lipgloss.NewStyle().Foreground(lipgloss.Color("#9ec5f4")).Render("  "+x.Snippet))
		}
		if x.Applied != "" {
			card = append(card, goodStyle.Render("✓ Applied ")+muted.Render(x.Applied))
		} else {
			card = append(card, warnStyle.Render("⚠ Trade-off ")+muted.Render(x.Caveat))
		}
		lines = append(lines, "", tile.Width(w+2).Render(strings.Join(card, "\n")))
	}
	all := strings.Split(strings.Join(lines, "\n"), "\n")
	m.scroll = min(m.scroll, max(len(all)-h, 0))
	return strings.Join(all[m.scroll:], "\n")
}
