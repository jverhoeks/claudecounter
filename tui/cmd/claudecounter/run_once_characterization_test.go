package main

import (
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

// runOnceGolden pins the exact stdout of runOnce against a fixed fixture.
// It exists so Task 6's move of runOnce onto scanSnapshotSources (and the
// underlying sources.Source list) cannot silently change --once output:
// --once must remain byte-identical for a single implicit source.
//
// Every number below is chosen to avoid ties (sort.Slice is not stable)
// and to force both a dupe and a parse error, since those two counters
// live on objects (the aggregator and the reader) that the extraction
// moves ownership of — a test on agg.Totals alone would be blind to a
// regression there.
const runOnceGolden = `sentinel pricing warn
Today  $11.00
Month  $11.00
────────────────────────────────────────────────────────────
By model (this month):
  claude-sonnet-4-6                    $6.00   in=2000000 out=0 cache_write=0 cache_read=0
  claude-opus-4-7                      $5.00   in=1000000 out=0 cache_write=0 cache_read=0
────────────────────────────────────────────────────────────
By project (this month) — total · main · subagent:
  two                                          $6.00 · main     $6.00 · sub     $0.00
  one                                          $5.00 · main     $5.00 · sub     $0.00
────────────────────────────────────────────────────────────
deduped dupes=1  parse_errors=1  unknown_model_events=0
`

// buildRunOnceFixture writes two project transcripts under root/projects/:
// one/one.jsonl carries an Opus event plus an exact duplicate (same
// message+request id) and a malformed line; two/two.jsonl carries a
// Sonnet event. The source root is rooted at <tmpdir>/projects, and the
// project key is derived as the first path segment below that root (see
// projectUnderRoot) — so "one" and "two" land in distinct project
// buckets simply by being the two directories directly under root.
func buildRunOnceFixture(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "projects")
	one := filepath.Join(root, "one")
	two := filepath.Join(root, "two")
	if err := os.MkdirAll(one, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(two, 0o755); err != nil {
		t.Fatal(err)
	}

	nowRFC := time.Now().UTC().Format(time.RFC3339)

	opusLine := `{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"` + nowRFC + `","sessionId":"s1","cwd":"/x","requestId":"r1"}` + "\n"
	malformed := `{"type":"assistant", this is not json` + "\n"
	sonnetLine := `{"type":"assistant","message":{"id":"m2","model":"claude-sonnet-4-6","usage":{"input_tokens":2000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"` + nowRFC + `","sessionId":"s2","cwd":"/x","requestId":"r2"}` + "\n"

	oneContent := opusLine + opusLine /* exact duplicate: same msgid:reqid */ + malformed
	if err := os.WriteFile(filepath.Join(one, "one.jsonl"), []byte(oneContent), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(two, "two.jsonl"), []byte(sonnetLine), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

// captureStdout redirects os.Stdout for the duration of fn and returns
// everything written to it.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	fn()
	w.Close()
	os.Stdout = old
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}

func TestRunOnce_StdoutIsByteIdentical(t *testing.T) {
	root := buildRunOnceFixture(t)
	table := pricing.Defaults()

	srcs := []sources.Source{{Vendor: "claude", Label: "claude", Root: root}}
	out := captureStdout(t, func() {
		runOnce(srcs, table, "sentinel pricing warn")
	})

	if out != runOnceGolden {
		t.Fatalf("runOnce stdout changed.\n--- got ---\n%s\n--- want ---\n%s", out, runOnceGolden)
	}
}
