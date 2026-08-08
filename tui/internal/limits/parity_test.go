package limits

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// parityFixture is shared verbatim with the Swift suite (see
// LimitsParityTests.swift). It lives under the macapp test bundle
// because SwiftPM must copy it as a resource; Go reads the same bytes
// here so both languages evaluate identical (now, config, daily totals)
// inputs and are pinned to agree on the result.
//
// Scope: this pins Evaluate() only — the pure window-boundary /
// threshold arithmetic exercised by TestParityFixture below. It does
// NOT pin Load() (Go uses BurntSushi/toml, a real TOML parser; Swift's
// Limits.load is a hand-rolled line reader — see config_test.go's
// TestLoadAcceptsSpacedTableHeader and LimitsTests.swift's matching
// case for one place they used to diverge), the Codex/Grok vendor
// scanners, row construction (BuildRows vs
// GaugeRows.build), or rendering. A change in any of those can still
// make the two surfaces disagree even while this fixture stays green.
//
// To add a case: append an object to the top-level "cases" array in
// limits_parity.json with a "now" (RFC3339), the configured limits,
// a "daily" array of {day, usd} totals, and the "expect" statuses both
// languages must produce. Both TestParityFixture (here) and
// LimitsParityTests.swift read the same file, so one addition covers
// both languages.
const parityFixture = "../../../macapp/Tests/ClaudeCounterCoreTests/Fixtures/limits_parity.json"

type parityCase struct {
	Name        string  `json:"name"`
	Now         string  `json:"now"`
	DailyLimit  float64 `json:"dailyLimit"`
	WeeklyLimit float64 `json:"weeklyLimit"`
	WarnPct     int     `json:"warnPct"`
	Daily       []struct {
		Day string  `json:"day"`
		USD float64 `json:"usd"`
	} `json:"daily"`
	Expect []struct {
		Window   string  `json:"window"`
		SpentUSD float64 `json:"spentUSD"`
		Pct      float64 `json:"pct"`
		State    string  `json:"state"`
	} `json:"expect"`
}

func TestParityFixture(t *testing.T) {
	body, err := os.ReadFile(filepath.Clean(parityFixture))
	if err != nil {
		t.Fatalf("read parity fixture: %v", err)
	}
	var f struct {
		Cases []parityCase `json:"cases"`
	}
	if err := json.Unmarshal(body, &f); err != nil {
		t.Fatalf("parse parity fixture: %v", err)
	}
	if len(f.Cases) == 0 {
		t.Fatal("parity fixture has no cases")
	}

	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			now, err := time.Parse(time.RFC3339, c.Now)
			if err != nil {
				t.Fatalf("parse now: %v", err)
			}
			daily := make([]agg.DailyTotal, 0, len(c.Daily))
			for _, d := range c.Daily {
				daily = append(daily, agg.DailyTotal{Day: d.Day, USD: d.USD})
			}
			got := Evaluate(daily, Config{
				Daily:   c.DailyLimit,
				Weekly:  c.WeeklyLimit,
				WarnPct: c.WarnPct,
			}, now)

			if len(got) != len(c.Expect) {
				t.Fatalf("got %d statuses, want %d", len(got), len(c.Expect))
			}
			for i, want := range c.Expect {
				g := got[i]
				// Compare Key (identity), not String (display label), so
				// this asserts the same field Swift's rawValue does.
				if g.Window.Key() != want.Window {
					t.Errorf("[%d] window = %q, want %q", i, g.Window.Key(), want.Window)
				}
				if math.Abs(g.SpentUSD-want.SpentUSD) > 0.0001 {
					t.Errorf("[%d] SpentUSD = %v, want %v", i, g.SpentUSD, want.SpentUSD)
				}
				if math.Abs(g.Pct-want.Pct) > 0.0001 {
					t.Errorf("[%d] Pct = %v, want %v", i, g.Pct, want.Pct)
				}
				if g.State.String() != want.State {
					t.Errorf("[%d] State = %q, want %q", i, g.State.String(), want.State)
				}
			}
		})
	}
}
