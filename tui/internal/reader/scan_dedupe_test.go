package reader_test

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

// The same turn really does get written into two session directories:
// across the local corpus 187 of 188 prompt_ids are unique and the one
// exception appears under two session ids in the same worktree. Scanning
// both directories is correct — a parent turn does not include its
// subagents' cost — so dedupe is the only thing standing between that
// turn and being billed twice.
func TestScan_DuplicateTurnAcrossSessionDirsIsCountedOnce(t *testing.T) {
	// The root must be the sessions directory itself, the way
	// sources.Defaults builds it: grokProjectKey and IsSubagent both
	// anchor on the "/sessions/" segment, so a fixture rooted anywhere
	// else wouldn't exercise the subagent-worktree path this test names.
	root := filepath.Join(t.TempDir(), "sessions")
	line := `{"timestamp":1786807668,"method":"_x.ai/session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"turn_completed","prompt_id":"shared-1","usage":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":400,"costUsdTicks":1656000000,"modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":400,"costUsdTicks":1656000000}}}}}}` + "\n"

	enc := "%2FUsers%2Fme%2F.grok%2Fworktrees%2Fx%2Fsubagent-aaaa"
	for _, sess := range []string{"aaaa", "bbbb"} {
		dir := filepath.Join(root, enc, sess)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "updates.jsonl"),
			[]byte(fmt.Sprintf(line, sess)), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	ch := make(chan reader.Event, 64)
	r := reader.New(ch)
	if err := r.InitialScanSource(
		sources.Source{Vendor: "grok", Label: "grok", Root: root}, time.Time{}); err != nil {
		t.Fatal(err)
	}
	close(ch)

	a := agg.NewWithClock(pricing.Table{}, func() time.Time {
		return time.Unix(1786807668, 0)
	})
	for e := range ch {
		a.Apply(e)
	}
	got := a.Snapshot()
	total := 0.0
	for _, md := range got.Month {
		total += md.USD
	}
	if math.Abs(total-1.656) > 1e-9 {
		t.Fatalf("month total = %v, want 1.656 — the turn appears in two session dirs and must be counted once", total)
	}
	if got.Coverage["grok"].Turns != 1 {
		t.Fatalf("Coverage[grok].Turns = %d, want 1 — the coverage event is deduped the same way", got.Coverage["grok"].Turns)
	}
}
