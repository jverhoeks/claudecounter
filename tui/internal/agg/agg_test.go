package agg

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
)

func priced() pricing.Table {
	return pricing.Table{Models: map[string]pricing.ModelPrice{
		"claude-opus-4-7":  {InputPerMTok: 15, OutputPerMTok: 75},
		"claude-sonnet-4-6": {InputPerMTok: 3, OutputPerMTok: 15},
	}}
}

func mkEvent(ts string, model string, inTok, outTok uint64) reader.Event {
	t, _ := time.Parse(time.RFC3339, ts)
	return reader.Event{
		Timestamp: t,
		Model:     model,
		Usage:     pricing.Usage{InputTokens: inTok, OutputTokens: outTok},
	}
}

func TestApplyAndSnapshot_TodayAndMonth(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	a.Apply(mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 0))
	a.Apply(mkEvent(now.Add(-24*time.Hour).UTC().Format(time.RFC3339),
		"claude-sonnet-4-6", 0, 1_000_000))

	snap := a.Snapshot()
	if got := snap.Day["claude-opus-4-7"].USD; got != 15 {
		t.Errorf("today opus USD: %v", got)
	}
	if _, ok := snap.Day["claude-sonnet-4-6"]; ok {
		t.Error("today should not include sonnet event from yesterday")
	}
	if got := snap.Month["claude-opus-4-7"].USD; got != 15 {
		t.Errorf("month opus USD: %v", got)
	}
	if got := snap.Month["claude-sonnet-4-6"].USD; got != 15 {
		t.Errorf("month sonnet USD: %v", got)
	}
}

func TestApply_UnknownModelCounted(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })
	a.Apply(mkEvent(now.UTC().Format(time.RFC3339), "claude-foo-x", 100, 100))
	snap := a.Snapshot()
	if snap.Unknown != 1 {
		t.Errorf("unknown count: %d", snap.Unknown)
	}
	if _, ok := snap.Day["claude-foo-x"]; !ok {
		t.Error("unknown model still needs token accounting")
	}
	if snap.Day["claude-foo-x"].USD != 0 {
		t.Error("unknown model cost must be 0")
	}
}

func TestApply_FirstSeenWinsByMsgIDAndReqID(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	// First line: keep this one.
	e1 := mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 100, 50)
	e1.MessageID = "msg_abc"
	e1.RequestID = "req_x"
	a.Apply(e1)

	// Second line: same msgid+reqid → must be SKIPPED (first-seen wins).
	e2 := mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 1_000_000)
	e2.MessageID = "msg_abc"
	e2.RequestID = "req_x"
	a.Apply(e2)

	snap := a.Snapshot()
	if got := snap.Day["claude-opus-4-7"].Tokens.In; got != 100 {
		t.Errorf("input tokens: got %d want 100 (first-seen)", got)
	}
	if snap.Dupes != 1 {
		t.Errorf("Dupes: got %d want 1", snap.Dupes)
	}
}

func TestApply_NoDedupeWhenMsgIDOrReqIDMissing(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	// Two identical events without msgid+reqid — both must count.
	for i := 0; i < 2; i++ {
		e := mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 0)
		// no MessageID or RequestID
		a.Apply(e)
	}

	snap := a.Snapshot()
	if got := snap.Day["claude-opus-4-7"].Tokens.In; got != 2_000_000 {
		t.Errorf("input tokens: got %d want 2,000,000", got)
	}
	if snap.Dupes != 0 {
		t.Errorf("Dupes: got %d want 0 (cannot dedup w/o keys)", snap.Dupes)
	}
}

func TestApply_DifferentReqIDsForSameMsgIDBothCount(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	for _, rid := range []string{"req_x", "req_y"} {
		e := mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 0)
		e.MessageID = "msg_same"
		e.RequestID = rid
		a.Apply(e)
	}

	snap := a.Snapshot()
	if got := snap.Day["claude-opus-4-7"].Tokens.In; got != 2_000_000 {
		t.Errorf("input tokens: got %d want 2,000,000 (msgid:reqid distinct)", got)
	}
}

func TestApply_UnknownModelCountsDistinctMessageIDs(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	// Same msgid+reqid → only first counts; unknown counter advances once.
	for i := 0; i < 3; i++ {
		e := mkEvent(now.UTC().Format(time.RFC3339), "claude-foo-x", 100, 100)
		e.MessageID = "msg_same"
		e.RequestID = "req_a"
		a.Apply(e)
	}
	// Different msgid, still unknown — adds a second.
	e2 := mkEvent(now.UTC().Format(time.RFC3339), "claude-foo-x", 100, 100)
	e2.MessageID = "msg_other"
	e2.RequestID = "req_b"
	a.Apply(e2)

	snap := a.Snapshot()
	if snap.Unknown != 2 {
		t.Errorf("Unknown: got %d want 2 (distinct message ids)", snap.Unknown)
	}
}

func TestSnapshot_ExcludesPreviousMonth(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })
	prev := time.Date(2026, 3, 21, 15, 0, 0, 0, time.Local)
	a.Apply(mkEvent(prev.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 0))

	snap := a.Snapshot()
	if _, ok := snap.Month["claude-opus-4-7"]; ok {
		t.Error("last month's event must not appear in this-month snapshot")
	}
}

// TestDailyTotal_TokensSumAllFourTypes guards against future regressions
// where someone summing tokens forgets one of the cache fields.
func TestDailyTotal_TokensSumAllFourTypes(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	// One event with non-zero values for ALL four token kinds.
	e := reader.Event{
		Timestamp: now,
		Model:     "claude-opus-4-7",
		Usage: pricing.Usage{
			InputTokens:              100,
			OutputTokens:             200,
			CacheCreationInputTokens: 30,
			CacheReadInputTokens:     70,
		},
	}
	a.Apply(e)

	snap := a.Snapshot()
	last := snap.Daily[len(snap.Daily)-1]
	if last.Tokens != 100+200+30+70 {
		t.Errorf("Daily.Tokens: got %d want %d (input+output+cacheCreate+cacheRead)",
			last.Tokens, 100+200+30+70)
	}
}

// TestDailyTotal_TokensIncludeUnpriced — tokens reflect raw activity
// regardless of pricing coverage. USD continues to count only priced
// models (existing behaviour, asserted alongside for clarity).
func TestDailyTotal_TokensIncludeUnpriced(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	a.Apply(mkEvent(now.UTC().Format(time.RFC3339),
		"claude-mystery-model-9000", 500, 0))

	snap := a.Snapshot()
	last := snap.Daily[len(snap.Daily)-1]
	if last.Tokens != 500 {
		t.Errorf("Daily.Tokens for unpriced model: got %d want 500", last.Tokens)
	}
	if last.USD != 0 {
		t.Errorf("Daily.USD for unpriced model: got %v want 0", last.USD)
	}
}

// TestDailyTotal_TokensSumAcrossModels — daily is unbucketed by model;
// two events from different models on the same day must add together.
func TestDailyTotal_TokensSumAcrossModels(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	a.Apply(mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 100, 0))
	e2 := mkEvent(now.UTC().Format(time.RFC3339), "claude-sonnet-4-6", 250, 0)
	e2.MessageID = "m2"
	e2.RequestID = "r2"
	a.Apply(e2)

	snap := a.Snapshot()
	last := snap.Daily[len(snap.Daily)-1]
	if last.Tokens != 350 {
		t.Errorf("Daily.Tokens summed across models: got %d want 350", last.Tokens)
	}
}
