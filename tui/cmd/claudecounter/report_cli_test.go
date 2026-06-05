package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

func TestParseBucket(t *testing.T) {
	cases := map[string]report.BucketSize{
		"day":   report.BucketDay,
		"week":  report.BucketWeek,
		"month": report.BucketMonth,
		"":      report.BucketWeek, // default
		"bogus": report.BucketWeek, // fallback
	}
	for in, want := range cases {
		if got := parseBucket(in); got != want {
			t.Errorf("parseBucket(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestWriteReportCSV(t *testing.T) {
	reports := []report.RepoReport{{
		Root: "/Users/me/git/alpha",
		Buckets: []report.Bucket{
			{Label: "2026-W23", USD: 10, CommitsMine: 3, CommitsAll: 5,
				Added: 120, Deleted: 40, Files: 8, USDPerCommit: 3.3333, USDPerLine: 0.0625,
				Tokens: 1000},
			{Label: "2026-W24", USD: 5, CommitsMine: 0, CommitsAll: 1,
				Added: 0, Deleted: 0, Files: 0, USDPerCommit: 0, USDPerLine: 0,
				Tokens: 0},
		},
	}}

	var buf bytes.Buffer
	if err := writeReportCSV(&buf, reports); err != nil {
		t.Fatal(err)
	}
	out := buf.String()
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 3 { // header + 2 buckets
		t.Fatalf("got %d lines, want 3:\n%s", len(lines), out)
	}
	if lines[0] != "repo,bucket,usd,commits_mine,commits_all,added,deleted,files,usd_per_commit,usd_per_line,tokens,tokens_per_commit,tokens_per_line" {
		t.Errorf("header = %q", lines[0])
	}
	// W23 row: ratios present
	if !strings.HasPrefix(lines[1], "/Users/me/git/alpha,2026-W23,10.00,3,5,120,40,8,") {
		t.Errorf("W23 row = %q", lines[1])
	}
	// W24 row: zero ratios render as empty cells (trailing commas); tokens=0 with empty token ratios
	if !strings.HasSuffix(lines[2], ",,0,,") {
		t.Errorf("W24 row should end with empty ratio cells, got %q", lines[2])
	}
}
