package agg

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
)

// codexParityFixture is shared verbatim with the Swift suite (see
// CodexParityTests.swift). Unlike costed_parity.json and grouping_parity.json,
// this fixture drives the real Aggregator.Apply/Snapshot path rather than
// feeding pre-summed usd straight into Group(): Codex is priced, not costed,
// so the behavior worth pinning cross-language — the pricing table lookup,
// and codex-auto-review's alias to gpt-5.6-luna — only fires if each
// language's own pricing.Table.Cost actually runs. The fixture's pricing
// table has a row for gpt-5.6-luna but none for codex-auto-review itself, so
// a non-zero codex-auto-review cost is reachable only through the alias.
const codexParityFixture = "../../../macapp/Tests/ClaudeCounterCoreTests/Fixtures/codex_parity.json"

type codexParityNow struct {
	Year, Month, Day, Hour int
}

type codexParityPrice struct {
	Input       float64 `json:"input"`
	Output      float64 `json:"output"`
	CacheCreate float64 `json:"cacheCreate"`
	CacheRead   float64 `json:"cacheRead"`
}

type codexParityEvent struct {
	MsgID       string `json:"msgID"`
	ReqID       string `json:"reqID"`
	Source      string `json:"source"`
	Project     string `json:"project"`
	Model       string `json:"model"`
	DayOffset   int    `json:"dayOffset"`
	Input       uint64 `json:"input"`
	Output      uint64 `json:"output"`
	CacheCreate uint64 `json:"cacheCreate"`
	CacheRead   uint64 `json:"cacheRead"`
}

type codexParityTokens struct {
	Input       uint64 `json:"input"`
	Output      uint64 `json:"output"`
	CacheCreate uint64 `json:"cacheCreate"`
	CacheRead   uint64 `json:"cacheRead"`
}

type codexParityDaily struct {
	USD    float64 `json:"usd"`
	Tokens uint64  `json:"tokens"`
}

type codexParityProj struct {
	USD         float64 `json:"usd"`
	Input       uint64  `json:"input"`
	Output      uint64  `json:"output"`
	CacheCreate uint64  `json:"cacheCreate"`
	CacheRead   uint64  `json:"cacheRead"`
}

type codexParityFixtureFile struct {
	Now               codexParityNow                          `json:"now"`
	Pricing           map[string]codexParityPrice             `json:"pricing"`
	Events            []codexParityEvent                      `json:"events"`
	ExpectUnknown     int                                     `json:"expectUnknown"`
	ExpectMonth       map[string]map[string]float64           `json:"expectMonth"`
	ExpectMonthTokens map[string]map[string]codexParityTokens `json:"expectMonthTokens"`
	ExpectDay         map[string]map[string]float64           `json:"expectDay"`
	ExpectDayTokens   map[string]map[string]codexParityTokens `json:"expectDayTokens"`
	ExpectMonthProj   map[string]codexParityProj              `json:"expectMonthProj"`
	ExpectDayProj     map[string]codexParityProj              `json:"expectDayProj"`
	ExpectDaily       map[string]codexParityDaily             `json:"expectDaily"`
}

func loadCodexParityFixture(t *testing.T) codexParityFixtureFile {
	t.Helper()
	body, err := os.ReadFile(filepath.Clean(codexParityFixture))
	if err != nil {
		t.Fatalf("read codex parity fixture: %v", err)
	}
	var f codexParityFixtureFile
	if err := json.Unmarshal(body, &f); err != nil {
		t.Fatalf("parse codex parity fixture: %v", err)
	}
	if len(f.Events) == 0 {
		t.Fatal("codex parity fixture has no events")
	}
	return f
}

func TestCodexParity(t *testing.T) {
	f := loadCodexParityFixture(t)

	table := pricing.Table{Models: map[string]pricing.ModelPrice{}}
	for model, p := range f.Pricing {
		table.Models[model] = pricing.ModelPrice{
			InputPerMTok:         p.Input,
			OutputPerMTok:        p.Output,
			CacheCreationPerMTok: p.CacheCreate,
			CacheReadPerMTok:     p.CacheRead,
		}
	}

	now := time.Date(f.Now.Year, time.Month(f.Now.Month), f.Now.Day, f.Now.Hour, 0, 0, 0, time.Local)
	a := NewWithClock(table, func() time.Time { return now })

	for _, e := range f.Events {
		ts := now.AddDate(0, 0, e.DayOffset)
		a.Apply(reader.Event{
			Timestamp: ts,
			Model:     e.Model,
			MessageID: e.MsgID,
			RequestID: e.ReqID,
			Project:   e.Project,
			Source:    e.Source,
			Vendor:    "codex",
			Usage: pricing.Usage{
				InputTokens:              e.Input,
				OutputTokens:             e.Output,
				CacheCreationInputTokens: e.CacheCreate,
				CacheReadInputTokens:     e.CacheRead,
			},
		})
	}

	snap := a.Snapshot()

	if snap.Unknown != f.ExpectUnknown {
		t.Errorf("Unknown = %d, want %d (codex-auto-review must resolve via alias, never count as unpriced)", snap.Unknown, f.ExpectUnknown)
	}

	modes := map[string]Mode{
		"model":  GroupModel,
		"vendor": GroupVendor,
		"source": GroupSource,
		"total":  GroupTotal,
	}

	checkScope := func(t *testing.T, scopeName string, in map[SeriesKey]ModelDay, wantUSD map[string]map[string]float64, wantTok map[string]map[string]codexParityTokens) {
		for name, mode := range modes {
			t.Run(scopeName+"_"+name, func(t *testing.T) {
				want, ok := wantUSD[name]
				if !ok {
					t.Fatalf("fixture has no %s USD expectations for mode %q", scopeName, name)
				}
				wantTokens, ok := wantTok[name]
				if !ok {
					t.Fatalf("fixture has no %s token expectations for mode %q", scopeName, name)
				}
				got := Group(in, mode)
				if len(got) != len(want) {
					t.Fatalf("%s mode %s: got %d buckets, want %d: got=%+v want=%+v", scopeName, name, len(got), len(want), got, want)
				}
				for bucket, wantUSDVal := range want {
					g, ok := got[bucket]
					if !ok {
						t.Errorf("%s mode %s: missing bucket %q, want USD %v", scopeName, name, bucket, wantUSDVal)
						continue
					}
					if math.Abs(g.USD-wantUSDVal) > 0.0001 {
						t.Errorf("%s mode %s: bucket %q USD = %v, want %v", scopeName, name, bucket, g.USD, wantUSDVal)
					}
					wt, ok := wantTokens[bucket]
					if !ok {
						t.Errorf("%s mode %s: missing token expectation for bucket %q", scopeName, name, bucket)
						continue
					}
					if g.Tokens.In != wt.Input || g.Tokens.Out != wt.Output ||
						g.Tokens.CacheCreate != wt.CacheCreate || g.Tokens.CacheRead != wt.CacheRead {
						t.Errorf("%s mode %s: bucket %q Tokens = %+v, want %+v", scopeName, name, bucket, g.Tokens, wt)
					}
				}
			})
		}
	}

	checkScope(t, "month", snap.Month, f.ExpectMonth, f.ExpectMonthTokens)
	checkScope(t, "day", snap.Day, f.ExpectDay, f.ExpectDayTokens)

	t.Run("month_project", func(t *testing.T) {
		if len(f.ExpectMonthProj) == 0 {
			t.Fatal("fixture has no month-project expectations")
		}
		for proj, want := range f.ExpectMonthProj {
			pd, ok := snap.MonthProj[proj]
			if !ok {
				t.Fatalf("missing MonthProj entry for %q", proj)
			}
			if math.Abs(pd.USD()-want.USD) > 0.0001 {
				t.Errorf("MonthProj[%q].USD() = %v, want %v", proj, pd.USD(), want.USD)
			}
			tok := pd.Tokens()
			if tok.In != want.Input || tok.Out != want.Output ||
				tok.CacheCreate != want.CacheCreate || tok.CacheRead != want.CacheRead {
				t.Errorf("MonthProj[%q].Tokens() = %+v, want %+v", proj, tok, want)
			}
		}
	})

	t.Run("day_project", func(t *testing.T) {
		if len(f.ExpectDayProj) == 0 {
			t.Fatal("fixture has no day-project expectations")
		}
		for proj, want := range f.ExpectDayProj {
			pd, ok := snap.DayProj[proj]
			if !ok {
				t.Fatalf("missing DayProj entry for %q", proj)
			}
			if math.Abs(pd.USD()-want.USD) > 0.0001 {
				t.Errorf("DayProj[%q].USD() = %v, want %v", proj, pd.USD(), want.USD)
			}
			tok := pd.Tokens()
			if tok.In != want.Input || tok.Out != want.Output ||
				tok.CacheCreate != want.CacheCreate || tok.CacheRead != want.CacheRead {
				t.Errorf("DayProj[%q].Tokens() = %+v, want %+v", proj, tok, want)
			}
		}
		// proj-b has no events on today's civil day (its two events fall on
		// dayOffset -1 and -2), so it must be entirely absent from DayProj
		// rather than present with a zero total.
		if _, ok := snap.DayProj["proj-b"]; ok {
			t.Error(`DayProj["proj-b"] present, want absent (no events today)`)
		}
	})

	t.Run("daily", func(t *testing.T) {
		if len(f.ExpectDaily) == 0 {
			t.Fatal("fixture has no daily expectations")
		}
		byDay := make(map[string]DailyTotal, len(snap.Daily))
		for _, d := range snap.Daily {
			byDay[d.Day] = d
		}
		for offsetStr, want := range f.ExpectDaily {
			offset, err := strconv.Atoi(offsetStr)
			if err != nil {
				t.Fatalf("bad offset %q in fixture: %v", offsetStr, err)
			}
			day := now.AddDate(0, 0, offset).Format("2006-01-02")
			got, ok := byDay[day]
			if !ok {
				t.Fatalf("Daily has no entry for %s (offset %s)", day, offsetStr)
			}
			if math.Abs(got.USD-want.USD) > 0.0001 {
				t.Errorf("Daily[%s] (offset %s) USD = %v, want %v", day, offsetStr, got.USD, want.USD)
			}
			if got.Tokens != want.Tokens {
				t.Errorf("Daily[%s] (offset %s) Tokens = %v, want %v", day, offsetStr, got.Tokens, want.Tokens)
			}
		}
	})
}
