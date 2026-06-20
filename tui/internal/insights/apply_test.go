package insights

import (
	"context"
	"errors"
	"strings"
	"testing"
)

func TestSynthesizeActions_Canned(t *testing.T) {
	reply := `{"actions":[{"action":"verify build before claiming done","why":"compile errors reached the user","sessions":3}]}`
	j := fakeJudge{reply: reply, cost: 0.1}
	js := []Judgment{{SessionID: "s1", Available: true, Advice: "x"}}
	got := SynthesizeActions(context.Background(), j, js)
	if !got.Available || len(got.Items) != 1 {
		t.Fatalf("actions: %+v", got)
	}
	if got.Items[0].Sessions != 3 || got.Items[0].Action == "" || got.CostUSD != 0.1 {
		t.Errorf("item: %+v", got.Items[0])
	}
}

func TestSynthesizeActions_NoJudgments(t *testing.T) {
	j := fakeJudge{err: errors.New("should not be called")}
	got := SynthesizeActions(context.Background(), j, []Judgment{{Available: false}})
	if !got.Available || len(got.Items) != 0 {
		t.Errorf("expected available with no items: %+v", got)
	}
}

func TestSynthesizeActions_Error(t *testing.T) {
	j := fakeJudge{err: errors.New("timeout")}
	got := SynthesizeActions(context.Background(), j, []Judgment{{Available: true}})
	if got.Available || got.Err == "" {
		t.Errorf("expected unavailable: %+v", got)
	}
}

func TestMergeClaudeMd_NoCandidates(t *testing.T) {
	j := fakeJudge{err: errors.New("should not be called")}
	out, cost, err := MergeClaudeMd(context.Background(), j, "existing content", nil)
	if err != nil || out != "existing content" || cost != 0 {
		t.Errorf("no-candidate merge: %q %v %v", out, cost, err)
	}
}

func TestMergeClaudeMd_StripsFence(t *testing.T) {
	merged := "```markdown\n# CLAUDE.md\n\n## Insights (auto-suggested)\n- run make test\n```"
	j := fakeJudge{reply: merged, cost: 0.1}
	out, _, err := MergeClaudeMd(context.Background(), j, "# CLAUDE.md\n",
		[]MemoryCandidate{{Suggestion: "run make test"}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "```") {
		t.Errorf("fence not stripped: %q", out)
	}
	if !strings.Contains(out, "run make test") {
		t.Errorf("missing merged content: %q", out)
	}
}

func TestMergeClaudeMd_Error(t *testing.T) {
	j := fakeJudge{err: errors.New("boom")}
	if _, _, err := MergeClaudeMd(context.Background(), j, "x", []MemoryCandidate{{Suggestion: "y"}}); err == nil {
		t.Error("expected error propagated")
	}
}

func TestUnifiedDiff(t *testing.T) {
	old := "line1\nline2\n"
	neu := "line1\nline2\nadded3\nadded4\n"
	d := unifiedDiff(old, neu, "/p/CLAUDE.md")
	if !strings.Contains(d, "/p/CLAUDE.md") {
		t.Errorf("missing path: %s", d)
	}
	if !strings.Contains(d, "+ added3") || !strings.Contains(d, "+ added4") {
		t.Errorf("missing additions: %s", d)
	}

	same := unifiedDiff("a\nb\n", "a\nb\n", "/p")
	if strings.Contains(same, "\n+ ") || strings.Contains(same, "\n- ") {
		t.Errorf("identical inputs should show no +/- lines: %s", same)
	}
}
