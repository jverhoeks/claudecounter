package main

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

func TestWriteLLM(t *testing.T) {
	judgments := []insights.Judgment{
		{SessionID: "abc12345", Available: true, Friction: 7, PromptSpecificity: 3,
			RootCause:   "vague first prompt",
			Corrections: []insights.Correction{{Quote: "no, wrong file", Issue: "misread target"}},
			Loops:       []string{"edit-test-fail x4"},
			Advice:      "name the target file up front"},
		{SessionID: "def67890", Available: false, Err: "timeout"},
	}
	mined := []insights.ProjectMined{
		{Project: "-tmp-proj", Available: true,
			Candidates: []insights.MemoryCandidate{{Suggestion: "run make test", Evidence: "asked 4×"}}},
	}
	var b strings.Builder
	writeLLM(&b, judgments, mined, 0.42)
	out := b.String()
	for _, want := range []string{"friction 7/10", "vague first prompt", "wrong file",
		"edit-test-fail", "name the target", "unavailable", "run make test", "$0.42"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
}

func TestWriteLLM_NoCandidates(t *testing.T) {
	var b strings.Builder
	writeLLM(&b, nil, nil, 0)
	if !strings.Contains(b.String(), "(none found)") {
		t.Errorf("expected none-found note: %s", b.String())
	}
}
