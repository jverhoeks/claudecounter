package insights

import (
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func TestAbuseFindings_RepeatedCall(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		{Name: "Bash", Target: "go test"},
		{Name: "Bash", Target: "go test"},
		{Name: "Bash", Target: "go test"},
	}}
	fs := abuseFindings(s, DefaultThresholds())
	if len(fs) != 1 || fs[0].Category != CatAbuse || fs[0].Count != 3 {
		t.Fatalf("want one abuse finding count=3, got %+v", fs)
	}
}

func TestAbuseFindings_BelowThreshold(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		{Name: "Bash", Target: "go test"},
		{Name: "Bash", Target: "go test"},
	}}
	if fs := abuseFindings(s, DefaultThresholds()); len(fs) != 0 {
		t.Errorf("want 0, got %+v", fs)
	}
}

func TestSkillFindings(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		{Name: "Skill", Target: "brainstorming"},
		{Name: "Skill", Target: "brainstorming"},
		{Name: "Skill", Target: "writing-plans"},
		{Name: "Skill", Target: "tdd"},
		{Name: "Skill", Target: "debugging"},
	}}
	fs := skillFindings(s)
	if len(fs) != 1 || fs[0].Category != CatSkill {
		t.Fatalf("want one skill finding, got %+v", fs)
	}
	if fs[0].Count != 4 { // 4 distinct skills
		t.Errorf("distinct skills Count = %d, want 4", fs[0].Count)
	}
}
