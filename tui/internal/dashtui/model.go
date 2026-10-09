// Package dashtui is the full-screen analytics dashboard (--dashboards):
// the macapp's dashboard window as terminal tabs — spend chart, the
// weekday × hour heatmap, the model × effort map, the tables and the
// improvement hints.
package dashtui

import (
	"fmt"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/dashboard"
	"github.com/jverhoeks/claudecounter/tui/internal/hints"
	"github.com/jverhoeks/claudecounter/tui/internal/perf"
)

type tab int

const (
	tabSpend tab = iota
	tabHeatmap
	tabEffort
	tabTables
	tabHints
)

var tabNames = []string{"Spend", "Heatmap", "Effort map", "Tables", "Hints"}

// Performance ranges, as on the macapp's Performance tab.
var perfRanges = []int{3, 7, 30, 90}

var perfAgents = []perf.Agent{perf.AgentAll, perf.AgentMain, perf.AgentSubagent}

// effortMetric is what the effort map's cells show.
type effortMetric int

const (
	metricShare effortMetric = iota
	metricE2E
	metricOutput
	metricThinking
)

var metricNames = []string{"share of requests", "E2E p50", "output p50", "thinking p50"}

// Table columns, as on the macapp's series table.
var columns = []string{"Spend", "Share", "Tokens", "Tokens/$", "Output", "Cache hit"}

type loadedMsg struct{ data dashboard.Data }
type tickMsg struct{}

type Model struct {
	load    dashboard.Loader
	data    *dashboard.Data
	loading bool
	done    atomic.Int64
	total   atomic.Int64

	w, h int
	tab  tab

	// Spend controls.
	rangeIdx   int
	dimIdx     int
	showTokens bool
	focus      string
	cursor     int
	sortCol    int // index into columns; -1 = name

	// Performance controls.
	perfRangeIdx int
	agentIdx     int
	effort       string
	metric       effortMetric

	hintsIdx int
	scroll   int

	// Caches, rebuilt when their inputs change.
	spend    *dashboard.SpendView
	spendKey string
	report   *perf.Report
	perfKey  string
	hintList []hints.Hint
	hintsKey string
}

// New builds the dashboard; load runs on start and on every rescan (r).
func New(load dashboard.Loader) *Model {
	return &Model{load: load, loading: true, rangeIdx: 1, perfRangeIdx: 2, sortCol: 0}
}

func (m *Model) Init() tea.Cmd { return tea.Batch(m.scan(), tick()) }

func tick() tea.Cmd {
	return tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg { return tickMsg{} })
}

func (m *Model) scan() tea.Cmd {
	m.loading = true
	m.done.Store(0)
	m.total.Store(0)
	return func() tea.Msg {
		d := m.load(func(done, total int) {
			m.done.Store(int64(done))
			m.total.Store(int64(total))
		})
		return loadedMsg{d}
	}
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
	case tickMsg:
		if m.loading {
			return m, tick()
		}
	case loadedMsg:
		m.data = &msg.data
		m.loading = false
		m.spendKey, m.perfKey, m.hintsKey = "", "", ""
	case tea.KeyMsg:
		return m, m.key(msg.String())
	}
	return m, nil
}

func (m *Model) key(k string) tea.Cmd {
	switch k {
	case "q", "ctrl+c":
		return tea.Quit
	case "r":
		if !m.loading {
			return tea.Batch(m.scan(), tick())
		}
	case "tab", "right", "l":
		m.tab = (m.tab + 1) % tab(len(tabNames))
		m.scroll = 0
	case "shift+tab", "left", "h":
		m.tab = (m.tab + tab(len(tabNames)) - 1) % tab(len(tabNames))
		m.scroll = 0
	case "1", "2", "3", "4", "5":
		m.tab = tab(k[0] - '1')
		m.scroll = 0
	case "d":
		if m.tab == tabEffort {
			m.perfRangeIdx = (m.perfRangeIdx + 1) % len(perfRanges)
		} else if m.tab == tabHints {
			m.hintsIdx = (m.hintsIdx + 1) % len(hints.Periods)
		} else {
			m.rangeIdx = (m.rangeIdx + 1) % len(dashboard.Ranges)
		}
	case "g":
		m.dimIdx = (m.dimIdx + 1) % len(dashboard.Dimensions)
		m.focus, m.cursor = "", 0
	case "t", "$":
		m.showTokens = !m.showTokens
	case "s":
		m.sortCol = (m.sortCol+2)%(len(columns)+1) - 1
	case "a":
		m.agentIdx = (m.agentIdx + 1) % len(perfAgents)
	case "e":
		m.effort = nextEffort(m.effort)
	case "m":
		m.metric = (m.metric + 1) % effortMetric(len(metricNames))
	case "up", "k":
		if m.tab == tabHints {
			m.scroll = max(m.scroll-1, 0)
		} else {
			m.cursor = max(m.cursor-1, 0)
		}
	case "down", "j":
		if m.tab == tabHints {
			m.scroll++
		} else {
			m.cursor++
		}
	case "enter":
		if rows := m.sortedRows(); m.cursor < len(rows) {
			if m.focus == rows[m.cursor].Name {
				m.focus = ""
			} else {
				m.focus = rows[m.cursor].Name
			}
		}
	case "esc":
		m.focus = ""
	}
	return nil
}

func nextEffort(e string) string {
	if e == "" {
		return perf.Efforts[0]
	}
	for i, x := range perf.Efforts {
		if x == e && i+1 < len(perf.Efforts) {
			return perf.Efforts[i+1]
		}
	}
	return ""
}

// spendView is the cached Spend tab data for the current controls.
func (m *Model) spendView() *dashboard.SpendView {
	key := fmt.Sprint(m.rangeIdx, m.dimIdx, m.focus)
	if m.spend == nil || key != m.spendKey {
		v := dashboard.Spend(m.data.Spend, dashboard.SpendQuery{
			RangeDays: dashboard.Ranges[m.rangeIdx], Dim: dashboard.Dimensions[m.dimIdx], Focus: m.focus,
		}, m.data.Sources)
		m.spend, m.spendKey = &v, key
	}
	return m.spend
}

func (m *Model) perfReport() *perf.Report {
	key := fmt.Sprint(m.perfRangeIdx, m.agentIdx, m.effort)
	if m.report == nil || key != m.perfKey {
		r := perf.BuildReport(m.data.Samples, perf.Filters{
			RangeDays: perfRanges[m.perfRangeIdx], Agent: perfAgents[m.agentIdx], Effort: m.effort,
		}, m.data.Spend.AsOf)
		m.report, m.perfKey = &r, key
	}
	return m.report
}

func (m *Model) hintsFor() []hints.Hint {
	key := fmt.Sprint(m.hintsIdx)
	if m.hintsKey != key {
		m.hintList = hints.Build(m.data.Samples, m.data.Pricing, m.data.Settings, hints.Periods[m.hintsIdx], m.data.Spend.AsOf)
		m.hintsKey = key
	}
	return m.hintList
}

// sortedRows is the series table in the current sort order.
func (m *Model) sortedRows() []dashboard.TableRow {
	if m.data == nil {
		return nil
	}
	rows := append([]dashboard.TableRow(nil), m.spendView().Rows...)
	key := func(r dashboard.TableRow) float64 {
		switch m.sortCol {
		case 2:
			return float64(r.Tokens)
		case 3:
			if r.TokensPerUSD == nil {
				return -1
			}
			return *r.TokensPerUSD
		case 4:
			return float64(r.Output)
		case 5:
			return r.CacheHit
		default:
			return r.USD
		}
	}
	sort.SliceStable(rows, func(i, j int) bool {
		if m.sortCol < 0 {
			return rows[i].Name < rows[j].Name
		}
		return key(rows[i]) > key(rows[j])
	})
	if m.cursor >= len(rows) {
		m.cursor = max(len(rows)-1, 0)
	}
	return rows
}

func (m *Model) View() string {
	if m.w == 0 {
		return ""
	}
	header := m.header()
	footer := m.footer()
	bodyH := m.h - lipgloss.Height(header) - lipgloss.Height(footer)
	var body string
	switch {
	case m.data == nil:
		body = m.loadingView()
	case m.tab == tabSpend:
		body = m.spendTab(bodyH)
	case m.tab == tabHeatmap:
		body = m.heatmapTab(bodyH)
	case m.tab == tabEffort:
		body = m.effortTab(bodyH)
	case m.tab == tabTables:
		body = m.tablesTab(bodyH)
	default:
		body = m.hintsTab(bodyH)
	}
	body = lipgloss.NewStyle().Width(m.w).Height(bodyH).MaxHeight(bodyH).Padding(0, 1).Render(body)
	return lipgloss.JoinVertical(lipgloss.Left, header, body, footer)
}

func (m *Model) loadingView() string {
	done, total := m.done.Load(), m.total.Load()
	if total == 0 {
		return muted.Render("\n  Finding session logs …")
	}
	return muted.Render(fmt.Sprintf("\n  Reading %d / %d files …", done, total))
}

func (m *Model) header() string {
	var tabs []string
	for i, n := range tabNames {
		label := fmt.Sprintf(" %d %s ", i+1, n)
		if tab(i) == m.tab {
			tabs = append(tabs, activeTab.Render(label))
		} else {
			tabs = append(tabs, inactiveTab.Render(label))
		}
	}
	left := title.Render(" claudecounter ") + " " + strings.Join(tabs, "")
	right := ""
	if m.loading && m.data != nil {
		right = muted.Render("rescanning … ")
	} else if m.data != nil {
		right = muted.Render("as of " + m.data.Spend.AsOf.Format("15:04") + " ")
	}
	gap := max(m.w-lipgloss.Width(left)-lipgloss.Width(right), 1)
	line := left + strings.Repeat(" ", gap) + right
	return line + "\n" + rule.Render(strings.Repeat("─", m.w))
}

func (m *Model) footer() string {
	keys := "tab/1-5 switch · r rescan · q quit"
	switch m.tab {
	case tabSpend:
		keys = "d range · g group · t $/tokens · ↑↓ enter focus · esc clear · " + keys
	case tabHeatmap:
		keys = "d range of table · g group · ↑↓ enter focus a model (Tables) · " + keys
	case tabEffort:
		keys = "d range · a agent · e effort · m metric · " + keys
	case tabTables:
		keys = "d range · g group · s sort · ↑↓ enter focus · " + keys
	case tabHints:
		keys = "d period · ↑↓ scroll · " + keys
	}
	var warn string
	if m.data != nil && len(m.data.Warnings) > 0 {
		warn = warnStyle.Render(strings.Join(m.data.Warnings, "  ")) + "\n"
	}
	return warn + muted.Render(" "+truncate(keys, m.w-2))
}

func truncate(s string, w int) string {
	r := []rune(s)
	if len(r) <= w || w < 1 {
		return s
	}
	return string(r[:w-1]) + "…"
}
