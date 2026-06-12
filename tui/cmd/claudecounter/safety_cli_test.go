package main

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/safety"
)

func safetyFixture() ([]safety.Row, safety.Summary) {
	rows := []safety.Row{
		{
			Project: "-workspace-sandbox", Turns: 10, Sessions: 1,
			ModeTurns:   map[string]int{"bypassPermissions": 10},
			BypassTurns: 10, BypassPct: 100, ContainerSessions: 1,
			Entrypoints: []string{"cli"},
		},
		{
			Project: "-Users-jane-src-alpha-app-deep", Turns: 20, Sessions: 3,
			ModeTurns:   map[string]int{"default": 15, "auto": 4, "bypassPermissions": 1},
			BypassTurns: 1, BypassPct: 5,
			Entrypoints: []string{"cli", "sdk-py"},
		},
	}
	sum := safety.Summary{
		TotalTurns: 30, BypassTurns: 11, BypassPct: 36.7,
		BypassProjects: 2, ContainerSessions: 1,
	}
	return rows, sum
}

func TestWriteSafety(t *testing.T) {
	rows, sum := safetyFixture()
	var b strings.Builder
	writeSafety(&b, rows, sum, 90)
	out := b.String()

	for _, want := range []string{
		"last 90 days",
		"⚠ 11 turns (36.7%) ran with permissions bypassed, in 2 project(s) · 1 likely-container session(s)",
		"likely(1)",
		"100%",
		"cli,sdk-py",
		"heuristic",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

func TestWriteSafety_QuietWindow(t *testing.T) {
	var b strings.Builder
	writeSafety(&b, nil, safety.Summary{TotalTurns: 5}, 30)
	if !strings.Contains(b.String(), "No bypassPermissions turns in this window (5 turns total).") {
		t.Errorf("quiet output:\n%s", b.String())
	}
}

func TestWriteSafetyCSV(t *testing.T) {
	rows, _ := safetyFixture()
	var b strings.Builder
	if err := writeSafetyCSV(&b, rows); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(b.String()), "\n")
	if len(lines) != 3 {
		t.Fatalf("lines = %d:\n%s", len(lines), b.String())
	}
	if lines[0] != "project,turns,sessions,default,accept_edits,plan,auto,dont_ask,bypass,bypass_pct,container_sessions,entrypoints" {
		t.Errorf("header = %s", lines[0])
	}
	if lines[1] != "-workspace-sandbox,10,1,0,0,0,0,0,10,100.0,1,cli" {
		t.Errorf("row1 = %s", lines[1])
	}
	if lines[2] != "-Users-jane-src-alpha-app-deep,20,3,15,0,0,4,0,1,5.0,0,cli sdk-py" {
		t.Errorf("row2 = %s", lines[2])
	}
}
