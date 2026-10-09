package hints

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/perf"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// Ports of the macapp's HintsTests.

var now = time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)

type opt func(*perf.Sample)

func sample(i int, t time.Time, context, read uint64, opts ...opt) perf.Sample {
	s := perf.Sample{
		RequestID: fmt.Sprintf("r%d", i), Time: t, Model: "claude-opus-5-5", Effort: "medium",
		FirstBlock: 2, Duration: 5, Output: 300, Context: context, CacheRead: read,
		CacheWrite: context - read, Session: "s1",
	}
	for _, o := range opts {
		o(&s)
	}
	return s
}

// growingSession is one main session growing step tokens per turn from
// 100k, a turn a minute.
func growingSession(step int) []perf.Sample {
	var out []perf.Sample
	for i := 0; i < 100; i++ {
		ctx := uint64(100_000 + i*step)
		out = append(out, sample(i, now.Add(time.Duration(i-100)*time.Minute), ctx, ctx-uint64(step),
			func(s *perf.Sample) { s.CacheWrite1h = uint64(step) }))
	}
	return out
}

func find(hs []Hint, k Kind) *Hint {
	for i := range hs {
		if hs[i].ID == k {
			return &hs[i]
		}
	}
	return nil
}

func TestCompact_FiresForBigContextsAndKnowsWhenApplied(t *testing.T) {
	p := pricing.Defaults()
	s := growingSession(4_000)
	h := find(Build(s, p, Settings{}, 7, now), Compact)
	if h == nil || h.SavingUSD <= 0 || h.Applied != "" || h.Snippet != `"autoCompactWindow": 200000` {
		t.Fatalf("compact = %+v", h)
	}
	w := 200_000
	if a := find(Build(s, p, Settings{AutoCompactWindow: &w}, 7, now), Compact); a == nil || a.Applied == "" {
		t.Errorf("applied = %+v", a)
	}
}

func TestCacheTTL_OnlyWhenPausesDontNeedTheHour(t *testing.T) {
	p := pricing.Defaults()
	quick := growingSession(20_000)
	if find(Build(quick, p, Settings{}, 7, now), CacheTTL) == nil {
		t.Error("back-to-back 1h writes should hint")
	}
	paused := append([]perf.Sample(nil), quick...)
	for i := range paused {
		paused[i].Time = now.Add(time.Duration(i-100) * 20 * time.Minute)
	}
	if find(Build(paused, p, Settings{}, 7, now), CacheTTL) != nil {
		t.Error("20-minute pauses need the hour")
	}
}

func TestSubagentModel_PricesTheSwitchToSonnet(t *testing.T) {
	p := pricing.Defaults()
	var subs []perf.Sample
	for i := 0; i < 50; i++ {
		subs = append(subs, sample(i, now.Add(-time.Hour), 2_000_000, 1_900_000, func(s *perf.Sample) {
			s.IsSubagent = true
			s.Session = fmt.Sprintf("sub%d", i)
		}))
	}
	h := find(Build(subs, p, Settings{}, 7, now), SubagentModel)
	if h == nil || h.SavingUSD <= 0 || h.SavingUSD >= Spend(subs, p) {
		t.Fatalf("subagent = %+v", h)
	}
	if a := find(Build(subs, p, Settings{SubagentModel: "claude-sonnet-5"}, 7, now), SubagentModel); a == nil || a.Applied == "" {
		t.Errorf("applied = %+v", a)
	}
}

func TestOldSamplesAreOutsideThePeriod(t *testing.T) {
	old := growingSession(4_000)
	for i := range old {
		old[i].Time = old[i].Time.Add(-30 * 24 * time.Hour)
	}
	if hs := Build(old, pricing.Defaults(), Settings{}, 7, now); len(hs) != 0 {
		t.Errorf("hints = %+v", hs)
	}
}

func TestLoadSettings_ReadsTheKeysHintsCheck(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	os.WriteFile(path, []byte(`{"autoCompactWindow": 200000, "promptCacheTtl": "5m", "model": "claude-opus-5-5", "effortLevel": "high",
	 "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-5"}, "statusLine": 3,
	 "modelSettings": {"claude-opus-5": {"effortLevel": "xhigh"}, "odd": true}}`), 0o600)
	c := LoadSettings(path)
	if c.AutoCompactWindow == nil || *c.AutoCompactWindow != 200_000 || c.PromptCacheTTL != "5m" || c.SubagentModel != "claude-sonnet-5" {
		t.Errorf("settings = %+v", c)
	}
	if c.EffortFor("claude-opus-5") != "xhigh" || c.EffortFor("claude-opus-5-5") != "high" {
		t.Errorf("effort = %+v", c)
	}
	if e := LoadSettings("/nonexistent/settings.json"); e.AutoCompactWindow != nil || e.Model != "" {
		t.Errorf("missing file = %+v", e)
	}
}
