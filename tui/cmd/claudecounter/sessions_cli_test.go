package main

import (
	"strings"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func sessionFixture() *session.Session {
	t0 := time.Date(2026, 6, 1, 10, 0, 0, 0, time.UTC)
	at := func(d time.Duration) time.Time { return t0.Add(d) }
	return &session.Session{
		ID:         "abc123",
		Cwd:        "/Users/jane/src/alpha",
		Entrypoint: "cli",
		Start:      t0,
		End:        at(2*time.Hour + 41*time.Minute),
		Prompts:    2,
		ModeTurns:  map[string]int{"auto": 1, "bypassPermissions": 1},
		ModeChanges: []session.ModeChange{
			{Time: t0, From: "", To: "auto"},
			{Time: at(time.Hour), From: "auto", To: "bypassPermissions"},
		},
		ToolCalls: []session.ToolCall{
			{Time: at(time.Minute), Name: "Bash", Target: "go test ./...", HasResult: true},
			{Time: at(2 * time.Minute), Name: "Read", Target: "/x/a.go", HasResult: true},
			{Time: at(3 * time.Minute), Name: "Read", Target: "/x/a.go", HasResult: true},
			{Time: at(4 * time.Minute), Name: "Edit", Target: "/x/a.go", HasResult: true, IsErr: true},
			{Time: at(5 * time.Minute), Name: "Read", Target: "/x/b.go", HasResult: true, Sub: true},
		},
		Turns: []session.Turn{
			{Time: at(time.Minute), Model: "test-model", Usage: pricing.Usage{InputTokens: 1000, OutputTokens: 500}},
			{Time: at(90 * time.Minute), Model: "test-model", Usage: pricing.Usage{OutputTokens: 2000}, Sub: true},
			{Time: at(100 * time.Minute), Model: "mystery-model", Usage: pricing.Usage{OutputTokens: 9}},
		},
		Tokens:      pricing.Usage{InputTokens: 1000, OutputTokens: 2500, CacheCreationInputTokens: 100, CacheReadInputTokens: 200},
		PeakContext: 164000,
	}
}

func testTable() pricing.Table {
	return pricing.Table{Models: map[string]pricing.ModelPrice{
		"test-model": {InputPerMTok: 10, OutputPerMTok: 100, CacheCreationPerMTok: 1, CacheReadPerMTok: 0.1},
	}}
}

func TestWriteScorecard(t *testing.T) {
	var b strings.Builder
	writeScorecard(&b, sessionFixture(), testTable())
	out := b.String()

	for _, want := range []string{
		"Session abc123",
		"alpha · 2h41m · cli · 2 prompts",
		"auto → bypassPermissions(!)",
		"5 tool calls · 1 failed (20.0%)",
		"Read", "Bash", "Edit",
		"1 file(s) Read 2+ times",
		"a.go", "×2",
		"in 1.0k · out 2.5k",
		"peak ≈ 164.0k tok",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("scorecard missing %q:\n%s", want, out)
		}
	}
	// turn1: 1000*10/1M + 500*100/1M = 0.06; turn2: 2000*100/1M = 0.20;
	// turn3 has no price → excluded from the sum, flagged instead.
	if !strings.Contains(out, "$0.26 ⚠ +1 unpriced turn(s)") {
		t.Errorf("scorecard missing cost + unpriced warning:\n%s", out)
	}
}

func TestWriteTimeline(t *testing.T) {
	var b strings.Builder
	writeTimeline(&b, sessionFixture(), testTable())
	out := b.String()

	for _, want := range []string{
		"Session abc123",
		"Bash       go test ./...",
		"ERR",
		"(sub)",
		"mode       (start) → auto",
		"mode       auto → bypassPermissions  ⚠",
		"turn       test-model",
		"+$?", // unpriced model: unknown cost, not free
	} {
		if !strings.Contains(out, want) {
			t.Errorf("timeline missing %q:\n%s", want, out)
		}
	}

	// Chronological: first mode change precedes the first tool call.
	if strings.Index(out, "(start) → auto") > strings.Index(out, "go test") {
		t.Errorf("timeline not chronological:\n%s", out)
	}
}
