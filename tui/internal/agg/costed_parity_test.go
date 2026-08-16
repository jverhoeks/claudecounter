package agg

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
)

// costedParityFixture is shared verbatim with the Swift suite (see
// CostedParityTests.swift). It is a second fixture, separate from
// grouping_parity.json: that one pins Group over priced series only.
// This one adds a costed vendor — Grok, whose dollars come from the
// provider rather than a pricing table — plus a coverage tally, so a
// costed cell and its coverage marker are pinned cross-language exactly
// like every other shared quantity.
//
// The fixture's two Grok models (grok-4.5-build, grok-4-fast) both carry
// a non-zero dayUSD because they arose from one turn whose modelUsage
// array had two entries: a single turn_completed event that reported
// usage against both models at once.
const costedParityFixture = "../../../macapp/Tests/ClaudeCounterCoreTests/Fixtures/costed_parity.json"

type costedParitySeries struct {
	Source string  `json:"source"`
	Vendor string  `json:"vendor"`
	Model  string  `json:"model"`
	USD    float64 `json:"usd"`    // month total
	Tokens uint64  `json:"tokens"` // month total
	DayUSD float64 `json:"dayUsd"` // this series' contribution to the fixture's one day
}

type costedParityCoverage struct {
	Turns     int `json:"turns"`
	WithUsage int `json:"withUsage"`
}

type costedParityFixtureFile struct {
	Series                 []costedParitySeries            `json:"series"`
	Expect                 map[string]map[string]float64   `json:"expect"`
	ExpectTokens           map[string]map[string]uint64    `json:"expectTokens"`
	DayTotalUSD            float64                         `json:"dayTotalUSD"`
	Coverage               map[string]costedParityCoverage `json:"coverage"`
	ExpectCoverageFraction map[string]float64              `json:"expectCoverageFraction"`
}

func TestCostedParity(t *testing.T) {
	body, err := os.ReadFile(filepath.Clean(costedParityFixture))
	if err != nil {
		t.Fatalf("read costed parity fixture: %v", err)
	}
	var f costedParityFixtureFile
	if err := json.Unmarshal(body, &f); err != nil {
		t.Fatalf("parse costed parity fixture: %v", err)
	}
	if len(f.Series) == 0 {
		t.Fatal("costed parity fixture has no series")
	}
	if len(f.Expect) == 0 {
		t.Fatal("costed parity fixture has no expectations")
	}
	if len(f.Coverage) == 0 {
		t.Fatal("costed parity fixture has no coverage")
	}

	monthIn := make(map[SeriesKey]ModelDay, len(f.Series))
	dayIn := make(map[SeriesKey]ModelDay, len(f.Series))
	for _, s := range f.Series {
		k := SeriesKey{Source: s.Source, Vendor: s.Vendor, Model: s.Model}

		cur := monthIn[k]
		cur.USD += s.USD
		cur.Tokens.In += s.Tokens
		monthIn[k] = cur

		dcur := dayIn[k]
		dcur.USD += s.DayUSD
		dayIn[k] = dcur
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
			got := Group(monthIn, mode)
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

	// The daily-window figure the sparkline shows for the fixture's one
	// day is a separate Group() call over the day-scoped series, exactly
	// as Snapshot's Daily computation is a separate pass from Month.
	t.Run("day_window", func(t *testing.T) {
		got := Group(dayIn, GroupTotal)["total"].USD
		if math.Abs(got-f.DayTotalUSD) > 0.0001 {
			t.Errorf("day-window total = %v, want %v", got, f.DayTotalUSD)
		}
	})

	// Coverage isn't grouped here (GroupCoverage's worst-vendor rule has
	// its own unit test); this just pins the raw fraction the fixture's
	// turn tally produces, since that arithmetic is what the coverage
	// marker in the UI is built on.
	t.Run("coverage", func(t *testing.T) {
		if len(f.ExpectCoverageFraction) == 0 {
			t.Fatal("costed parity fixture has no coverage fraction expectations")
		}
		for vendor, wantFraction := range f.ExpectCoverageFraction {
			c, ok := f.Coverage[vendor]
			if !ok {
				t.Fatalf("fixture coverage missing vendor %q", vendor)
			}
			cov := Coverage{Turns: c.Turns, WithUsage: c.WithUsage}
			if math.Abs(cov.Fraction()-wantFraction) > 0.0001 {
				t.Errorf("coverage[%q].Fraction() = %v, want %v", vendor, cov.Fraction(), wantFraction)
			}
		}
	})
}
