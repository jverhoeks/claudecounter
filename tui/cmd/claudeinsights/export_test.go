package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

func sampleCorpus() insights.CorpusReport {
	return insights.CorpusReport{
		Sessions: []insights.SessionReport{
			{ID: "s1", Project: "p", USD: 2, WasteUSD: 1,
				Findings: []insights.Finding{
					{Category: insights.CatWaste, Detail: "failed", Count: 2, USD: 1},
				}},
		},
		TotalUSD: 2, TotalWasteUSD: 1,
	}
}

func TestWriteJSON(t *testing.T) {
	var b strings.Builder
	if err := writeJSON(&b, sampleCorpus()); err != nil {
		t.Fatal(err)
	}
	var back insights.CorpusReport
	if err := json.Unmarshal([]byte(b.String()), &back); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if back.TotalUSD != 2 || len(back.Sessions) != 1 {
		t.Errorf("roundtrip: %+v", back)
	}
}

func TestWriteDigest(t *testing.T) {
	d := insights.Digest{ID: "s1", Project: "p", Model: "m", Prompts: []string{"hi"}}
	var b strings.Builder
	if err := writeDigest(&b, d); err != nil {
		t.Fatal(err)
	}
	var back insights.Digest
	if err := json.Unmarshal([]byte(b.String()), &back); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if back.ID != "s1" || len(back.Prompts) != 1 {
		t.Errorf("roundtrip: %+v", back)
	}
}

func TestWriteCSV(t *testing.T) {
	var b strings.Builder
	if err := writeCSV(&b, sampleCorpus()); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	if !strings.Contains(out, "session,project,usd") {
		t.Errorf("missing header: %s", out)
	}
	if !strings.Contains(out, "s1,p,") || !strings.Contains(out, "waste,failed") {
		t.Errorf("missing row: %s", out)
	}
}
