package insights

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func tc(name, target string, sub bool) session.ToolCall {
	return session.ToolCall{Name: name, Target: target, Sub: sub}
}

func TestLoopFindings_PingPong(t *testing.T) {
	// Edit/Bash repeated 3× on the main stream.
	s := &session.Session{ToolCalls: []session.ToolCall{
		tc("Edit", "/m.go", false), tc("Bash", "go test", false),
		tc("Edit", "/m.go", false), tc("Bash", "go test", false),
		tc("Edit", "/m.go", false), tc("Bash", "go test", false),
	}}
	fs := loopFindings(s, DefaultThresholds())
	if len(fs) != 1 || fs[0].Category != CatLoop {
		t.Fatalf("want one loop finding, got %+v", fs)
	}
	if fs[0].Count != 3 {
		t.Errorf("repeat Count = %d, want 3", fs[0].Count)
	}
	if !strings.Contains(fs[0].Detail, "Edit") {
		t.Errorf("detail missing cycle: %q", fs[0].Detail)
	}
}

func TestLoopFindings_StreamsNotMerged(t *testing.T) {
	// Each stream alone IS 3 repeats of [Read /a] — a real per-stream loop.
	// Assert we get exactly two (one per stream), proving we split streams.
	s := &session.Session{ToolCalls: []session.ToolCall{
		tc("Read", "/a", false), tc("Read", "/a", true),
		tc("Read", "/a", false), tc("Read", "/a", true),
		tc("Read", "/a", false), tc("Read", "/a", true),
	}}
	fs := loopFindings(s, DefaultThresholds())
	if len(fs) != 2 {
		t.Fatalf("want 2 per-stream loops, got %d: %+v", len(fs), fs)
	}
}

func TestLoopFindings_None(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		tc("Read", "/a", false), tc("Edit", "/b", false), tc("Bash", "x", false),
	}}
	if fs := loopFindings(s, DefaultThresholds()); len(fs) != 0 {
		t.Errorf("want 0, got %+v", fs)
	}
}
