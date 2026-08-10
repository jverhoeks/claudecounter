package ui

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

func series() map[string]agg.ModelDay {
	return map[string]agg.ModelDay{
		"claude-opus-4-7":   {USD: 12},
		"claude-sonnet-4-6": {USD: 5},
		"grok-4.5-build":    {USD: 3},
	}
}

func TestRenderSeriesSortsByUSDDescending(t *testing.T) {
	out := renderSeries(series(), agg.GroupModel)
	iOpus := strings.Index(out, "claude-opus-4-7")
	iSonnet := strings.Index(out, "claude-sonnet-4-6")
	iGrok := strings.Index(out, "grok-4.5-build")
	if !(iOpus < iSonnet && iSonnet < iGrok) {
		t.Fatalf("rows must be ordered by USD desc:\n%s", out)
	}
}

func TestRenderSeriesShowsShareOfTotal(t *testing.T) {
	out := renderSeries(series(), agg.GroupModel)
	// 12 of 20 is 60%.
	if !strings.Contains(out, "60%") {
		t.Fatalf("expected a 60%% share for opus:\n%s", out)
	}
}

// A source label contains a slash and must survive rendering intact —
// truncating it to the vendor would merge two subscriptions visually.
func TestRenderSeriesKeepsFullSourceLabel(t *testing.T) {
	out := renderSeries(map[string]agg.ModelDay{
		"claude/work":     {USD: 10},
		"claude/personal": {USD: 4},
	}, agg.GroupSource)
	for _, want := range []string{"claude/work", "claude/personal"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q:\n%s", want, out)
		}
	}
}

func TestRenderSeriesEmptyIsEmpty(t *testing.T) {
	if got := renderSeries(map[string]agg.ModelDay{}, agg.GroupModel); got != "" {
		t.Fatalf("no series must render nothing, got %q", got)
	}
}

func TestRenderModeBarMarksActiveMode(t *testing.T) {
	out := renderModeBar(agg.GroupVendor)
	if !strings.Contains(out, "[vendor]") {
		t.Fatalf("active mode must be bracketed:\n%s", out)
	}
	for _, other := range []string{"model", "source", "total"} {
		if !strings.Contains(out, other) {
			t.Errorf("mode bar must list %q:\n%s", other, out)
		}
	}
}
