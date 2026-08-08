package ui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/planlimits"
)

// Band groups rows by rough duration. A band title is NOT an assertion
// that its rows share a window definition: the weekly band holds an ISO
// week, Codex's 7-day rolling window and Grok's Thursday-anchored
// billing period. Each row therefore always renders its own window
// label, which is what stops the grouping reading as "these numbers
// disagree, it's a bug".
type Band int

const (
	BandShort Band = iota
	BandWeekly
)

// displayOrder is the fixed vendor order within every band. It does not
// depend on values, so rows never reorder between refreshes. Glyph
// escalation uses a different, value-dependent order — see WorstPct.
var displayOrder = []string{"claude", "codex", "grok"}

const gaugeCells = 10

var (
	styleBarFill = lipgloss.NewStyle().Foreground(lipgloss.Color("10"))
	styleBarWarn = lipgloss.NewStyle().Foreground(lipgloss.Color("11"))
	styleBarOver = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
	styleStale   = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
)

// Segment is one stacked slice of a budget bar. Spec 1 emits a single
// Claude segment; the Codex USD segment is added later without changing
// the renderer.
type Segment struct {
	Label string
	USD   float64
	Style lipgloss.Style
}

// Row is one rendered line. Exactly one of Budget, Plan or NotApplicable
// is meaningful.
type Row struct {
	Vendor        string
	WindowLbl     string
	Budget        *limits.Status
	Segments      []Segment
	Plan          *planlimits.Gauge
	NotApplicable string
}

// BuildRows assembles one band's rows in fixed display order,
// synthesising an "n/a" placeholder for a vendor that is installed but
// reports nothing in this band. A vendor absent altogether is omitted:
// showing n/a for a tool you do not use would be noise, while hiding a
// real gap would read as zero usage.
func BuildRows(band Band, st []limits.Status, gs []planlimits.Gauge) []Row {
	installed := map[string]bool{}
	for _, g := range gs {
		installed[g.Vendor] = true
	}

	var rows []Row
	for _, vendor := range displayOrder {
		if vendor == "claude" {
			if s := budgetFor(band, st); s != nil {
				rows = append(rows, Row{
					Vendor:    "claude",
					WindowLbl: s.Window.String(),
					Budget:    s,
					Segments:  []Segment{{Label: "claude", USD: s.SpentUSD, Style: styleBarFill}},
				})
			}
			continue
		}
		if !installed[vendor] {
			continue
		}
		matched := false
		for i := range gs {
			g := gs[i]
			if g.Vendor != vendor || bandOf(g) != band {
				continue
			}
			rows = append(rows, Row{Vendor: vendor, WindowLbl: g.WindowLbl, Plan: &gs[i]})
			matched = true
		}
		if !matched {
			rows = append(rows, Row{
				Vendor:        vendor,
				WindowLbl:     "—",
				NotApplicable: naReason(band),
			})
		}
	}
	return rows
}

func naReason(band Band) string {
	if band == BandShort {
		return "weekly only"
	}
	return "no weekly window"
}

// bandOf places a gauge by its label: anything measured in hours is a
// short window, anything in days is weekly.
func bandOf(g planlimits.Gauge) Band {
	if strings.HasSuffix(g.WindowLbl, "h") {
		return BandShort
	}
	return BandWeekly
}

func budgetFor(band Band, st []limits.Status) *limits.Status {
	want := limits.WindowDay
	if band == BandWeekly {
		want = limits.WindowWeek
	}
	for i := range st {
		if st[i].Window == want && st[i].State != limits.StateUnset {
			return &st[i]
		}
	}
	return nil
}

// RenderGauges draws both bands. Rows are grouped by duration because
// "how close am I to a wall in the next few hours" spans both budget and
// plan numbers.
func RenderGauges(st []limits.Status, gs []planlimits.Gauge) string {
	var b strings.Builder
	b.WriteString(renderGaugeGroup("short window", BuildRows(BandShort, st, gs)))
	b.WriteString(renderGaugeGroup("weekly", BuildRows(BandWeekly, st, gs)))
	return b.String()
}

func renderGaugeGroup(title string, rows []Row) string {
	if len(rows) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString(styleDim.Render("── "+title+" ") + "\n")
	for _, r := range rows {
		b.WriteString(renderRow(r) + "\n")
	}
	return b.String()
}

func renderRow(r Row) string {
	label := fmt.Sprintf(" %-7s %-5s", r.Vendor, r.WindowLbl)

	if r.NotApplicable != "" {
		return styleStale.Render(label + " n/a (" + r.NotApplicable + ")")
	}

	switch {
	case r.Budget != nil:
		return renderBudgetRow(label, r)
	case r.Plan != nil:
		return renderPlanRow(label, r)
	default:
		return label
	}
}

// renderBudgetRow draws a budget row's bar from Segments rather than a
// scalar percentage. That is what lets a later spec stack a second
// (Codex USD) segment onto these same rows without changing this
// function — only its input, BuildRows, changes.
//
// The bar's segments always keep their own per-vendor Style, even past
// the warn/over thresholds: colour-per-vendor must keep working
// regardless of how many segments are stacked. The threshold signal
// instead lives on the percentage text via pctColor, which is what a
// plan row's percentage also uses — see renderPlanRow — so the two row
// kinds agree on what colour means.
func renderBudgetRow(label string, r Row) string {
	pct := r.Budget.Pct
	// The detail column is what distinguishes a budget percentage from a
	// plan percentage: money on one, a reset clock on the other.
	detail := fmt.Sprintf("%s/%s", FormatUSD(r.Budget.SpentUSD), FormatUSD(r.Budget.LimitUSD))
	pctText := pctColor(pct).Render(fmt.Sprintf("%3.0f%%", pct))
	line := label + " " + stackedBar(r.Segments, r.Budget.LimitUSD) + " " + pctText + "  " + detail
	if pct >= 100 {
		line += " ⚠"
	}
	return line
}

// renderPlanRow draws a plan row, built once for either the live or the
// stale case — never both — so a future change to stale styling can't
// silently apply to a string nobody returns.
func renderPlanRow(label string, r Row) string {
	pct := r.Plan.Pct
	if r.Plan.Stale {
		// A stale window shows no live reset countdown and no
		// over-threshold glyph: both would wrongly imply the window is
		// still open.
		detail := "stale · ended " + shortWhen(r.Plan.ResetsAt)
		return styleStale.Render(label + " " + plainBar(pct) + fmt.Sprintf(" %3.0f%%  %s", pct, detail))
	}
	// A plan row has no segments to colour, so its bar keeps the
	// threshold colouring it always had. Its percentage text also
	// carries the same threshold colour as a budget row's, via
	// pctColor — see renderBudgetRow's comment for why that pairing
	// matters.
	detail := "↻ " + shortWhen(r.Plan.ResetsAt)
	pctText := pctColor(pct).Render(fmt.Sprintf("%3.0f%%", pct))
	line := label + " " + bar(pct) + " " + pctText + "  " + detail
	if pct >= 100 {
		line += " ⚠"
	}
	return line
}

// pctColor is the single source of truth for the warn/over threshold
// colour, applied to the percentage text of both budget and plan rows.
// It is deliberately never applied to bar segments: a segment's colour
// identifies its vendor, and must mean the same thing whether one
// vendor is stacked or five.
func pctColor(pct float64) lipgloss.Style {
	switch {
	case pct >= 100:
		return styleBarOver
	case pct >= 80:
		return styleBarWarn
	default:
		return lipgloss.NewStyle()
	}
}

func bar(pct float64) string {
	s := plainBar(pct)
	switch {
	case pct >= 100:
		return styleBarOver.Render(s)
	case pct >= 80:
		return styleBarWarn.Render(s)
	default:
		return styleBarFill.Render(s)
	}
}

// stackedBar draws one bar as a sequence of styled runs, one per
// segment, each sized by its own share of gaugeCells. With a single
// segment this is byte-identical to a plain threshold-coloured bar over
// the same percentage — see TestStackedBarSingleSegmentMatchesPlainBar —
// which is what proves stacking a second segment later needs no change
// here.
func stackedBar(segments []Segment, limitUSD float64) string {
	cells := segmentCells(segments, limitUSD)
	filled := 0
	var b strings.Builder
	for i, seg := range segments {
		n := cells[i]
		filled += n
		if n > 0 {
			b.WriteString(seg.Style.Render(strings.Repeat("█", n)))
		}
	}
	b.WriteString(strings.Repeat("░", gaugeCells-filled))
	return b.String()
}

// segmentCells splits gaugeCells across segments proportional to each
// segment's USD share of limitUSD. It rounds the running cumulative
// total and takes the difference from the previous cumulative count,
// rather than rounding each segment independently, so the per-segment
// counts always sum to the same total a single non-stacked bar would
// show for that total USD.
func segmentCells(segments []Segment, limitUSD float64) []int {
	out := make([]int, len(segments))
	var total float64
	for _, seg := range segments {
		total += seg.USD
	}
	totalFilled := filledCells(total, limitUSD)

	var running float64
	prev := 0
	for i, seg := range segments {
		running += seg.USD
		cum := filledCells(running, limitUSD)
		if cum > totalFilled {
			cum = totalFilled
		}
		out[i] = cum - prev
		prev = cum
	}
	return out
}

func filledCells(usd, limitUSD float64) int {
	if limitUSD <= 0 {
		return 0
	}
	return filledCellsFromPct(100 * usd / limitUSD)
}

func filledCellsFromPct(pct float64) int {
	filled := int(pct/100*gaugeCells + 0.5)
	if filled < 0 {
		filled = 0
	}
	if filled > gaugeCells {
		filled = gaugeCells
	}
	return filled
}

func plainBar(pct float64) string {
	filled := filledCellsFromPct(pct)
	return strings.Repeat("█", filled) + strings.Repeat("░", gaugeCells-filled)
}

func shortWhen(t time.Time) string {
	d := time.Until(t)
	switch {
	case d <= 0:
		return t.Local().Format("Mon")
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	default:
		return t.Local().Format("Mon")
	}
}

// WorstPct is the highest utilisation across every non-stale row in both
// bands. This drives menu bar escalation, and it is deliberately a
// different ordering from displayOrder: an expired window must never
// paint the menu bar red.
func WorstPct(st []limits.Status, gs []planlimits.Gauge) float64 {
	worst := 0.0
	for _, s := range st {
		if s.State != limits.StateUnset && s.Pct > worst {
			worst = s.Pct
		}
	}
	for _, g := range gs {
		if !g.Stale && g.Pct > worst {
			worst = g.Pct
		}
	}
	return worst
}
