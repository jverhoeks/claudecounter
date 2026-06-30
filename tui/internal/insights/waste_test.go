package insights

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func priceTable() pricing.Table {
	return pricing.Table{Models: map[string]pricing.ModelPrice{
		"m": {InputPerMTok: 1, OutputPerMTok: 1, CacheCreationPerMTok: 1, CacheReadPerMTok: 1},
	}}
}

func TestWasteFindings(t *testing.T) {
	now := time.Now()
	s := &session.Session{
		ToolCalls: []session.ToolCall{
			{Name: "Bash", IsErr: true},
			{Name: "Read", Target: "/a.go"},
			{Name: "Read", Target: "/a.go"},
			{Name: "Read", Target: "/a.go"},
		},
		Turns: []session.Turn{
			{Time: now, Model: "m", Usage: pricing.Usage{InputTokens: 60_000, OutputTokens: 10}},
		},
	}
	fs := wasteFindings(s, priceTable(), DefaultThresholds())
	if len(fs) != 3 {
		t.Fatalf("want 3 waste findings, got %d: %+v", len(fs), fs)
	}
	for _, f := range fs {
		if f.Category != CatWaste {
			t.Errorf("category = %q", f.Category)
		}
	}
}

func TestWasteFindings_None(t *testing.T) {
	s := &session.Session{
		ToolCalls: []session.ToolCall{{Name: "Read", Target: "/a.go"}},
	}
	if fs := wasteFindings(s, priceTable(), DefaultThresholds()); len(fs) != 0 {
		t.Errorf("want 0, got %+v", fs)
	}
}
