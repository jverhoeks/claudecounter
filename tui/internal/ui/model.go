package ui

import (
	"fmt"

	"github.com/NimbleMarkets/ntcharts/linechart/streamlinechart"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

type ViewMode int

const (
	ModeMinimal ViewMode = iota
	ModeSplit
	ModeFull
	ModeReport
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
	Tag  string  // short label (project, model, cost)
	Line string  // pre-formatted line for the feed
	Cost float64 // event cost in USD; pushed into the streamlinechart
}

// BackfillDoneMsg signals that InitialScan has finished, so the
// "loading files…" spinner should be replaced by live state.
type BackfillDoneMsg struct{}

// ReportMsg delivers a freshly gathered git-activity report (or an error).
type ReportMsg struct {
	Reports []report.RepoReport
	Skipped int
	Days    int
	Bucket  report.BucketSize
	Err     error
}

// ReportFunc runs a wide scan + git collect for the given window/bucket and
// returns a ReportMsg. It is injected by main so ui needn't import reader.
type ReportFunc func(days int, size report.BucketSize) ReportMsg

const (
	recentCap        = 20
	streamlineWidth  = 60
	streamlineHeight = 8
)

type Model struct {
	mode        ViewMode
	totals      agg.Totals
	recent      []string
	warns       []string
	parseErrors int
	pricingWarn string
	width       int
	height      int

	loading bool
	spin    spinner.Model

	// streamline is updated incrementally as RecentEventMsg arrives,
	// so the rolling line is preserved across renders. Sparkline and
	// barchart are stateless — they're built from the latest snapshot
	// inside their view functions.
	streamline streamlinechart.Model

	reportFn      ReportFunc
	reports       []report.RepoReport
	reportSkipped int
	reportDays    int
	reportBucket  report.BucketSize
	reportErr     error
	reportLoading bool
	reportLoaded  bool
	reportVP      viewport.Model
}

func NewModel() Model {
	sp := spinner.New()
	sp.Spinner = spinner.Dot
	sp.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("12"))
	return Model{
		mode:         ModeSplit,
		loading:      true,
		spin:         sp,
		streamline:   streamlinechart.New(streamlineWidth, streamlineHeight),
		reportDays:   90,
		reportBucket: report.BucketWeek,
		reportVP:     viewport.New(0, 0),
	}
}

// SetReportFunc injects the report generator (called by main).
func (m *Model) SetReportFunc(fn ReportFunc) { m.reportFn = fn }

func (m Model) Init() tea.Cmd { return m.spin.Tick }

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.reportVP.Width = msg.Width
		h := msg.Height - 7
		if h < 3 {
			h = 3
		}
		m.reportVP.Height = h
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
		case "4":
			m.mode = ModeReport
			if !m.reportLoaded && !m.reportLoading && m.reportFn != nil {
				m.reportLoading = true
				return m, m.runReportCmd()
			}
		case "tab":
			m.mode = (m.mode + 1) % 4
			if m.mode == ModeReport && !m.reportLoaded && !m.reportLoading && m.reportFn != nil {
				m.reportLoading = true
				return m, m.runReportCmd()
			}
		case "d", "w", "m":
			if m.mode == ModeReport && !m.reportLoading {
				switch msg.String() {
				case "d":
					m.reportBucket = report.BucketDay
				case "w":
					m.reportBucket = report.BucketWeek
				case "m":
					m.reportBucket = report.BucketMonth
				}
				m.reportLoading = true
				return m, m.runReportCmd()
			}
		case "[", "]":
			if m.mode == ModeReport && !m.reportLoading {
				windows := []int{30, 90, 180}
				idx := 1
				for i, w := range windows {
					if w == m.reportDays {
						idx = i
					}
				}
				if msg.String() == "[" && idx > 0 {
					idx--
				}
				if msg.String() == "]" && idx < len(windows)-1 {
					idx++
				}
				m.reportDays = windows[idx]
				m.reportLoading = true
				return m, m.runReportCmd()
			}
		case "up", "down", "pgup", "pgdown", "j", "k", " ", "b", "f":
			if m.mode == ModeReport && !m.reportLoading {
				var cmd tea.Cmd
				m.reportVP, cmd = m.reportVP.Update(msg)
				return m, cmd
			}
		case "g":
			if m.mode == ModeReport && !m.reportLoading {
				m.reportVP.GotoTop()
				return m, nil
			}
		case "G":
			if m.mode == ModeReport && !m.reportLoading {
				m.reportVP.GotoBottom()
				return m, nil
			}
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
		m.streamline.Push(msg.Cost)
		m.streamline.Draw()
	case BackfillDoneMsg:
		m.loading = false
	case ReportMsg:
		m.reportLoading = false
		m.reportLoaded = true
		m.reports = msg.Reports
		m.reportSkipped = msg.Skipped
		m.reportDays = msg.Days
		m.reportBucket = msg.Bucket
		m.reportErr = msg.Err
		m.reportVP.SetContent(reportTables(m.reports, m.reportSkipped))
		m.reportVP.GotoTop()
	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spin, cmd = m.spin.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m Model) View() string {
	header := ""
	if m.loading {
		header = m.spin.View() + " loading files…\n"
	}

	var body string
	switch m.mode {
	case ModeMinimal:
		body = viewMinimal(m.totals)
	case ModeSplit:
		body = viewSplit(m.totals)
	case ModeFull:
		body = viewFull(m.totals, m.recent, m.streamline.View())
	case ModeReport:
		head := reportHeader(m.reportDays, m.reportBucket)
		switch {
		case m.reportErr != nil:
			body = head + "  report error: " + m.reportErr.Error() + "\n"
		case m.reportLoading:
			body = head + "  " + m.spin.View() + " collecting git stats…\n"
		case len(m.reports) == 0:
			body = head + emptyReportLine(m.reportSkipped)
		default:
			body = head + m.reportVP.View()
		}
	}
	footer := "1/2/3/4 or Tab: switch view   q: quit"
	if m.mode == ModeReport && m.reportLoaded && !m.reportLoading && m.reportErr == nil && len(m.reports) > 0 {
		if !(m.reportVP.AtTop() && m.reportVP.AtBottom()) {
			footer = fmt.Sprintf("scroll %.0f%%   ", m.reportVP.ScrollPercent()*100) + footer
		}
	}
	for _, w := range m.warns {
		footer = w + "\n" + footer
	}
	return header + body + "\n" + footer + "\n"
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

func (m Model) runReportCmd() tea.Cmd {
	fn := m.reportFn
	days := m.reportDays
	size := m.reportBucket
	if fn == nil {
		return nil
	}
	return func() tea.Msg { return fn(days, size) }
}
