package insights

import (
	"context"
	"errors"
	"testing"
)

type fakeScorer struct {
	scores []LayaScore
	err    error
}

func (f fakeScorer) Score(ctx context.Context, ds []Digest) ([]LayaScore, error) {
	return f.scores, f.err
}

const cannedJudgment = `{"friction":1,"prompt_specificity":1,"corrections":[],"loops":[],"root_cause":"vague ask","advice":"name the file"}`

func TestJudgeHybrid_EscalatesOnlyRoughSessions(t *testing.T) {
	sc := fakeScorer{scores: []LayaScore{
		{Friction: 2, PromptSpecificity: 8, PCorrection: 0.1, PLoop: 0.1}, // smooth
		{Friction: 7, PromptSpecificity: 3, PCorrection: 0.2, PLoop: 0.1}, // high friction
		{Friction: 2, PromptSpecificity: 6, PCorrection: 0.9, PLoop: 0.1}, // corrected
	}}
	js, err := JudgeHybrid(context.Background(), sc, fakeJudge{reply: cannedJudgment, cost: 0.2},
		[]Digest{{ID: "a"}, {ID: "b"}, {ID: "c"}})
	if err != nil {
		t.Fatal(err)
	}
	if js[0].Advice != "" || js[0].CostUSD != 0 || !js[0].Available {
		t.Errorf("smooth session should be Laya-only: %+v", js[0])
	}
	for _, j := range js[1:] {
		if j.Advice != "name the file" || j.CostUSD != 0.2 {
			t.Errorf("rough session %s should get the text judgment: %+v", j.SessionID, j)
		}
	}
	// Scores are Laya's even when the text judge ran, so sessions compare.
	if js[1].Friction != 7 || js[1].PromptSpecificity != 3 || js[1].Laya == nil {
		t.Errorf("scores should come from Laya: %+v", js[1])
	}
}

func TestJudgeHybrid_FallsBackWhenLayaFails(t *testing.T) {
	js, err := JudgeHybrid(context.Background(), fakeScorer{err: errors.New("no uv")},
		fakeJudge{reply: cannedJudgment}, []Digest{{ID: "a"}})
	if err == nil {
		t.Error("expected the Laya error to be returned")
	}
	if js[0].Advice != "name the file" || js[0].Laya != nil {
		t.Errorf("expected a plain text judgment: %+v", js[0])
	}
}

func TestParseLaya(t *testing.T) {
	out := []byte(`[{"friction":{"score":2.8},"prompt_specificity":{"score":0.4},"correction":{"noul":0.73},"loop":{"noul":0.05}}]`)
	s, err := parseLaya(out, 1)
	if err != nil {
		t.Fatal(err)
	}
	if s[0].Friction != 7 || s[0].PromptSpecificity != 1 || s[0].PCorrection != 0.73 {
		t.Errorf("mapped scores: %+v", s[0])
	}
	if _, err := parseLaya(out, 2); err == nil {
		t.Error("expected a count-mismatch error")
	}
}
