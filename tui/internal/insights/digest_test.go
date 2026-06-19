package insights

import (
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func TestBuildDigest_Truncates(t *testing.T) {
	s := &session.Session{
		ID:  "s1",
		Cwd: "/tmp/proj",
		UserPrompts: []session.Prompt{
			{Text: "first prompt that is quite long indeed"},
			{Text: "second"},
			{Text: "third"},
		},
		ToolCalls: []session.ToolCall{
			{Name: "Read", Target: "/a"}, {Name: "Edit", Target: "/b"},
			{Name: "Bash", Target: "go test"}, {Name: "Read", Target: "/c"},
			{Name: "Read", Target: "/d"},
		},
	}
	r := SessionReport{ID: "s1", Project: "p", Model: "m"}
	d := BuildDigest(s, r, 2, 3, 10)

	if len(d.Prompts) != 2 || d.DroppedPrompt != 1 {
		t.Errorf("prompts: %+v dropped=%d", d.Prompts, d.DroppedPrompt)
	}
	for _, p := range d.Prompts {
		if len([]rune(p)) > 10 {
			t.Errorf("prompt not truncated to 10 runes: %q", p)
		}
	}
	if len(d.Tools) != 3 || d.DroppedTool != 2 {
		t.Errorf("tools: %+v dropped=%d", d.Tools, d.DroppedTool)
	}
	if d.Project != "p" || d.Model != "m" {
		t.Errorf("metrics not threaded: %+v", d)
	}
}

func TestBuildDigest_NoTruncation(t *testing.T) {
	s := &session.Session{ID: "s1", UserPrompts: []session.Prompt{{Text: "hi"}}}
	d := BuildDigest(s, SessionReport{ID: "s1"}, 10, 10, 100)
	if len(d.Prompts) != 1 || d.DroppedPrompt != 0 || d.DroppedTool != 0 {
		t.Errorf("unexpected truncation: %+v", d)
	}
}
