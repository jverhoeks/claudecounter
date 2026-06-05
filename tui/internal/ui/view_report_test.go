package ui

import (
	"errors"
	"strings"
	"testing"

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
