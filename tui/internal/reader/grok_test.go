package reader

import (
	"bufio"
	"math"
	"os"
	"testing"
)

const grokRoot = "/Users/me/.grok/sessions"
const grokPath = grokRoot + "/%2FUsers%2Fme%2Fsrc%2Fproj/01a0-sess/updates.jsonl"

func parseGrokFixture(t *testing.T) (events []Event, parseErrs int) {
	t.Helper()
	f, err := os.Open("testdata/grok_updates.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	p := grokParser{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		evs, err := p.Parse(sc.Bytes(), grokPath)
		if err != nil {
			parseErrs++
			continue
		}
		events = append(events, evs...)
	}
	return events, parseErrs
}

func TestGrokParser_EmitsOneEventPerModelPlusOneCoverageEvent(t *testing.T) {
	events, parseErrs := parseGrokFixture(t)
	if parseErrs != 1 {
		t.Fatalf("parse errors = %d, want 1 (the malformed line)", parseErrs)
	}

	var usage, coverage []Event
	for _, e := range events {
		if e.CoverageOnly {
			coverage = append(coverage, e)
		} else {
			usage = append(usage, e)
		}
	}
	// 5 turn_completed records (p1, p2, p3, p1-dup, p4) each yield
	// exactly one coverage event; the non-turn_completed and malformed
	// lines yield none.
	if len(coverage) != 5 {
		t.Fatalf("coverage events = %d, want 5", len(coverage))
	}
	withUsage := 0
	for _, e := range coverage {
		if e.HasUsage {
			withUsage++
		}
		// Every coverage event must be dedupe-addressable, or a re-scan
		// silently inflates the tally.
		if e.MessageID == "" || e.RequestID != "coverage" {
			t.Fatalf("coverage event has dedupe key %q:%q, want <prompt_id>:coverage",
				e.MessageID, e.RequestID)
		}
	}
	// p1, p3 and p1-dup carry a usable cost. p2 has no usage at all and
	// p4's costUsdTicks is 0 — neither counts as covered.
	if withUsage != 3 {
		t.Fatalf("coverage events with usable cost = %d, want 3", withUsage)
	}
	// p1 -> 1 model, p3 -> 2 models, p1-dup -> 1 model, p4 -> 1 model.
	// Dedupe is the aggregator's job (MessageID:RequestID), not the
	// parser's.
	if len(usage) != 5 {
		t.Fatalf("usage events = %d, want 5", len(usage))
	}
}

// A record whose cost is zero but whose tokens are real is kept, not
// dropped: a missing cost is a coverage problem, not a free turn.
func TestGrokParser_ZeroCostRecordIsKeptWithItsTokens(t *testing.T) {
	events, _ := parseGrokFixture(t)
	var found bool
	for _, e := range events {
		if e.CoverageOnly || e.MessageID != "p4" {
			continue
		}
		found = true
		if e.CostUSD != 0 {
			t.Fatalf("CostUSD = %v, want 0", e.CostUSD)
		}
		if !e.Costed {
			t.Fatal("Costed = false; a zero-cost Grok cell is still costed, not priced")
		}
		if e.Usage.OutputTokens != 50 {
			t.Fatalf("output = %d, want 50 — the tokens must survive", e.Usage.OutputTokens)
		}
	}
	if !found {
		t.Fatal("the zero-cost record produced no usage event")
	}
}

func TestGrokParser_TokenAndCostMapping(t *testing.T) {
	events, _ := parseGrokFixture(t)
	var first Event
	for _, e := range events {
		if !e.CoverageOnly && e.MessageID == "p1" {
			first = e
			break
		}
	}
	if first.Model != "grok-4.6-build" {
		t.Fatalf("model = %q, want grok-4.6-build", first.Model)
	}
	// inputTokens INCLUDES cachedReadTokens (totalTokens == input+output
	// on the live records), so the uncached input is the difference.
	if first.Usage.InputTokens != 210887-158592 {
		t.Fatalf("input = %d, want %d", first.Usage.InputTokens, 210887-158592)
	}
	if first.Usage.CacheReadInputTokens != 158592 {
		t.Fatalf("cacheRead = %d, want 158592", first.Usage.CacheReadInputTokens)
	}
	// reasoningTokens is a subset of outputTokens and must NOT be added.
	if first.Usage.OutputTokens != 5833 {
		t.Fatalf("output = %d, want 5833", first.Usage.OutputTokens)
	}
	if first.Usage.CacheCreationInputTokens != 0 {
		t.Fatalf("cacheCreate = %d, want 0 (Grok reports none)", first.Usage.CacheCreationInputTokens)
	}
	if !first.Costed {
		t.Fatal("Costed = false, want true")
	}
	// costUsdTicks are nano-dollars.
	if math.Abs(first.CostUSD-0.3721028) > 1e-9 {
		t.Fatalf("CostUSD = %v, want 0.3721028", first.CostUSD)
	}
	// The dedupe key is prompt_id + model, so a multi-model turn keeps
	// both of its cells.
	if first.RequestID != "grok-4.6-build" {
		t.Fatalf("RequestID = %q, want the model name", first.RequestID)
	}
}

func TestGrokParser_TopLevelTotalsNeverAddedOnTopOfModelUsage(t *testing.T) {
	events, _ := parseGrokFixture(t)
	total := 0.0
	for _, e := range events {
		if e.CoverageOnly || e.MessageID != "p3" {
			continue
		}
		total += e.CostUSD
	}
	// p3's top-level costUsdTicks is 3e9 ($3.00) and its two models sum
	// to exactly that. Emitting both would report $6.00.
	if math.Abs(total-3.0) > 1e-9 {
		t.Fatalf("p3 total = %v, want 3.00 (modelUsage only)", total)
	}
}

func TestGrokProjectKey_MatchesClaudeEncoding(t *testing.T) {
	// The session directory is the percent-encoded cwd. Decoding it and
	// re-encoding the Claude way keeps one project one row in the
	// per-project table regardless of which vendor produced the spend.
	got := grokProjectKey(grokRoot, grokPath)
	if got != "-Users-me-src-proj" {
		t.Fatalf("project = %q, want -Users-me-src-proj", got)
	}
	// A dot in the path becomes a dash, exactly as Claude encodes it
	// (~/.claude -> -Users-me--claude).
	dotted := grokRoot + "/%2FUsers%2Fme%2F.config%2Fx/sess/updates.jsonl"
	if got := grokProjectKey(grokRoot, dotted); got != "-Users-me--config-x" {
		t.Fatalf("project = %q, want -Users-me--config-x", got)
	}
}

func TestGrokParser_WalkableOnlyMatchesUpdatesJSONL(t *testing.T) {
	p := grokParser{}
	if !p.Walkable("updates.jsonl") {
		t.Fatal("updates.jsonl must be walkable")
	}
	// _meta.totalTokens lives in other files and is cumulative context,
	// not usage. Reading them would be a large silent overcount.
	for _, name := range []string{"messages.jsonl", "meta.jsonl", "notes.txt"} {
		if p.Walkable(name) {
			t.Fatalf("%s must not be walkable", name)
		}
	}
}

func TestGrokParser_IsSubagent(t *testing.T) {
	p := grokParser{}
	sub := grokRoot + "/%2FUsers%2Fme%2F.grok%2Fworktrees%2Fx%2Fsubagent-01a0/01a0/updates.jsonl"
	if !p.IsSubagent(grokRoot, sub) {
		t.Fatal("a subagent worktree session must be flagged")
	}
	if p.IsSubagent(grokRoot, grokPath) {
		t.Fatal("a main session must not be flagged")
	}
}
