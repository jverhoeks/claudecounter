package insights

import (
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func TestDefaultThresholds(t *testing.T) {
	th := DefaultThresholds()
	if th.RepeatToolN != 3 || th.LoopMin != 3 || th.ReadDupN != 2 {
		t.Errorf("counts: %+v", th)
	}
	if th.CtxHighPct != 80 {
		t.Errorf("CtxHighPct = %v, want 80", th.CtxHighPct)
	}
	if th.HighCtxTokens != 50_000 || th.TinyOutput != 100 {
		t.Errorf("token thresholds: %+v", th)
	}
}

func TestCategoryConsts(t *testing.T) {
	got := []Category{CatWaste, CatAbuse, CatSkill, CatContext, CatLoop}
	want := []string{"waste", "abuse", "skill", "context", "loop"}
	for i := range got {
		if string(got[i]) != want[i] {
			t.Errorf("cat[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestAnalyzeSession(t *testing.T) {
	s := &session.Session{
		ID: "s1", Cwd: "/tmp/proj",
		Prompts: 2,
		ToolCalls: []session.ToolCall{
			{Name: "Bash", Target: "go test", IsErr: true},
			{Name: "Bash", Target: "go test"},
			{Name: "Bash", Target: "go test"},
		},
		Turns: []session.Turn{
			{Model: "m", Usage: pricing.Usage{InputTokens: 100, OutputTokens: 50}},
			{Model: "m", Usage: pricing.Usage{InputTokens: 100, OutputTokens: 50}},
		},
		Tokens:      pricing.Usage{InputTokens: 200, OutputTokens: 100},
		PeakContext: 180_000, // 90% of 200k default
	}
	r := AnalyzeSession(s, priceTable(), DefaultThresholds())
	if r.ID != "s1" || r.Model != "m" || r.ToolCalls != 3 || r.Prompts != 2 {
		t.Errorf("scalars wrong: %+v", r)
	}
	if r.CtxPct < 89 || r.CtxPct > 91 {
		t.Errorf("CtxPct = %v, want ~90", r.CtxPct)
	}
	cats := map[Category]bool{}
	for _, f := range r.Findings {
		cats[f.Category] = true
	}
	for _, want := range []Category{CatAbuse, CatWaste, CatContext} {
		if !cats[want] {
			t.Errorf("missing %q finding in %+v", want, r.Findings)
		}
	}
	if r.Score <= 0 {
		t.Errorf("Score = %v, want > 0", r.Score)
	}
}
