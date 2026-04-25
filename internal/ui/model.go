package ui

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/jverhoeks/claudecounter/internal/agg"
)

type ViewMode int

const (
	ModeMinimal ViewMode = iota
	ModeSplit
	ModeFull
)

// SnapshotMsg is pushed by the app goroutine whenever totals change.
type SnapshotMsg struct {
	Totals      agg.Totals
	ParseErrors int
	Dupes       int    // lines skipped as duplicate message.id (expected; not surfaced as a warning)
	PricingWarn string // empty unless built-in defaults are in use
}

// RecentEventMsg is pushed for the live-tail in ModeFull.
type RecentEventMsg struct {
	Tag  string // short label (project, model, cost)
	Line string // pre-formatted line for the feed
}

const recentCap = 20

type Model struct {
	mode        ViewMode
	totals      agg.Totals
	recent      []string
	warns       []string
	parseErrors int
	pricingWarn string
	width       int
	height      int
}

func NewModel() Model { return Model{mode: ModeSplit} }

func (m Model) Init() tea.Cmd { return nil }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "1":
			m.mode = ModeMinimal
		case "2":
			m.mode = ModeSplit
		case "3":
			m.mode = ModeFull
		case "tab":
			m.mode = (m.mode + 1) % 3
		}
	case SnapshotMsg:
		m.totals = msg.Totals
		m.parseErrors = msg.ParseErrors
		m.pricingWarn = msg.PricingWarn
		m.warns = collectWarns(msg)
	case RecentEventMsg:
		m.recent = append(m.recent, msg.Line)
		if len(m.recent) > recentCap {
			m.recent = m.recent[len(m.recent)-recentCap:]
		}
	}
	return m, nil
}

func (m Model) View() string {
	var body string
	switch m.mode {
	case ModeMinimal:
		body = viewMinimal(m.totals)
	case ModeSplit:
		body = viewSplit(m.totals)
	case ModeFull:
		body = viewFull(m.totals, m.recent)
	}
	footer := "1/2/3 or Tab: switch view   q: quit"
	for _, w := range m.warns {
		footer = w + "\n" + footer
	}
	return body + "\n" + footer + "\n"
}

func collectWarns(s SnapshotMsg) []string {
	var out []string
	if s.PricingWarn != "" {
		out = append(out, s.PricingWarn)
	}
	if s.Totals.Unknown > 0 {
		out = append(out, fmt.Sprintf("⚠ %d events with unpriced models", s.Totals.Unknown))
	}
	if s.ParseErrors > 0 {
		out = append(out, fmt.Sprintf("⚠ %d parse errors", s.ParseErrors))
	}
	return out
}
