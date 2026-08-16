package reader

import (
	"bufio"
	"os"
	"testing"
)

// parseCodexFixture runs testdata/codex_rollout.jsonl through a single
// codexParser instance, line by line, exactly the way OnChange would
// for one file — codexParser is stateful, so reusing one instance
// across all lines is the point of the test, not an implementation
// detail to route around.
func parseCodexFixture(t *testing.T) (events []Event, parseErrs int) {
	t.Helper()
	f, err := os.Open("testdata/codex_rollout.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	p := &codexParser{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		evs, err := p.Parse(sc.Bytes(), "irrelevant")
		if err != nil {
			parseErrs++
			continue
		}
		events = append(events, evs...)
	}
	return events, parseErrs
}

// TestCodexParser_DeltasTelescope hand-computes the expected deltas from
// the fixture:
//
// Line 2 (first reading, no baseline yet): delta is its own value.
//
//	In  = 1000 - 400 = 600
//	Out = 100 - 0    = 100
//
// Line 4 (second reading, deltas against line 2's totals):
//
//	deltaInput  = 3000 - 1000 = 2000
//	deltaCached = 1400 - 400  = 1000
//	In  = 2000 - 1000 = 1000   (equivalently (3000-1400) - (1000-400) = 1600-600 = 1000)
//	Out = 300 - 100 = 200
func TestCodexParser_DeltasTelescope(t *testing.T) {
	events, parseErrs := parseCodexFixture(t)
	if parseErrs != 1 {
		t.Fatalf("parse errors = %d, want 1 (the malformed line)", parseErrs)
	}
	if len(events) != 3 {
		t.Fatalf("events = %d, want 3 (line 2, line 4, line 7 — lines 5, 6 contribute none)", len(events))
	}

	first, second := events[0], events[1]
	if first.Usage.InputTokens != 600 {
		t.Fatalf("line 2 In = %d, want 600", first.Usage.InputTokens)
	}
	if first.Usage.OutputTokens != 100 {
		t.Fatalf("line 2 Out = %d, want 100", first.Usage.OutputTokens)
	}
	if first.Usage.CacheReadInputTokens != 400 {
		t.Fatalf("line 2 CacheRead = %d, want 400", first.Usage.CacheReadInputTokens)
	}

	if second.Usage.InputTokens != 1000 {
		t.Fatalf("line 4 In = %d, want 1000", second.Usage.InputTokens)
	}
	if second.Usage.OutputTokens != 200 {
		t.Fatalf("line 4 Out = %d, want 200", second.Usage.OutputTokens)
	}
	if second.Usage.CacheReadInputTokens != 1000 {
		t.Fatalf("line 4 CacheRead = %d, want 1000", second.Usage.CacheReadInputTokens)
	}
}

// TestCodexParser_DuplicateReadingYieldsNoEvent asserts line 5, which
// repeats line 4's totals exactly, contributes nothing: a duplicate
// telescopes to a zero delta.
func TestCodexParser_DuplicateReadingYieldsNoEvent(t *testing.T) {
	events, _ := parseCodexFixture(t)
	// line 2, line 4, line 7 only — never a fourth event from line 5.
	if len(events) != 3 {
		t.Fatalf("events = %d, want 3 (line 5's duplicate must not appear)", len(events))
	}
}

// TestCodexParser_DecreaseYieldsNoNegativeDelta covers both halves of
// the restart rule: line 6 (a decrease from 3300 to 11 total_tokens)
// contributes no event, and the recovery reading on line 7 deltas
// against the DECREASED baseline (11), not the pre-decrease one (3300).
//
// Hand-computed: line 7's totals are
// {input:110, cached:55, output:11}. Against the adopted baseline from
// line 6 {input:10, cached:5, output:1}:
//
//	deltaInput  = 110 - 10 = 100
//	deltaCached = 55 - 5   = 50
//	In  = (110-55) - (10-5) = 55 - 5 = 50   (equivalently 100 - 50 = 50)
//	Out = 11 - 1 = 10
//
// A parser that dropped the decreasing reading instead of adopting its
// value would instead compute In = (110-55)-(3000-1400) and go negative
// (clamped to 0) or otherwise diverge from 50 — this test would catch
// either failure.
func TestCodexParser_DecreaseYieldsNoNegativeDelta(t *testing.T) {
	events, _ := parseCodexFixture(t)
	if len(events) != 3 {
		t.Fatalf("events = %d, want 3 (line 6's decrease must not appear)", len(events))
	}
	third := events[2]
	if third.Usage.InputTokens != 50 {
		t.Fatalf("line 7 In = %d, want 50 (delta against the decreased baseline of 11, not 3300)", third.Usage.InputTokens)
	}
	if third.Usage.OutputTokens != 10 {
		t.Fatalf("line 7 Out = %d, want 10", third.Usage.OutputTokens)
	}
	if third.Usage.CacheReadInputTokens != 50 {
		t.Fatalf("line 7 CacheRead = %d, want 50", third.Usage.CacheReadInputTokens)
	}
}

// TestCodexParser_ModelFallsBackBeforeFirstDeclaration asserts line 2's
// event (before thread_settings_applied on line 3) resolves through the
// fallback, and line 4's event (after) carries the declared model —
// both happen to be gpt-5.6-sol here, but for different reasons.
func TestCodexParser_ModelFallsBackBeforeFirstDeclaration(t *testing.T) {
	events, _ := parseCodexFixture(t)
	if events[0].Model != "gpt-5.6-sol" {
		t.Fatalf("line 2 model = %q, want gpt-5.6-sol (fallback: no parent_thread_id)", events[0].Model)
	}
	if events[1].Model != "gpt-5.6-sol" {
		t.Fatalf("line 4 model = %q, want gpt-5.6-sol (declared by thread_settings_applied)", events[1].Model)
	}
}

// TestCodexParser_ParentThreadIdImpliesAutoReview uses a fixture that
// never declares thread_settings_applied at all and whose session_meta
// carries a parent_thread_id, and asserts both the model fallback and
// IsSubagent key off that field.
func TestCodexParser_ParentThreadIdImpliesAutoReview(t *testing.T) {
	lines := []string{
		`{"timestamp":"2026-08-09T09:00:00.000Z","type":"session_meta","payload":{"session_id":"s2","cwd":"/Users/me/src/proj","parent_thread_id":"parent-1"}}`,
		`{"timestamp":"2026-08-09T09:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550}}}}`,
	}
	p := &codexParser{}
	var events []Event
	for _, line := range lines {
		evs, err := p.Parse([]byte(line), "irrelevant")
		if err != nil {
			t.Fatalf("Parse error: %v", err)
		}
		events = append(events, evs...)
	}
	if len(events) != 1 {
		t.Fatalf("events = %d, want 1", len(events))
	}
	if events[0].Model != "codex-auto-review" {
		t.Fatalf("model = %q, want codex-auto-review", events[0].Model)
	}
	if !events[0].IsSubagent {
		t.Fatal("IsSubagent = false, want true (parent_thread_id present)")
	}
	if !p.IsSubagent("", "") {
		t.Fatal("codexParser.IsSubagent() = false, want true")
	}
}

// TestCodexParser_ProjectFromSessionMetaCwd asserts the project key
// comes from session_meta's cwd, encoded the way Claude encodes project
// directories — every '/' and '.' becomes '-' — and NOT from the
// transcript path, which for Codex carries no project information at
// all (its layout is YYYY/MM/DD/rollout-*.jsonl).
func TestCodexParser_ProjectFromSessionMetaCwd(t *testing.T) {
	p := &codexParser{}
	line := `{"timestamp":"2026-08-09T08:34:15.910Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/proj","originator":"codex-tui"}}`
	if _, err := p.Parse([]byte(line), "/Users/me/.codex/sessions/2026/08/09/rollout-abc.jsonl"); err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	// A deliberately unrelated path+root: proves Project reads state,
	// not its arguments.
	if got := p.Project("/some/other/root", "/some/other/path.jsonl"); got != "-Users-me-src-proj" {
		t.Fatalf("project = %q, want -Users-me-src-proj", got)
	}
}

// TestCodexParser_MalformedLineIsAParseError asserts the fixture's
// single malformed line is the only parse error, keeping the count
// exact rather than merely nonzero.
func TestCodexParser_MalformedLineIsAParseError(t *testing.T) {
	_, parseErrs := parseCodexFixture(t)
	if parseErrs != 1 {
		t.Fatalf("parse errors = %d, want 1", parseErrs)
	}
}

func TestCodexParser_WalkableMatchesRolloutPrefix(t *testing.T) {
	p := &codexParser{}
	if !p.Walkable("rollout-2026-08-09T08-34-15-910Z-abc.jsonl") {
		t.Fatal("a rollout-*.jsonl file must be walkable")
	}
	for _, name := range []string{"history.jsonl", "rollout-foo.json", "notes.txt"} {
		if p.Walkable(name) {
			t.Fatalf("%s must not be walkable", name)
		}
	}
}

func TestAliasedPricingModel(t *testing.T) {
	if got := aliasedPricingModel("codex-auto-review"); got != "gpt-5.6-luna" {
		t.Fatalf("aliasedPricingModel(codex-auto-review) = %q, want gpt-5.6-luna", got)
	}
	for _, model := range []string{"gpt-5.6-sol", "claude-sonnet-5", ""} {
		if got := aliasedPricingModel(model); got != model {
			t.Fatalf("aliasedPricingModel(%q) = %q, want unchanged", model, got)
		}
	}
}
