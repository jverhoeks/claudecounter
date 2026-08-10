package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
	"github.com/jverhoeks/claudecounter/tui/internal/sources"
	"github.com/jverhoeks/claudecounter/tui/internal/watcher"
)

// usageLine returns one minimal assistant JSONL line carrying usage, so
// it lands in the current month regardless of what "now" is when the
// test runs. The brief's fixture (testdata/session_normal.jsonl) has a
// timestamp baked into 2026-04-24, which would fall outside "this
// month" whenever the suite runs in a different month — a fixture bug,
// not a bug in the code under test — so these tests generate their own
// events instead, the same way run_once_characterization_test.go does.
func usageLine(id, ts string) string {
	return `{"type":"assistant","message":{"id":"` + id + `","model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"` + ts + `","sessionId":"s","cwd":"/x","requestId":"` + id + `-req"}` + "\n"
}

// Two roots, each with one project, must both land in the snapshot and
// stay distinguishable by source.
func TestScanSnapshotCoversEverySource(t *testing.T) {
	home := t.TempDir()
	nowRFC := time.Now().UTC().Format(time.RFC3339)
	for _, root := range []string{"a", "b"} {
		dir := filepath.Join(home, root, "projects", "proj")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		// Distinct message ids per root so dedupe does not collapse them.
		if err := os.WriteFile(filepath.Join(dir, "s.jsonl"), []byte(usageLine(root+"msg", nowRFC)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := filepath.Join(home, "sources.toml")
	if err := os.WriteFile(cfg, []byte(`
[[source]]
vendor = "claude"
label  = "a"
root   = "`+filepath.Join(home, "a", "projects")+`"

[[source]]
vendor = "claude"
label  = "b"
root   = "`+filepath.Join(home, "b", "projects")+`"
`), 0o644); err != nil {
		t.Fatal(err)
	}

	snap := scanSnapshotFromConfig(cfg, home, pricing.Defaults())
	seen := map[string]bool{}
	for k := range snap.Month {
		seen[k.Source] = true
	}
	if !seen["claude/a"] || !seen["claude/b"] {
		t.Fatalf("both sources must appear, got %+v", seen)
	}
}

// With no config file the behaviour must be exactly what it was before
// this feature existed: one implicit claude source.
func TestScanSnapshotWithNoConfigUsesDefault(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "projects", "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	nowRFC := time.Now().UTC().Format(time.RFC3339)
	if err := os.WriteFile(filepath.Join(dir, "s.jsonl"), []byte(usageLine("m1", nowRFC)), 0o644); err != nil {
		t.Fatal(err)
	}

	snap := scanSnapshotFromConfig(filepath.Join(home, "absent.toml"), home, pricing.Defaults())
	for k := range snap.Month {
		if k.Source != "claude/claude" {
			t.Fatalf("default source must be claude/claude, got %q", k.Source)
		}
	}
	if len(snap.Month) == 0 {
		t.Fatal("expected the default root to be scanned")
	}
}

// A configured root that doesn't exist is skipped, not fatal — matching
// how an absent vendor already behaves.
func TestScanSnapshotSkipsMissingRoot(t *testing.T) {
	home := t.TempDir()
	present := filepath.Join(home, "present", "projects", "proj")
	if err := os.MkdirAll(present, 0o755); err != nil {
		t.Fatal(err)
	}
	nowRFC := time.Now().UTC().Format(time.RFC3339)
	if err := os.WriteFile(filepath.Join(present, "s.jsonl"), []byte(usageLine("m1", nowRFC)), 0o644); err != nil {
		t.Fatal(err)
	}

	srcs := []sources.Source{
		{Vendor: "claude", Label: "gone", Root: filepath.Join(home, "does-not-exist")},
		{Vendor: "claude", Label: "here", Root: filepath.Join(home, "present", "projects")},
	}
	snap, _, _ := scanSnapshotSources(srcs, pricing.Defaults())
	seen := map[string]bool{}
	for k := range snap.Month {
		seen[k.Source] = true
	}
	if seen["claude/gone"] {
		t.Fatalf("missing root must contribute nothing, got %+v", seen)
	}
	if !seen["claude/here"] {
		t.Fatalf("present root must be scanned, got %+v", seen)
	}
}

// This is the concurrency hazard the plan flagged: a shared Reader's
// source field would let a live file-change event for one source get
// mis-tagged if a scan of a different source were happening at the
// same time. handleWatchChange resolves the owning source itself and
// dispatches to that source's own Reader, so the tag is right by
// construction rather than by timing.
func TestHandleWatchChangeDispatchesToOwningSource(t *testing.T) {
	home := t.TempDir()
	rootA := filepath.Join(home, "a", "projects")
	rootB := filepath.Join(home, "b", "projects")
	if err := os.MkdirAll(filepath.Join(rootA, "proj"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(rootB, "proj"), 0o755); err != nil {
		t.Fatal(err)
	}
	srcA := sources.Source{Vendor: "claude", Label: "a", Root: rootA}
	srcB := sources.Source{Vendor: "claude", Label: "b", Root: rootB}
	rsrcs := resolveSourceRoots([]sources.Source{srcA, srcB})

	evCh := make(chan reader.Event, 16)
	readers := map[string]*reader.Reader{
		srcA.ID(): reader.New(evCh),
		srcB.ID(): reader.New(evCh),
	}

	fileB := filepath.Join(rootB, "proj", "s.jsonl")
	nowRFC := time.Now().UTC().Format(time.RFC3339)
	if err := os.WriteFile(fileB, []byte(usageLine("bmsg", nowRFC)), 0o644); err != nil {
		t.Fatal(err)
	}

	// Simulate what fsnotify can report on a system where the temp
	// directory sits behind a symlink (e.g. macOS's /var -> /private/var):
	// the reported path may be the fully resolved one, not the literal
	// string the source was configured with.
	reportedPath := fileB
	if resolved, err := filepath.EvalSymlinks(fileB); err == nil {
		reportedPath = resolved
	}

	handleWatchChange(watcher.Change{Path: reportedPath, Kind: watcher.Write}, rsrcs, readers)
	close(evCh)

	var got reader.Event
	found := false
	for e := range evCh {
		got = e
		found = true
	}
	if !found {
		t.Fatal("expected one event")
	}
	if got.Source != srcB.ID() {
		t.Fatalf("event tagged with wrong source: got %q want %q", got.Source, srcB.ID())
	}
}
