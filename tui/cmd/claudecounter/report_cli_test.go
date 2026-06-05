package main

import (
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
