package ui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

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
	out := renderSeries(series(), agg.GroupModel, 0)
	iOpus := strings.Index(out, "claude-opus-4-7")
	iSonnet := strings.Index(out, "claude-sonnet-4-6")
	iGrok := strings.Index(out, "grok-4.5-build")
	if !(iOpus < iSonnet && iSonnet < iGrok) {
		t.Fatalf("rows must be ordered by USD desc:\n%s", out)
	}
}

func TestRenderSeriesShowsShareOfTotal(t *testing.T) {
	out := renderSeries(series(), agg.GroupModel, 0)
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
	}, agg.GroupSource, 0)
	for _, want := range []string{"claude/work", "claude/personal"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q:\n%s", want, out)
		}
	}
}

func TestRenderSeriesEmptyIsEmpty(t *testing.T) {
	if got := renderSeries(map[string]agg.ModelDay{}, agg.GroupModel, 0); got != "" {
		t.Fatalf("no series must render nothing, got %q", got)
	}
}

// TestRenderSeriesZeroBarWidthOmitsBar locks in that viewMinimal's call
// (barWidth 0) renders a plain table with no bar glyphs.
func TestRenderSeriesZeroBarWidthOmitsBar(t *testing.T) {
	out := renderSeries(series(), agg.GroupModel, 0)
	if strings.ContainsAny(out, "█░") {
		t.Fatalf("barWidth=0 must render no bar glyphs:\n%s", out)
	}
}

// TestRenderSeriesPositiveBarWidthDrawsBar locks in that viewSplit's
// call (barWidth>0) restores the colour-coded inline bar chart that
// view_split.go originally rendered per-model, now reused for whichever
// grouping is active.
func TestRenderSeriesPositiveBarWidthDrawsBar(t *testing.T) {
	out := renderSeries(series(), agg.GroupModel, 24)
	if !strings.ContainsAny(out, "█░") {
		t.Fatalf("barWidth=24 must render bar glyphs:\n%s", out)
	}
}

// TestModelBarStyleColorsVendorLabels locks in the plan-directed fix:
// modelBarStyle must give vendor-level labels ("claude", "codex", "grok" —
// what GroupVendor collapses to) a real colour, not the opus/sonnet/haiku
// default grey, while still matching model-specific names first so
// "claude-opus-4-7" keeps its opus colour rather than falling to the
// vendor-level "claude" case.
func TestModelBarStyleColorsVendorLabels(t *testing.T) {
	// lipgloss.Style isn't comparable (it embeds a func field), so
	// compare rendered output of the same probe string instead — which
	// requires forcing a colour profile, since lipgloss emits no ANSI
	// codes when stdout isn't a terminal (as in `go test`).
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })
	render := func(s lipgloss.Style) string { return s.Render("X") }

	grey := render(modelBarStyle("unknown-model"))
	for _, vendor := range []string{"claude", "codex", "grok"} {
		if render(modelBarStyle(vendor)) == grey {
			t.Errorf("vendor label %q must not fall back to the default grey", vendor)
		}
	}
	if render(modelBarStyle("claude-opus-4-7")) != render(modelBarStyle("claude-opus-4-8")) {
		t.Fatalf("both opus ids should share the opus colour")
	}
	if render(modelBarStyle("claude-opus-4-7")) == render(modelBarStyle("claude")) {
		t.Errorf("a specific model match must win over the vendor-level fallback")
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
