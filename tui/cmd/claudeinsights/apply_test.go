package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

// stubJudge is a local Judge double (the insights fakeJudge is unexported).
type stubJudge struct {
	reply string
	err   error
}

func (s stubJudge) Ask(ctx context.Context, prompt string) (string, float64, error) {
	return s.reply, 0.1, s.err
}

func TestWriteActions(t *testing.T) {
	a := insights.ActionList{Available: true, Items: []insights.ActionItem{
		{Action: "verify build before done", Why: "compile errors reached you", Sessions: 3},
	}}
	var b strings.Builder
	writeActions(&b, a)
	out := b.String()
	if !strings.Contains(out, "verify build before done") || !strings.Contains(out, "seen in 3") {
		t.Errorf("actions render: %s", out)
	}
}

func corpusWithProject(cwd string) insights.CorpusReport {
	return insights.CorpusReport{Sessions: []insights.SessionReport{
		{ID: "s1", Project: "proj", Cwd: cwd},
	}}
}

func TestApplyClaudeMd_DryRunWritesNothing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CLAUDE.md")
	if err := os.WriteFile(path, []byte("# CLAUDE.md\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	c := corpusWithProject(dir)
	mined := []insights.ProjectMined{{Project: "proj", Available: true,
		Candidates: []insights.MemoryCandidate{{Suggestion: "run make test"}}}}
	j := stubJudge{reply: "# CLAUDE.md\n\n## Insights (auto-suggested)\n- run make test\n"}

	res := applyClaudeMd(c, mined, j, false) // dry-run
	if len(res) != 1 || res[0].Wrote || res[0].Diff == "" {
		t.Fatalf("dry-run result: %+v", res)
	}
	got, _ := os.ReadFile(path)
	if string(got) != "# CLAUDE.md\n" {
		t.Errorf("dry-run modified the file: %q", got)
	}
}

func TestApplyClaudeMd_WriteApplies(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "CLAUDE.md")
	_ = os.WriteFile(path, []byte("# CLAUDE.md\n"), 0o644)
	c := corpusWithProject(dir)
	merged := "# CLAUDE.md\n\n## Insights (auto-suggested)\n- run make test\n"
	mined := []insights.ProjectMined{{Project: "proj", Available: true,
		Candidates: []insights.MemoryCandidate{{Suggestion: "run make test"}}}}

	res := applyClaudeMd(c, mined, stubJudge{reply: merged}, true) // write
	if len(res) != 1 || !res[0].Wrote {
		t.Fatalf("write result: %+v", res)
	}
	got, _ := os.ReadFile(path)
	if string(got) != merged {
		t.Errorf("file not written as merged: %q", got)
	}
}

func TestApplyClaudeMd_MissingDirSkipped(t *testing.T) {
	c := corpusWithProject("/no/such/dir/anywhere")
	mined := []insights.ProjectMined{{Project: "proj", Available: true,
		Candidates: []insights.MemoryCandidate{{Suggestion: "x"}}}}
	res := applyClaudeMd(c, mined, stubJudge{reply: "merged"}, true)
	if len(res) != 1 || !res[0].Skipped {
		t.Fatalf("expected skip: %+v", res)
	}
}

func TestApplyClaudeMd_NoCandidatesSkipped(t *testing.T) {
	dir := t.TempDir()
	c := corpusWithProject(dir)
	mined := []insights.ProjectMined{{Project: "proj", Available: true}}
	res := applyClaudeMd(c, mined, stubJudge{}, false)
	if len(res) != 1 || !res[0].Skipped {
		t.Fatalf("expected skip for no candidates: %+v", res)
	}
}
