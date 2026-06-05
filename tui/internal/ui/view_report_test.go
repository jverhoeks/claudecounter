package ui

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

func TestViewReport_RendersRawComponents(t *testing.T) {
	reports := []report.RepoReport{{
		Root: "/Users/me/git/alpha",
		Buckets: []report.Bucket{{
			Label: "2026-W23", USD: 10, CommitsMine: 3, CommitsAll: 5,
			Added: 120, Deleted: 40, Files: 8, USDPerCommit: 3.33, USDPerLine: 0.0625,
		}},
		Total: report.Bucket{
			USD: 10, CommitsMine: 3, CommitsAll: 5, Added: 120, Deleted: 40, Files: 8,
		},
	}}

	out := viewReport(reports, 90, report.BucketWeek, 0, false)

	for _, want := range []string{"alpha", "2026-W23", "3 / 5", "+120", "-40"} {
		if !strings.Contains(out, want) {
			t.Errorf("render missing %q\n---\n%s", want, out)
		}
	}
}

func TestViewReport_Empty(t *testing.T) {
	out := viewReport(nil, 90, report.BucketWeek, 0, false)
	if !strings.Contains(out, "No git activity") {
		t.Errorf("empty render should explain emptiness, got:\n%s", out)
	}
}
