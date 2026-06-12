package ui

import (
	"errors"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/jverhoeks/claudecounter/tui/internal/safety"
)

func sampleSafety() ([]safety.Row, safety.Summary) {
	rows := []safety.Row{
		{
			Project: "-Users-me-git-alpha", Turns: 100, Sessions: 4,
			ModeTurns:   map[string]int{"default": 70, "auto": 20, "bypassPermissions": 10},
			BypassTurns: 10, BypassPct: 10, ContainerSessions: 1,
			Entrypoints: []string{"cli"},
		},
	}
	sum := safety.Summary{
		TotalTurns: 100, BypassTurns: 10, BypassPct: 10,
		BypassProjects: 1, ContainerSessions: 1,
	}
	return rows, sum
}

func TestSafetyTable_RendersRowsAndSummary(t *testing.T) {
	rows, sum := sampleSafety()
	out := safetyTable(rows, sum)
	for _, want := range []string{
		"⚠ 10 turns (10.0%) ran with permissions bypassed",
		"1 likely-container session(s)",
		"alpha", "70%", "20%", "10%", "likely(1)", "cli",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("safetyTable missing %q\n---\n%s", want, out)
		}
	}
}

func TestSafetyTable_QuietWindow(t *testing.T) {
	out := safetyTable(nil, safety.Summary{TotalTurns: 42})
	if !strings.Contains(out, "No bypassPermissions turns in this window (42 turns total)") {
		t.Errorf("quiet summary missing:\n%s", out)
	}
}

func TestSafetyHeader(t *testing.T) {
	out := safetyHeader(30)
	for _, want := range []string{"last 30 days", "heuristic"} {
		if !strings.Contains(out, want) {
			t.Errorf("safetyHeader missing %q\n---\n%s", want, out)
		}
	}
}

func TestModelView_SafetyLoadingShowsSpinner(t *testing.T) {
	m := NewModel()
	m.mode = ModeSafety
	m.safetyLoading = true
	out := m.View()
	if !strings.Contains(out, "scanning transcripts") {
		t.Errorf("loading view missing spinner text:\n%s", out)
	}
}

func TestModelView_SafetyError(t *testing.T) {
	m := NewModel()
	m.mode = ModeSafety
	m.safetyErr = errors.New("boom")
	out := m.View()
	if !strings.Contains(out, "safety error: boom") {
		t.Errorf("error view missing error text:\n%s", out)
	}
}

func TestUpdate_Key5TriggersSafetyLoad(t *testing.T) {
	m := NewModel()
	called := false
	m.SetSafetyFunc(func(days int) SafetyMsg {
		called = true
		return SafetyMsg{Days: days}
	})
	m2, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'5'}})
	m = m2.(Model)
	if m.mode != ModeSafety {
		t.Fatalf("mode = %v, want ModeSafety", m.mode)
	}
	if !m.safetyLoading || cmd == nil {
		t.Fatal("key 5 should start a lazy safety load")
	}
	cmd() // run the tea.Cmd
	if !called {
		t.Error("safety func not invoked")
	}
}

func TestUpdate_SafetyMsgPopulatesViewport(t *testing.T) {
	m := NewModel()
	m2, _ := m.Update(tea.WindowSizeMsg{Width: 120, Height: 40})
	m = m2.(Model)
	m.mode = ModeSafety
	rows, sum := sampleSafety()
	m3, _ := m.Update(SafetyMsg{Rows: rows, Sum: sum, Days: 30})
	m = m3.(Model)
	if m.safetyLoading || !m.safetyLoaded {
		t.Error("SafetyMsg should clear loading and mark loaded")
	}
	if m.safetyDays != 30 {
		t.Errorf("safetyDays = %d", m.safetyDays)
	}
	if out := m.View(); !strings.Contains(out, "alpha") {
		t.Errorf("view missing table content:\n%s", out)
	}
}

func TestUpdate_TabCyclesThroughSafety(t *testing.T) {
	m := NewModel()
	m.mode = ModeReport
	m.reportLoaded = true
	m2, _ := m.Update(tea.KeyMsg{Type: tea.KeyTab})
	m = m2.(Model)
	if m.mode != ModeSafety {
		t.Fatalf("tab from report = %v, want ModeSafety", m.mode)
	}
	m2, _ = m.Update(tea.KeyMsg{Type: tea.KeyTab})
	m = m2.(Model)
	if m.mode != ModeMinimal {
		t.Fatalf("tab from safety = %v, want ModeMinimal (wraparound)", m.mode)
	}
}

func TestUpdate_SafetyWindowCycling(t *testing.T) {
	m := NewModel()
	m.mode = ModeSafety
	m.safetyLoaded = true
	m.SetSafetyFunc(func(days int) SafetyMsg { return SafetyMsg{Days: days} })
	m2, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{']'}})
	m = m2.(Model)
	if m.safetyDays != 180 || cmd == nil {
		t.Errorf("] should widen window to 180, got %d", m.safetyDays)
	}
	// Report's window must be untouched.
	if m.reportDays != 90 {
		t.Errorf("reportDays changed to %d", m.reportDays)
	}
}
