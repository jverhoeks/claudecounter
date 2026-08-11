package ui

import (
	"errors"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// TestModelGaugesMsg_ErrorSurfacesAsFooterWarning is the model-level
// counterpart to the "malformed limits.toml must never take the live
// TUI down" constraint. It exercises the actual path the live TUI's
// gauge-refresh goroutine drives: a GaugesMsg carrying Err must not
// panic, must not blank whatever gauge block was last shown, and must
// surface visibly (a footer warning) rather than silently vanish —
// while a repeated failure renders exactly one warning line, not one
// per refresh attempt, and a later success clears it.
func TestModelGaugesMsg_ErrorSurfacesAsFooterWarning(t *testing.T) {
	m := NewModel()

	// A successful refresh renders in the body.
	next, _ := m.Update(GaugesMsg{Gauges: "GOOD-GAUGES\n"})
	m = next.(Model)
	if !strings.Contains(m.View(), "GOOD-GAUGES") {
		t.Fatalf("expected successful gauges in view:\n%s", m.View())
	}

	// A later failure must not blank the last-good gauges, and must
	// surface as a footer warning naming the error.
	next, _ = m.Update(GaugesMsg{Err: errors.New("boom")})
	m = next.(Model)
	view := m.View()
	if !strings.Contains(view, "GOOD-GAUGES") {
		t.Fatalf("malformed config must not blank the last-good gauge block:\n%s", view)
	}
	if !strings.Contains(view, "limits config") || !strings.Contains(view, "boom") {
		t.Fatalf("expected a footer warning naming the error:\n%s", view)
	}

	// Idempotency: a repeated identical failure must not accumulate a
	// second warning line — this is what stops an unattended session
	// with a persistently bad config from growing an unbounded footer.
	next, _ = m.Update(GaugesMsg{Err: errors.New("boom")})
	m = next.(Model)
	if n := strings.Count(m.View(), "limits config"); n != 1 {
		t.Fatalf("expected exactly one warning line after a repeated failure, got %d in:\n%s", n, m.View())
	}

	// Recovery: a subsequent success clears the warning and swaps in
	// the new gauges.
	next, _ = m.Update(GaugesMsg{Gauges: "NEW-GAUGES\n"})
	m = next.(Model)
	view = m.View()
	if strings.Contains(view, "limits config") {
		t.Fatalf("expected the warning to clear after a successful refresh:\n%s", view)
	}
	if !strings.Contains(view, "NEW-GAUGES") || strings.Contains(view, "GOOD-GAUGES") {
		t.Fatalf("expected gauges to update to the latest successful render:\n%s", view)
	}
}

// TestUpdate_VCyclesGroupMode locks in that "v" ("view by") cycles the
// grouping shown in the cost views. "b" was the original choice but
// turned out to already be bound as the report/safety scroll-back key
// (model.go's up/down/pgup/pgdown/j/k/space/b/f case); "v" is a plain,
// dedicated case with no mode guard to keep in sync with that one.
func TestUpdate_VCyclesGroupMode(t *testing.T) {
	m := NewModel()
	m.mode = ModeSplit
	if m.groupMode != agg.GroupModel {
		t.Fatalf("expected default groupMode=GroupModel, got %v", m.groupMode)
	}
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("v")})
	m = next.(Model)
	if m.groupMode != agg.GroupVendor {
		t.Errorf("pressing v in ModeSplit did not cycle model -> vendor, got %v", m.groupMode)
	}
}

// TestUpdate_BDoesNotCycleGroupMode is the executable record of the
// collision discovered while implementing this feature: "b" is bound
// (model.go:245) as a report/safety viewport page-back key and must
// never touch groupMode, in any mode — that's why grouping got its own
// "v" case instead of piggybacking on "b".
func TestUpdate_BDoesNotCycleGroupMode(t *testing.T) {
	m := NewModel()
	start := m.groupMode
	next, _ := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("b")})
	m = next.(Model)
	if m.groupMode != start {
		t.Errorf("pressing b must not cycle groupMode, got %v -> %v", start, m.groupMode)
	}
}
