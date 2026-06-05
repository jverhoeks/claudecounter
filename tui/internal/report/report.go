// Package report joins Claude spend (per project/day, from agg) with git
// activity (per repo, from gitstat) into per-repo, per-bucket rows. Build
// is pure and unit-tested; Scan and Gather (next task) wrap it with I/O.
package report

import (
	"fmt"
	"sort"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/gitstat"
)

// BucketSize is the time granularity of report rows.
type BucketSize int

const (
	BucketDay BucketSize = iota
	BucketWeek
	BucketMonth
)

// CostDay is one day's Claude cost attributed to a repo (summed across all
// project keys that map to the repo root).
type CostDay struct {
	Day    time.Time
	USD    float64
	Tokens uint64
}

// RepoInput is the pre-grouped cost + commits for a single repo root.
type RepoInput struct {
	Root     string
	CostDays []CostDay
	Commits  []gitstat.Commit
}

// Bucket is one (repo, time-bucket) row. Raw components are primary; the
// ratios are derived garnish and are 0 when their denominator is 0.
type Bucket struct {
	Label        string
	Sort         string // sortable key (same as Label for our formats)
	USD          float64
	CommitsMine  int
	CommitsAll   int
	Added        int // mine
	Deleted      int // mine
	Files        int // mine
	USDPerCommit float64
	USDPerLine   float64
	Tokens       uint64
	TokPerCommit float64
	TokPerLine   float64
}

// RepoReport is all buckets for one repo plus the window total.
type RepoReport struct {
	Root    string
	Buckets []Bucket
	Total   Bucket
}

// bucketLabel returns the (label, sortKey) for t at the given granularity.
func bucketLabel(t time.Time, size BucketSize) (string, string) {
	lt := t.Local()
	switch size {
	case BucketDay:
		s := lt.Format("2006-01-02")
		return s, s
	case BucketMonth:
		s := lt.Format("2006-01")
		return s, s
	default: // BucketWeek
		y, w := lt.ISOWeek()
		s := fmt.Sprintf("%04d-W%02d", y, w)
		return s, s
	}
}

func ratios(b *Bucket) {
	if b.CommitsMine > 0 {
		b.USDPerCommit = b.USD / float64(b.CommitsMine)
	}
	if lines := b.Added + b.Deleted; lines > 0 {
		b.USDPerLine = b.USD / float64(lines)
	}
	if b.CommitsMine > 0 {
		b.TokPerCommit = float64(b.Tokens) / float64(b.CommitsMine)
	}
	if lines := b.Added + b.Deleted; lines > 0 {
		b.TokPerLine = float64(b.Tokens) / float64(lines)
	}
}

// Build joins each repo's cost-days and commits into chronological buckets,
// computing ratios from "mine" commits/lines only. Repos are returned
// sorted by descending total spend.
func Build(inputs []RepoInput, size BucketSize) []RepoReport {
	var out []RepoReport
	for _, in := range inputs {
		byLabel := map[string]*Bucket{}
		get := func(t time.Time) *Bucket {
			label, sortKey := bucketLabel(t, size)
			b := byLabel[label]
			if b == nil {
				b = &Bucket{Label: label, Sort: sortKey}
				byLabel[label] = b
			}
			return b
		}

		total := Bucket{Label: "total"}
		for _, c := range in.CostDays {
			b := get(c.Day)
			b.USD += c.USD
			b.Tokens += c.Tokens
			total.USD += c.USD
			total.Tokens += c.Tokens
		}
		for _, c := range in.Commits {
			b := get(c.Date)
			b.CommitsAll++
			total.CommitsAll++
			if c.Mine {
				b.CommitsMine++
				b.Added += c.Added
				b.Deleted += c.Deleted
				b.Files += c.Files
				total.CommitsMine++
				total.Added += c.Added
				total.Deleted += c.Deleted
				total.Files += c.Files
			}
		}

		buckets := make([]Bucket, 0, len(byLabel))
		for _, b := range byLabel {
			ratios(b)
			buckets = append(buckets, *b)
		}
		sort.Slice(buckets, func(i, j int) bool { return buckets[i].Sort < buckets[j].Sort })
		ratios(&total)

		out = append(out, RepoReport{Root: in.Root, Buckets: buckets, Total: total})
	}

	sort.Slice(out, func(i, j int) bool { return out[i].Total.USD > out[j].Total.USD })
	return out
}
