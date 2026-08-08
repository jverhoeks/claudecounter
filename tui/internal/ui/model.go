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
	"github.com/jverhoeks/claudecounter/tui/internal/safety"
)

type ViewMode int

const (
	ModeMinimal ViewMode = iota
	ModeSplit
	ModeFull
	ModeReport
	ModeSafety

	modeCount // number of view modes (for Tab cycling)
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

// GaugesMsg delivers a freshly rendered budget/plan-limit gauge block.
// It is pushed on its own slow ticker, independent of SnapshotMsg: the
// gauge scan walks vendor log directories, which is too costly to run
// on the aggregator's sub-second dirty-flush cadence without risking
// the live counting pipeline.
//
// Err is set instead of Gauges when limits.toml is malformed. It must
// never crash or halt the live TUI: the model turns it into a footer
// warning and leaves whatever gauge block was already showing in
// place, rather than replacing it with a blank one.
type GaugesMsg struct {
	Gauges string
	Err    error
}

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

// SafetyMsg delivers a freshly gathered permission-mode safety report.
type SafetyMsg struct {
	Rows []safety.Row
	Sum  safety.Summary
	Days int
	Err  error
}

// SafetyFunc runs the wide mode scan for a window; injected by main.
type SafetyFunc func(days int) SafetyMsg

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
	gauges      string
	limitsWarn  string // set from GaugesMsg.Err; cleared on the next successful refresh
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

	safetyFn      SafetyFunc
	safetyRows    []safety.Row
	safetySum     safety.Summary
	safetyDays    int
	safetyErr     error
	safetyLoading bool
	safetyLoaded  bool
	safetyVP      viewport.Model
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
		safetyDays:   90,
		safetyVP:     viewport.New(0, 0),
	}
}

// SetReportFunc injects the report generator (called by main).
func (m *Model) SetReportFunc(fn ReportFunc) { m.reportFn = fn }

// SetSafetyFunc injects the safety-report generator (called by main).
func (m *Model) SetSafetyFunc(fn SafetyFunc) { m.safetyFn = fn }

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
		m.safetyVP.Width = msg.Width
		m.safetyVP.Height = h
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
		case "5":
			m.mode = ModeSafety
			if !m.safetyLoaded && !m.safetyLoading && m.safetyFn != nil {
				m.safetyLoading = true
				return m, m.runSafetyCmd()
			}
		case "tab":
			m.mode = (m.mode + 1) % modeCount
			if m.mode == ModeReport && !m.reportLoaded && !m.reportLoading && m.reportFn != nil {
				m.reportLoading = true
				return m, m.runReportCmd()
			}
			if m.mode == ModeSafety && !m.safetyLoaded && !m.safetyLoading && m.safetyFn != nil {
				m.safetyLoading = true
				return m, m.runSafetyCmd()
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
			if (m.mode == ModeReport && !m.reportLoading) || (m.mode == ModeSafety && !m.safetyLoading) {
				cur := m.reportDays
				if m.mode == ModeSafety {
					cur = m.safetyDays
				}
				windows := []int{30, 90, 180}
				idx := 1
				for i, w := range windows {
					if w == cur {
						idx = i
					}
				}
				if msg.String() == "[" && idx > 0 {
					idx--
				}
				if msg.String() == "]" && idx < len(windows)-1 {
					idx++
				}
				if m.mode == ModeSafety {
					m.safetyDays = windows[idx]
					m.safetyLoading = true
					return m, m.runSafetyCmd()
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
			if m.mode == ModeSafety && !m.safetyLoading {
				var cmd tea.Cmd
				m.safetyVP, cmd = m.safetyVP.Update(msg)
				return m, cmd
			}
		case "g":
			if m.mode == ModeReport && !m.reportLoading {
				m.reportVP.GotoTop()
				return m, nil
			}
			if m.mode == ModeSafety && !m.safetyLoading {
				m.safetyVP.GotoTop()
				return m, nil
			}
		case "G":
			if m.mode == ModeReport && !m.reportLoading {
				m.reportVP.GotoBottom()
				return m, nil
			}
			if m.mode == ModeSafety && !m.safetyLoading {
				m.safetyVP.GotoBottom()
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
	case GaugesMsg:
		if msg.Err != nil {
			// Leave m.gauges untouched — the last-good render (if any)
			// stays on screen — and surface the error as a footer
			// warning instead of a log line, since the alt screen owns
			// the terminal and nothing writes to stderr while it does.
			m.limitsWarn = "⚠ limits config: " + msg.Err.Error()
		} else {
			m.limitsWarn = ""
			m.gauges = msg.Gauges
		}
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
	case SafetyMsg:
		m.safetyLoading = false
		m.safetyLoaded = true
		m.safetyRows = msg.Rows
		m.safetySum = msg.Sum
		m.safetyDays = msg.Days
		m.safetyErr = msg.Err
		m.safetyVP.SetContent(safetyTable(m.safetyRows, m.safetySum))
		m.safetyVP.GotoTop()
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
		body = viewMinimal(m.totals, m.gauges)
	case ModeSplit:
		body = viewSplit(m.totals, m.gauges)
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
	case ModeSafety:
		head := safetyHeader(m.safetyDays)
		switch {
		case m.safetyErr != nil:
			body = head + "  safety error: " + m.safetyErr.Error() + "\n"
		case m.safetyLoading:
			body = head + "  " + m.spin.View() + " scanning transcripts…\n"
		case len(m.safetyRows) == 0:
			body = head + "  No prompt turns found in this window.\n"
		default:
			body = head + m.safetyVP.View()
		}
	}
	footer := "1/2/3/4/5 or Tab: switch view   q: quit"
	if m.mode == ModeReport && m.reportLoaded && !m.reportLoading && m.reportErr == nil && len(m.reports) > 0 {
		if !(m.reportVP.AtTop() && m.reportVP.AtBottom()) {
			footer = fmt.Sprintf("scroll %.0f%%   ", m.reportVP.ScrollPercent()*100) + footer
		}
	}
	if m.mode == ModeSafety && m.safetyLoaded && !m.safetyLoading && m.safetyErr == nil && len(m.safetyRows) > 0 {
		if !(m.safetyVP.AtTop() && m.safetyVP.AtBottom()) {
			footer = fmt.Sprintf("scroll %.0f%%   ", m.safetyVP.ScrollPercent()*100) + footer
		}
	}
	for _, w := range m.warns {
		footer = w + "\n" + footer
	}
	// limitsWarn is a single persistent field, not appended to m.warns
	// (which collectWarns fully rebuilds on every SnapshotMsg), so a
	// repeatedly-failing config refresh renders one line, not one per
	// attempt.
	if m.limitsWarn != "" {
		footer = m.limitsWarn + "\n" + footer
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

func (m Model) runSafetyCmd() tea.Cmd {
	fn := m.safetyFn
	days := m.safetyDays
	if fn == nil {
		return nil
	}
	return func() tea.Msg { return fn(days) }
}
