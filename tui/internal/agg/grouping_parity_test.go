package agg

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
)

// groupingParityFixture is shared verbatim with the Swift suite (see
// GroupingParityTests.swift). It lives under the macapp test bundle
// because SwiftPM must copy it as a resource; Go reads the same bytes
// here so both languages evaluate identical per-series spend and are
// pinned to agree on every grouping mode.
//
// This is a second fixture, separate from limits_parity.json, which
// pins the budget engines (Evaluate). This one pins Group/Mode instead
// — if these disagree, the TUI and the menu bar app disagree about
// what a vendor, source, or subscription total is.
//
// To add a case: append a series to the top-level "series" array and
// update the affected buckets in "expect" and "expectTokens". Both
// TestGroupingParity (here) and GroupingParityTests.swift read the same
// file, so one addition covers both languages.
const groupingParityFixture = "../../../macapp/Tests/ClaudeCounterCoreTests/Fixtures/grouping_parity.json"

type groupingParitySeries struct {
	Source string  `json:"source"`
	Vendor string  `json:"vendor"`
	Model  string  `json:"model"`
	USD    float64 `json:"usd"`
	Tokens uint64  `json:"tokens"`
}

type groupingParityFixtureFile struct {
	Series       []groupingParitySeries        `json:"series"`
	Expect       map[string]map[string]float64 `json:"expect"`
	ExpectTokens map[string]map[string]uint64  `json:"expectTokens"`
}

func TestGroupingParity(t *testing.T) {
	body, err := os.ReadFile(filepath.Clean(groupingParityFixture))
	if err != nil {
		t.Fatalf("read grouping parity fixture: %v", err)
	}
	var f groupingParityFixtureFile
	if err := json.Unmarshal(body, &f); err != nil {
		t.Fatalf("parse grouping parity fixture: %v", err)
	}
	if len(f.Series) == 0 {
		t.Fatal("grouping parity fixture has no series")
	}
	if len(f.Expect) == 0 {
		t.Fatal("grouping parity fixture has no expectations")
	}
	if len(f.ExpectTokens) == 0 {
		t.Fatal("grouping parity fixture has no token expectations")
	}

	in := make(map[SeriesKey]ModelDay, len(f.Series))
	for _, s := range f.Series {
		k := SeriesKey{Source: s.Source, Vendor: s.Vendor, Model: s.Model}
		cur := in[k]
		cur.USD += s.USD
		cur.Tokens.In += s.Tokens
		in[k] = cur
	}

	modes := map[string]Mode{
		"model":  GroupModel,
		"vendor": GroupVendor,
		"source": GroupSource,
		"total":  GroupTotal,
	}

	for name, mode := range modes {
		t.Run(name, func(t *testing.T) {
			want, ok := f.Expect[name]
			if !ok {
				t.Fatalf("fixture has no expectations for mode %q", name)
			}
			wantTokens, ok := f.ExpectTokens[name]
			if !ok {
				t.Fatalf("fixture has no token expectations for mode %q", name)
			}
			got := Group(in, mode)
			if len(got) != len(want) {
				t.Fatalf("mode %s: got %d buckets, want %d: got=%+v want=%+v", name, len(got), len(want), got, want)
			}
			for bucket, wantUSD := range want {
				g, ok := got[bucket]
				if !ok {
					t.Errorf("mode %s: missing bucket %q, want USD %v", name, bucket, wantUSD)
					continue
				}
				if math.Abs(g.USD-wantUSD) > 0.0001 {
					t.Errorf("mode %s: bucket %q USD = %v, want %v", name, bucket, g.USD, wantUSD)
				}
				wantTok, ok := wantTokens[bucket]
				if !ok {
					t.Errorf("mode %s: missing token expectation for bucket %q", name, bucket)
					continue
				}
				if g.Tokens.In != wantTok {
					t.Errorf("mode %s: bucket %q Tokens.In = %v, want %v", name, bucket, g.Tokens.In, wantTok)
				}
			}
		})
	}
}
