package main

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

func TestWriteCorpus(t *testing.T) {
	c := insights.CorpusReport{
		Sessions: []insights.SessionReport{
			{ID: "abc123def", Project: "-tmp-proj", USD: 2, WasteUSD: 1, Score: 4,
				Findings: []insights.Finding{{Category: insights.CatWaste, Detail: "x"}}},
		},
		Projects:      []insights.ProjectAgg{{Project: "-tmp-proj", Sessions: 1, USD: 2, WasteUSD: 1}},
		TotalUSD:      2,
		TotalWasteUSD: 1,
	}
	var b strings.Builder
	writeCorpus(&b, c, 10)
	out := b.String()
	if !strings.Contains(out, "abc123") || !strings.Contains(out, "proj") {
		t.Errorf("missing session/project: %s", out)
	}
}

func TestWriteSession(t *testing.T) {
	r := insights.SessionReport{
		ID: "s1", Cwd: "/tmp/proj", Prompts: 2, ToolCalls: 5, CtxPct: 90,
		Findings: []insights.Finding{
			{Category: insights.CatLoop, Detail: "main stream: cycle [Edit] repeated 3×", Count: 3},
		},
	}
	var b strings.Builder
	writeSession(&b, r)
	out := b.String()
	if !strings.Contains(out, "s1") || !strings.Contains(out, "cycle") {
		t.Errorf("missing content: %s", out)
	}
}
