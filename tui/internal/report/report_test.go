package report

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/gitstat"
)

func day(y int, m time.Month, d int) time.Time {
	return time.Date(y, m, d, 12, 0, 0, 0, time.Local)
}

func TestBuild_BucketsRatiosAndMineVsAll(t *testing.T) {
	inputs := []RepoInput{{
		Root: "/repo/alpha",
		CostDays: []CostDay{
			{Day: day(2026, 6, 1), USD: 8},  // Mon, ISO 2026-W23
			{Day: day(2026, 6, 2), USD: 2},  // Tue, same week
			{Day: day(2026, 6, 8), USD: 5},  // next Mon, 2026-W24
		},
		Commits: []gitstat.Commit{
			{Date: day(2026, 6, 1), Added: 100, Deleted: 0, Files: 2, Mine: true},
			{Date: day(2026, 6, 2), Added: 0, Deleted: 0, Files: 1, Mine: false}, // coworker
			{Date: day(2026, 6, 8), Added: 50, Deleted: 50, Files: 1, Mine: true},
		},
	}}

	reports := Build(inputs, BucketWeek)
	if len(reports) != 1 {
		t.Fatalf("got %d repos, want 1", len(reports))
	}
	r := reports[0]
	if len(r.Buckets) != 2 {
		t.Fatalf("got %d buckets, want 2", len(r.Buckets))
	}

	// Buckets are chronological.
	w23 := r.Buckets[0]
	if w23.USD != 10 {
		t.Errorf("W23 USD = %v, want 10", w23.USD)
	}
	if w23.CommitsMine != 1 || w23.CommitsAll != 2 {
		t.Errorf("W23 commits = mine %d / all %d, want 1/2", w23.CommitsMine, w23.CommitsAll)
	}
	// $/commit uses mine only: 10 / 1 = 10
	if w23.USDPerCommit != 10 {
		t.Errorf("W23 $/commit = %v, want 10", w23.USDPerCommit)
	}
	// $/line uses mine added+deleted: 10 / 100 = 0.1
	if w23.USDPerLine != 0.1 {
		t.Errorf("W23 $/line = %v, want 0.1", w23.USDPerLine)
	}

	if r.Total.USD != 15 {
		t.Errorf("total USD = %v, want 15", r.Total.USD)
	}
	if r.Total.CommitsMine != 2 {
		t.Errorf("total commits mine = %d, want 2", r.Total.CommitsMine)
	}
}

func TestBuild_ZeroCommitsNoDivideByZero(t *testing.T) {
	inputs := []RepoInput{{
		Root:     "/repo/beta",
		CostDays: []CostDay{{Day: day(2026, 6, 1), USD: 12}},
		Commits:  nil,
	}}
	r := Build(inputs, BucketWeek)[0]
	if r.Buckets[0].USDPerCommit != 0 {
		t.Errorf("$/commit with no commits should be 0, got %v", r.Buckets[0].USDPerCommit)
	}
	if r.Buckets[0].USDPerLine != 0 {
		t.Errorf("$/line with no lines should be 0, got %v", r.Buckets[0].USDPerLine)
	}
}
