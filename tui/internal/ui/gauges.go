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
// depend on values, so rows never reorder between refreshes. BuildRows
// and WorstPct both read displayOrder — WorstPct iterates the rows
// BuildRows creates, so a row that cannot be displayed cannot escalate.
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

// Row is one rendered line. Exactly one of Budget or Plan is meaningful.
type Row struct {
	Vendor    string
	WindowLbl string
	Budget    *limits.Status
	Segments  []Segment
	Plan      *planlimits.Gauge
}

// BuildRows assembles one band's rows in fixed display order. A vendor
// with nothing to show in this band — whether not installed at all, or
// installed but reporting no window in this band — is simply omitted.
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
		for i := range gs {
			g := gs[i]
			if g.Vendor != vendor || bandOf(g) != band {
				continue
			}
			rows = append(rows, Row{Vendor: vendor, WindowLbl: g.WindowLbl, Plan: &gs[i]})
		}
	}
	return rows
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
//
// warnPct is the user's configured amber threshold (limits.Config.WarnPct,
// itself limits.DefaultWarnPct when unconfigured). It is threaded through
// to plan rows only — a budget row's colour instead comes from its own
// Status.State, which limits.Evaluate already computed against this same
// warnPct. See pctColor and stateColor.
func RenderGauges(st []limits.Status, gs []planlimits.Gauge, warnPct int) string {
	var b strings.Builder
	b.WriteString(renderGaugeGroup("short window", BuildRows(BandShort, st, gs), warnPct))
	b.WriteString(renderGaugeGroup("weekly", BuildRows(BandWeekly, st, gs), warnPct))
	return b.String()
}

func renderGaugeGroup(title string, rows []Row, warnPct int) string {
	if len(rows) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString(styleDim.Render("── "+title+" ") + "\n")
	for _, r := range rows {
		b.WriteString(renderRow(r, warnPct) + "\n")
	}
	return b.String()
}

func renderRow(r Row, warnPct int) string {
	label := fmt.Sprintf(" %-7s %-5s", r.Vendor, r.WindowLbl)

	switch {
	case r.Budget != nil:
		return renderBudgetRow(label, r)
	case r.Plan != nil:
		return renderPlanRow(label, r, warnPct)
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
// instead lives on the percentage text via stateColor, which reads
// r.Budget.State — the verdict limits.Evaluate already computed against
// the configured warnPct — rather than re-comparing Pct against a
// threshold here. A plan row's percentage carries the same threshold
// colour via a different mechanism, pctColor — see renderPlanRow — so
// the two row kinds still agree on what colour a given warnPct means.
func renderBudgetRow(label string, r Row) string {
	pct := r.Budget.Pct
	// The detail column is what distinguishes a budget percentage from a
	// plan percentage: money on one, a reset clock on the other.
	detail := fmt.Sprintf("%s/%s", FormatUSD(r.Budget.SpentUSD), FormatUSD(r.Budget.LimitUSD))
	// Width 4, not 3: a budget row is exactly where pct can exceed 100
	// (spend past the limit), and %3.0f only reserves room up to 99% —
	// at 100+ it grows past the field and shoves the detail column
	// right, misaligning against every row above and below it.
	pctText := stateColor(r.Budget.State).Render(fmt.Sprintf("%4.0f%%", pct))
	line := label + " " + stackedBar(r.Segments, r.Budget.LimitUSD) + " " + pctText + "  " + detail
	if pct >= 100 {
		line += " ⚠"
	}
	return line
}

// renderPlanRow draws a plan row, built once for either the live or the
// stale case — never both — so a future change to stale styling can't
// silently apply to a string nobody returns.
//
// A planlimits.Gauge is vendor-reported and carries no State (unlike
// limits.Status), so it has no engine verdict to read the way
// renderBudgetRow does. It re-derives colour from warnPct directly, via
// pctColor/bar — applying the user's configured threshold to a plan row
// is a deliberate display convention, not a second engine, but it keeps
// a plan row's colour meaning the same threshold a budget row's State
// was computed against.
func renderPlanRow(label string, r Row, warnPct int) string {
	pct := r.Plan.Pct
	if r.Plan.Stale {
		// A stale window shows no live reset countdown and no
		// over-threshold glyph: both would wrongly imply the window is
		// still open.
		detail := "stale · ended " + shortWhen(r.Plan.ResetsAt)
		return styleStale.Render(label + " " + plainBar(pct) + fmt.Sprintf(" %4.0f%%  %s", pct, detail))
	}
	// A plan row has no segments to colour, so its bar keeps the
	// threshold colouring it always had. Its percentage text carries
	// the same threshold colour a budget row's would for this warnPct,
	// via pctColor rather than stateColor — see renderBudgetRow's
	// comment for why that pairing still agrees.
	detail := "↻ " + shortWhen(r.Plan.ResetsAt)
	pctText := pctColor(pct, warnPct).Render(fmt.Sprintf("%4.0f%%", pct))
	line := label + " " + bar(pct, warnPct) + " " + pctText + "  " + detail
	if pct >= 100 {
		line += " ⚠"
	}
	return line
}

// pctColor is a plan row's warn/over threshold colour, applied to its
// percentage text. Unlike stateColor, it takes warnPct as an argument
// rather than reading it off an engine-computed State — a plan gauge has
// no State to read (see renderPlanRow) — so a caller that forgets to
// plumb the configured value gets a compile error, not a silent 80.
// It is deliberately never applied to bar segments: a segment's colour
// identifies its vendor, and must mean the same thing whether one
// vendor is stacked or five.
func pctColor(pct float64, warnPct int) lipgloss.Style {
	switch {
	case pct >= 100:
		return styleBarOver
	case pct >= float64(warnPct):
		return styleBarWarn
	default:
		return lipgloss.NewStyle()
	}
}

// stateColor is a budget row's warn/over threshold colour, driven
// entirely by the engine's State. limits.Evaluate already compared Pct
// against the configured warnPct to produce State, so this function
// never re-compares Pct against a threshold itself — that is what keeps
// a budget row's colour and its Status.State from being able to drift
// apart.
func stateColor(s limits.State) lipgloss.Style {
	switch s {
	case limits.StateOver:
		return styleBarOver
	case limits.StateWarn:
		return styleBarWarn
	default:
		return lipgloss.NewStyle()
	}
}

func bar(pct float64, warnPct int) string {
	s := plainBar(pct)
	switch {
	case pct >= 100:
		return styleBarOver.Render(s)
	case pct >= float64(warnPct):
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

// WorstPct is the highest utilisation across every non-stale row that
// BuildRows would actually display, in both bands. This drives menu bar
// escalation.
//
// It deliberately reads BuildRows' own output rather than re-scanning
// st/gs itself: displayOrder is a closed list ("claude", "codex",
// "grok"), and BuildRows already drops anything outside it — an unknown
// vendor's gauge, or (subtly) a Vendor: "claude" plan gauge, since the
// displayOrder loop's "claude" slot only ever looks at budget Status,
// never at gs. Iterating st/gs directly here, as this used to, would
// let such a gauge escalate the menu bar to red with no row on screen
// explaining why — harmless today because only codex/grok emit gauges
// and both are in displayOrder, but a real gap the moment a fourth
// vendor (or a Vendor: "claude" gauge) appears. Reading BuildRows makes
// "cannot be displayed" and "cannot escalate" the same guarantee by
// construction, so they cannot drift apart again.
func WorstPct(st []limits.Status, gs []planlimits.Gauge) float64 {
	worst := 0.0
	for _, band := range []Band{BandShort, BandWeekly} {
		for _, r := range BuildRows(band, st, gs) {
			if r.Budget != nil && r.Budget.Pct > worst {
				worst = r.Budget.Pct
			}
			if r.Plan != nil && !r.Plan.Stale && r.Plan.Pct > worst {
				worst = r.Plan.Pct
			}
		}
	}
	return worst
}
