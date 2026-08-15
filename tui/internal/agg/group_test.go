package agg

import "testing"

func seed() map[SeriesKey]ModelDay {
	return map[SeriesKey]ModelDay{
		{Source: "claude/work", Vendor: "claude", Model: "claude-opus-4-7"}:   {USD: 10, Tokens: TokenCounts{In: 100}},
		{Source: "claude/work", Vendor: "claude", Model: "claude-sonnet-4-6"}: {USD: 5, Tokens: TokenCounts{In: 50}},
		{Source: "claude/home", Vendor: "claude", Model: "claude-opus-4-7"}:   {USD: 2, Tokens: TokenCounts{In: 20}},
		{Source: "grok/home", Vendor: "grok", Model: "grok-4.5-build"}:        {USD: 3, Tokens: TokenCounts{In: 30}},
	}
}

func TestGroupModelMergesAcrossSources(t *testing.T) {
	got := Group(seed(), GroupModel)
	if len(got) != 3 {
		t.Fatalf("want 3 models, got %d: %+v", len(got), got)
	}
	// opus appears under two sources and must merge to 12.
	if got["claude-opus-4-7"].USD != 12 {
		t.Fatalf("opus USD = %v, want 12", got["claude-opus-4-7"].USD)
	}
	if got["claude-opus-4-7"].Tokens.In != 120 {
		t.Fatalf("tokens must merge too, got %+v", got["claude-opus-4-7"].Tokens)
	}
}

func TestGroupVendorCollapsesModels(t *testing.T) {
	got := Group(seed(), GroupVendor)
	if len(got) != 2 {
		t.Fatalf("want 2 vendors, got %+v", got)
	}
	if got["claude"].USD != 17 {
		t.Fatalf("claude USD = %v, want 17 (10+5+2)", got["claude"].USD)
	}
	if got["grok"].USD != 3 {
		t.Fatalf("grok USD = %v, want 3", got["grok"].USD)
	}
}

func TestGroupSourceKeepsSubscriptionsApart(t *testing.T) {
	got := Group(seed(), GroupSource)
	if len(got) != 3 {
		t.Fatalf("want 3 sources, got %+v", got)
	}
	if got["claude/work"].USD != 15 {
		t.Fatalf("claude/work USD = %v, want 15 (10+5)", got["claude/work"].USD)
	}
	if got["claude/home"].USD != 2 {
		t.Fatalf("claude/home USD = %v, want 2", got["claude/home"].USD)
	}
}

func TestGroupTotalIsOneSeries(t *testing.T) {
	got := Group(seed(), GroupTotal)
	if len(got) != 1 {
		t.Fatalf("want 1 series, got %+v", got)
	}
	if got["total"].USD != 20 {
		t.Fatalf("total USD = %v, want 20", got["total"].USD)
	}
}

// Every mode must sum to the same grand total — a grouping that loses or
// duplicates spend is the whole risk here.
func TestEveryModeSumsToTheSameTotal(t *testing.T) {
	in := seed()
	var want float64
	for _, v := range in {
		want += v.USD
	}
	for _, m := range []Mode{GroupModel, GroupVendor, GroupSource, GroupTotal} {
		var got float64
		for _, v := range Group(in, m) {
			got += v.USD
		}
		if got != want {
			t.Errorf("mode %s sums to %v, want %v", m, got, want)
		}
	}
}

func TestModeNextCycles(t *testing.T) {
	m := GroupModel
	for _, want := range []Mode{GroupVendor, GroupSource, GroupTotal, GroupModel} {
		m = m.Next()
		if m != want {
			t.Fatalf("Next() = %v, want %v", m, want)
		}
	}
}

// A row that spans vendors takes the worst of their coverage. Averaging
// would let a large complete Claude figure hide a small partial Grok one
// inside the same row.
func TestGroupCoverage_RowTakesTheWorstContributingVendor(t *testing.T) {
	in := map[SeriesKey]ModelDay{
		{Source: "claude/claude", Vendor: "claude", Model: "m"}: {USD: 100},
		{Source: "grok/grok", Vendor: "grok", Model: "m"}:       {USD: 1},
	}
	cov := map[string]Coverage{"grok": {Turns: 100, WithUsage: 20}}

	// GroupTotal merges everything into one row, which therefore spans
	// both vendors.
	got := GroupCoverage(in, cov, GroupTotal)
	if !got["total"].Partial() {
		t.Fatalf("total row coverage = %+v, want partial", got["total"])
	}
	// GroupVendor keeps them apart.
	byVendor := GroupCoverage(in, cov, GroupVendor)
	if byVendor["claude"].Partial() {
		t.Fatal("the claude row must not be marked partial")
	}
	if !byVendor["grok"].Partial() {
		t.Fatal("the grok row must be marked partial")
	}
	// Key sets match Group's exactly, or a row would render without its
	// marker.
	if len(Group(in, GroupVendor)) != len(byVendor) {
		t.Fatal("GroupCoverage and Group must share a key set")
	}
}

func TestModeStrings(t *testing.T) {
	for m, want := range map[Mode]string{
		GroupModel: "model", GroupVendor: "vendor",
		GroupSource: "source", GroupTotal: "total",
	} {
		if m.String() != want {
			t.Errorf("%d.String() = %q, want %q", m, m.String(), want)
		}
	}
}
