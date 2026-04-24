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
