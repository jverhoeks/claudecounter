package agg

import (
	"testing"
	"time"

	"github.com/jjverhoeks/claudecounter/internal/pricing"
	"github.com/jjverhoeks/claudecounter/internal/reader"
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

func TestApply_SameMessageIDReplacesPrevious(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	// Partial streamed line — lower counts, same msgid.
	e1 := mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 100, 50)
	e1.MessageID = "msg_abc"
	a.Apply(e1)

	// Final line — larger counts, same msgid. Must REPLACE the first.
	e2 := mkEvent(now.UTC().Format(time.RFC3339), "claude-opus-4-7", 1_000_000, 1_000_000)
	e2.MessageID = "msg_abc"
	a.Apply(e2)

	snap := a.Snapshot()
	wantUSD := 15.0 + 75.0 // 1M input * $15 + 1M output * $75
	if got := snap.Day["claude-opus-4-7"].USD; got != wantUSD {
		t.Errorf("USD: got %v want %v (first line should have been replaced)", got, wantUSD)
	}
	if got := snap.Day["claude-opus-4-7"].Tokens.In; got != 1_000_000 {
		t.Errorf("input tokens not replaced: got %d want 1000000", got)
	}
	if snap.Dupes != 1 {
		t.Errorf("Dupes: got %d want 1", snap.Dupes)
	}
}

func TestApply_UnknownModelCountsDistinctMessageIDs(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	// Three lines, same msgid, unknown model — must count as ONE unknown.
	for i := 0; i < 3; i++ {
		e := mkEvent(now.UTC().Format(time.RFC3339), "claude-foo-x", 100, 100)
		e.MessageID = "msg_same"
		a.Apply(e)
	}
	// Different msgid, still unknown — adds a second.
	e2 := mkEvent(now.UTC().Format(time.RFC3339), "claude-foo-x", 100, 100)
	e2.MessageID = "msg_other"
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
