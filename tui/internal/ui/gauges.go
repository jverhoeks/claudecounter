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

	var pct float64
	var detail string
	var stale bool
	switch {
	case r.Budget != nil:
		pct = r.Budget.Pct
		// The detail column is what distinguishes a budget percentage
		// from a plan percentage: money on one, a reset clock on the other.
		detail = fmt.Sprintf("%s/%s", FormatUSD(r.Budget.SpentUSD), FormatUSD(r.Budget.LimitUSD))
	case r.Plan != nil:
		pct = r.Plan.Pct
		stale = r.Plan.Stale
		if stale {
			detail = "stale · ended " + shortWhen(r.Plan.ResetsAt)
		} else {
			detail = "↻ " + shortWhen(r.Plan.ResetsAt)
		}
	default:
		return label
	}

	line := label + " " + bar(pct, stale) + fmt.Sprintf(" %3.0f%%  %s", pct, detail)
	if stale {
		return styleStale.Render(label + " " + plainBar(pct) + fmt.Sprintf(" %3.0f%%  %s", pct, detail))
	}
	if pct >= 100 {
		line += " ⚠"
	}
	return line
}

func bar(pct float64, stale bool) string {
	s := plainBar(pct)
	switch {
	case stale:
		return styleStale.Render(s)
	case pct >= 100:
		return styleBarOver.Render(s)
	case pct >= 80:
		return styleBarWarn.Render(s)
	default:
		return styleBarFill.Render(s)
	}
}

func plainBar(pct float64) string {
	filled := int(pct/100*gaugeCells + 0.5)
	if filled < 0 {
		filled = 0
	}
	if filled > gaugeCells {
		filled = gaugeCells
	}
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
