package insights

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func TestSprawlFindings_Prompts(t *testing.T) {
	s := &session.Session{Prompts: 70}
	if fs := sprawlFindings(s, DefaultThresholds()); len(fs) != 1 || fs[0].Category != CatSprawl {
		t.Fatalf("want sprawl, got %+v", fs)
	}
}

func TestSprawlFindings_Duration(t *testing.T) {
	start := time.Now()
	s := &session.Session{Prompts: 3, Start: start, End: start.Add(5 * time.Hour)}
	if fs := sprawlFindings(s, DefaultThresholds()); len(fs) != 1 {
		t.Fatalf("want sprawl from duration, got %+v", fs)
	}
}

func TestSprawlFindings_None(t *testing.T) {
	start := time.Now()
	s := &session.Session{Prompts: 5, Start: start, End: start.Add(30 * time.Minute)}
	if fs := sprawlFindings(s, DefaultThresholds()); len(fs) != 0 {
		t.Errorf("want none, got %+v", fs)
	}
}

func TestRoutingFindings_LightOpus(t *testing.T) {
	s := &session.Session{
		Tokens:    pricing.Usage{InputTokens: 1000, OutputTokens: 500},
		ToolCalls: []session.ToolCall{{Name: "Read"}},
	}
	if fs := routingFindings(s, "claude-opus-4-8", DefaultThresholds()); len(fs) != 1 || fs[0].Category != CatRouting {
		t.Fatalf("want routing, got %+v", fs)
	}
}

func TestRoutingFindings_HeavyOpus(t *testing.T) {
	s := &session.Session{Tokens: pricing.Usage{InputTokens: 100_000, OutputTokens: 50_000}}
	if fs := routingFindings(s, "claude-opus-4-8", DefaultThresholds()); len(fs) != 0 {
		t.Errorf("heavy opus should not flag routing, got %+v", fs)
	}
}

func TestRoutingFindings_NotOpus(t *testing.T) {
	s := &session.Session{Tokens: pricing.Usage{InputTokens: 1000}}
	if fs := routingFindings(s, "claude-haiku-4-5", DefaultThresholds()); len(fs) != 0 {
		t.Errorf("non-opus should not flag routing, got %+v", fs)
	}
}
