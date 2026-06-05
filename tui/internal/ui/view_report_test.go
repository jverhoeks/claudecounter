package ui

import (
	"errors"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

func sampleReports() []report.RepoReport {
	return []report.RepoReport{{
		Root: "/Users/me/git/alpha",
		Buckets: []report.Bucket{{
			Label: "2026-W23", USD: 10, CommitsMine: 3, CommitsAll: 5,
			Added: 120, Deleted: 40, Files: 8, USDPerCommit: 3.33, USDPerLine: 0.0625,
		}},
		Total: report.Bucket{
			USD: 10, CommitsMine: 3, CommitsAll: 5, Added: 120, Deleted: 40, Files: 8,
		},
	}}
}

func TestReportTables_RendersRawComponents(t *testing.T) {
	out := reportTables(sampleReports(), 0)
	for _, want := range []string{"alpha", "2026-W23", "3 / 5", "+120", "-40"} {
		if !strings.Contains(out, want) {
			t.Errorf("reportTables missing %q\n---\n%s", want, out)
		}
	}
}

func TestReportHeader_ShowsWindowAndScrollHint(t *testing.T) {
	out := reportHeader(90, report.BucketWeek)
	for _, want := range []string{"last 90 days", "by week", "scroll"} {
		if !strings.Contains(out, want) {
			t.Errorf("reportHeader missing %q\n---\n%s", want, out)
		}
	}
}

func TestEmptyReportLine(t *testing.T) {
	if !strings.Contains(emptyReportLine(0), "No git activity") {
		t.Error("empty (skipped=0) should mention No git activity")
	}
	if !strings.Contains(emptyReportLine(2), "not git repos") {
		t.Error("empty (skipped>0) should explain the skip / git availability")
	}
}

func TestModelView_ReportLoadingShowsSpinner(t *testing.T) {
	m := NewModel()
	m.mode = ModeReport
	m.reportLoading = true
	out := m.View()
	if !strings.Contains(out, "collecting git stats") {
		t.Errorf("loading view missing spinner text:\n%s", out)
	}
}

func TestModelView_ReportError(t *testing.T) {
	m := NewModel()
	m.mode = ModeReport
	m.reportErr = errors.New("boom")
	out := m.View()
	if !strings.Contains(out, "report error: boom") {
		t.Errorf("error view missing error text:\n%s", out)
	}
}

func TestUpdate_ReportMsgPopulatesViewport(t *testing.T) {
	m := NewModel()
	m2, _ := m.Update(tea.WindowSizeMsg{Width: 100, Height: 40})
	m = m2.(Model)
	m.mode = ModeReport
	m3, _ := m.Update(ReportMsg{Reports: sampleReports(), Days: 90, Bucket: report.BucketWeek})
	m = m3.(Model)
	out := m.View()
	if !strings.Contains(out, "alpha") || !strings.Contains(out, "2026-W23") {
		t.Errorf("viewport not populated after ReportMsg:\n%s", out)
	}
}

func TestUpdate_NavKeyIgnoredInCostView(t *testing.T) {
	m := NewModel() // defaults to ModeSplit
	start := m.mode
	m2, _ := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	m = m2.(Model)
	if m.mode != start {
		t.Errorf("a nav key changed the mode in a cost view: %v -> %v", start, m.mode)
	}
}

func TestUpdate_BucketKeyTriggersReloadInReport(t *testing.T) {
	m := NewModel()
	m.SetReportFunc(func(days int, size report.BucketSize) ReportMsg {
		return ReportMsg{Days: days, Bucket: size}
	})
	m.mode = ModeReport
	m2, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("m")})
	m = m2.(Model)
	if m.reportBucket != report.BucketMonth {
		t.Errorf("pressing m did not set bucket=month, got %v", m.reportBucket)
	}
	if !m.reportLoading || cmd == nil {
		t.Errorf("pressing m should start a reload (loading=%v, cmd nil=%v)", m.reportLoading, cmd == nil)
	}
}
