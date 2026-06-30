package insights

import (
	"context"
	"errors"
	"testing"
)

func TestJudgeSession_Canned(t *testing.T) {
	reply := `{"friction":7,"prompt_specificity":3,"corrections":[{"quote":"no, wrong file","issue":"misread target"}],"loops":["edit-test-fail x4"],"root_cause":"vague first prompt","advice":"state the target file up front"}`
	j := fakeJudge{reply: reply, cost: 0.1}
	got := JudgeSession(context.Background(), j, Digest{ID: "s1"})
	if !got.Available || got.Friction != 7 || got.PromptSpecificity != 3 {
		t.Fatalf("judgment: %+v", got)
	}
	if len(got.Corrections) != 1 || got.Corrections[0].Quote != "no, wrong file" {
		t.Errorf("corrections: %+v", got.Corrections)
	}
	if got.CostUSD != 0.1 || got.SessionID != "s1" {
		t.Errorf("meta: %+v", got)
	}
}

func TestJudgeSession_ProseWrapped(t *testing.T) {
	j := fakeJudge{reply: "Sure! Here:\n```json\n{\"friction\":2,\"advice\":\"ok\"}\n```"}
	got := JudgeSession(context.Background(), j, Digest{ID: "s1"})
	if !got.Available || got.Friction != 2 || got.Advice != "ok" {
		t.Errorf("expected parse from fenced JSON: %+v", got)
	}
}

func TestJudgeSession_Error(t *testing.T) {
	j := fakeJudge{err: errors.New("timeout")}
	got := JudgeSession(context.Background(), j, Digest{ID: "s1"})
	if got.Available || got.Err == "" {
		t.Errorf("expected unavailable on error: %+v", got)
	}
}

func TestMineProject_Canned(t *testing.T) {
	reply := `{"candidates":[{"suggestion":"always run make test before committing","evidence":"asked in 4 sessions"}]}`
	j := fakeJudge{reply: reply, cost: 0.1}
	digs := []Digest{{Prompts: []string{"run make test", "remember to run make test"}}}
	got := MineProject(context.Background(), j, "p1", digs)
	if !got.Available || len(got.Candidates) != 1 {
		t.Fatalf("mined: %+v", got)
	}
	if got.Candidates[0].Suggestion == "" {
		t.Errorf("empty suggestion: %+v", got.Candidates)
	}
}

func TestMineProject_NoPrompts(t *testing.T) {
	j := fakeJudge{err: errors.New("should not be called")}
	got := MineProject(context.Background(), j, "p1", []Digest{{}})
	if !got.Available || len(got.Candidates) != 0 {
		t.Errorf("empty project should be available with no candidates: %+v", got)
	}
}
