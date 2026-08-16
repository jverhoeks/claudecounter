package reader

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

func TestParseLine_Assistant(t *testing.T) {
	line := []byte(`{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}},"sessionId":"s1","cwd":"/tmp/x","timestamp":"2026-04-24T14:00:01Z"}`)
	ev, ok, err := parseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("expected event")
	}
	if ev.Model != "claude-opus-4-7" {
		t.Errorf("model: %q", ev.Model)
	}
	if ev.Usage.InputTokens != 10 || ev.Usage.OutputTokens != 20 ||
		ev.Usage.CacheCreationInputTokens != 30 || ev.Usage.CacheReadInputTokens != 40 {
		t.Errorf("usage: %+v", ev.Usage)
	}
	if ev.SessionID != "s1" || ev.Cwd != "/tmp/x" {
		t.Errorf("ids: %+v", ev)
	}
	want, _ := time.Parse(time.RFC3339, "2026-04-24T14:00:01Z")
	if !ev.Timestamp.Equal(want) {
		t.Errorf("ts: %v", ev.Timestamp)
	}
}

func TestProjectFromPath_BothSeparators(t *testing.T) {
	cases := []struct {
		path string
		want string
	}{
		{"/Users/x/.claude/projects/-foo-bar/abc.jsonl", "-foo-bar"},
		{"/Users/x/.claude/projects/-foo-bar/sess/subagents/agent-1.jsonl", "-foo-bar"},
		// Windows-style normalised by filepath.ToSlash before reaching here:
		{"C:/Users/x/.claude/projects/-foo-bar/abc.jsonl", "-foo-bar"},
		{"/no/projects/segment/here.jsonl", "segment"}, // last "/projects/" wins
		{"", ""},
	}
	for _, c := range cases {
		if got := projectFromPath(c.path); got != c.want {
			t.Errorf("projectFromPath(%q) = %q, want %q", c.path, got, c.want)
		}
	}
}

func TestParseLine_SkipsLinesWithoutUsage(t *testing.T) {
	// Per ccusage rules we don't filter by type; we DO require message.usage.
	for _, l := range []string{
		`{"type":"user","message":{"content":"x"}}`,
		`{"type":"permission-mode"}`,
		`{"type":"assistant","message":{"model":"x"}}`, // no usage
	} {
		_, ok, err := parseLine([]byte(l))
		if err != nil {
			t.Fatalf("%s: %v", l, err)
		}
		if ok {
			t.Errorf("%s: expected skip", l)
		}
	}
}

func TestParseLine_Malformed(t *testing.T) {
	_, _, err := parseLine([]byte(`{not json`))
	if err == nil {
		t.Fatal("expected parse error")
	}
}

func TestOnChange_ReadsAppendedLinesOnly(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")

	first := `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"}` + "\n"
	if err := os.WriteFile(path, []byte(first), 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 8)
	r := New(ch)
	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ch:
	default:
		t.Fatal("expected event after first OnChange")
	}

	second := `{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":2,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:01Z","sessionId":"s","cwd":"/x"}` + "\n"
	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(second)
	f.Close()

	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		if ev.Model != "claude-sonnet-4-6" {
			t.Fatalf("expected sonnet, got %q", ev.Model)
		}
	default:
		t.Fatal("expected event after append")
	}
	select {
	case ev := <-ch:
		t.Fatalf("unexpected extra event: %+v", ev)
	default:
	}
}

func TestOnChange_PartialLineNotAdvanced(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")

	partial := `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":9,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"`
	os.WriteFile(path, []byte(partial), 0o644)

	ch := make(chan Event, 4)
	r := New(ch)
	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		t.Fatalf("no event expected on partial line: %+v", ev)
	default:
	}

	f, _ := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString("}\n")
	f.Close()

	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		if ev.Usage.InputTokens != 9 {
			t.Fatalf("wrong event: %+v", ev)
		}
	default:
		t.Fatal("expected event once line completes")
	}
}

func TestOnChange_MalformedLineAdvancesButIsSkipped(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "s.jsonl")
	body := "{bad line\n" +
		`{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":7,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"}` + "\n"
	os.WriteFile(path, []byte(body), 0o644)

	ch := make(chan Event, 4)
	r := New(ch)
	if err := r.OnChange(path); err != nil {
		t.Fatal(err)
	}
	got := <-ch
	if got.Usage.InputTokens != 7 {
		t.Fatalf("expected second line to be delivered: %+v", got)
	}
	if r.ParseErrors() != 1 {
		t.Fatalf("want 1 parse error, got %d", r.ParseErrors())
	}
}

func TestInitialScan_SkipsFilesOlderThanNotBefore(t *testing.T) {
	root := t.TempDir()
	projA := filepath.Join(root, "projA")
	projB := filepath.Join(root, "projB")
	os.MkdirAll(projA, 0o755)
	os.MkdirAll(projB, 0o755)

	old := filepath.Join(projA, "old.jsonl")
	cur := filepath.Join(projB, "cur.jsonl")
	line := `{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"}` + "\n"
	os.WriteFile(old, []byte(line), 0o644)
	os.WriteFile(cur, []byte(line), 0o644)

	sixtyDaysAgo := time.Now().Add(-60 * 24 * time.Hour)
	os.Chtimes(old, sixtyDaysAgo, sixtyDaysAgo)

	ch := make(chan Event, 8)
	r := New(ch)

	notBefore := time.Now().Add(-30 * 24 * time.Hour)
	if err := r.InitialScan(root, notBefore); err != nil {
		t.Fatal(err)
	}
	close(ch)
	var events []Event
	for e := range ch {
		events = append(events, e)
	}
	if len(events) != 1 {
		t.Fatalf("want 1 event (from projB), got %d", len(events))
	}
}

func TestInitialScanSourceTagsEvents(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "proj-a")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join("testdata", "session_normal.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "s.jsonl"), body, 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 256)
	r := New(ch)
	src := sources.Source{Vendor: "claude", Label: "work", Root: root}
	if err := r.InitialScanSource(src, time.Time{}); err != nil {
		t.Fatalf("InitialScanSource: %v", err)
	}
	close(ch)

	n := 0
	for e := range ch {
		n++
		if e.Vendor != "claude" {
			t.Fatalf("Vendor = %q, want claude", e.Vendor)
		}
		if e.Source != "claude/work" {
			t.Fatalf("Source = %q, want claude/work", e.Source)
		}
	}
	if n == 0 {
		t.Fatal("expected at least one event from the fixture")
	}
}

// A Grok source scans end-to-end: the reader picks the Grok parser from
// the source's vendor, walks only updates.jsonl, and tags every event
// with the source identity.
func TestInitialScanSource_GrokEndToEnd(t *testing.T) {
	// The root must be the sessions directory itself, the way
	// sources.Defaults builds it: grokProjectKey finds the encoded cwd as
	// the first path segment under the configured root (grokSessionDir /
	// projectUnderRoot), so a fixture rooted anywhere else files every
	// event under the empty project.
	root := filepath.Join(t.TempDir(), "sessions")
	dir := filepath.Join(root, "%2FUsers%2Fme%2Fsrc%2Fproj", "01a0-sess")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("testdata/grok_updates.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "updates.jsonl"), fixture, 0o644); err != nil {
		t.Fatal(err)
	}
	// A sibling file that must be ignored: its token fields are
	// cumulative context, not usage.
	if err := os.WriteFile(filepath.Join(dir, "messages.jsonl"), fixture, 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 64)
	r := New(ch)
	src := sources.Source{Vendor: "grok", Label: "grok", Root: root}
	if err := r.InitialScanSource(src, time.Time{}); err != nil {
		t.Fatal(err)
	}
	close(ch)

	var usage int
	for e := range ch {
		if e.Vendor != "grok" || e.Source != "grok/grok" {
			t.Fatalf("event tagged %s/%s, want grok/grok", e.Vendor, e.Source)
		}
		if e.CoverageOnly {
			continue
		}
		usage++
		if e.Project != "-Users-me-src-proj" {
			t.Fatalf("project = %q, want -Users-me-src-proj", e.Project)
		}
		if !e.Costed {
			t.Fatal("a Grok usage event must be costed")
		}
	}
	// Exactly the 5 usage events from updates.jsonl. If messages.jsonl
	// were also walked this would be 10.
	if usage != 5 {
		t.Fatalf("usage events = %d, want 5 (messages.jsonl must be skipped)", usage)
	}
}

// TestInitialScanSource_CodexEndToEnd scans a rollout file laid out the
// way ~/.codex/sessions actually nests them (YYYY/MM/DD/rollout-*.jsonl,
// not project-keyed like Claude's or Grok's), using the Task 2 fixture,
// and asserts the events reach the aggregator tagged codex/codex with the
// project key resolved from session_meta's cwd rather than the path.
func TestInitialScanSource_CodexEndToEnd(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "2026", "08", "09")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("testdata/codex_rollout.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "rollout-x.jsonl"), fixture, 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 64)
	r := New(ch)
	src := sources.Source{Vendor: "codex", Label: "codex", Root: root}
	if err := r.InitialScanSource(src, time.Time{}); err != nil {
		t.Fatal(err)
	}
	close(ch)

	var n int
	for e := range ch {
		n++
		if e.Vendor != "codex" || e.Source != "codex/codex" {
			t.Fatalf("event tagged %s/%s, want codex/codex", e.Vendor, e.Source)
		}
		if e.Project != "-Users-me-src-proj" {
			t.Fatalf("project = %q, want -Users-me-src-proj", e.Project)
		}
		if e.Costed {
			t.Fatal("Codex is priced, not costed: Costed must be false")
		}
	}
	// codex_rollout.jsonl yields 3 usage events (line 2, 4, 7) — see
	// TestCodexParser_DeltasTelescope in codex_test.go. No event may be a
	// negative delta; deltaEvent already clamps that, so a zero count or
	// wrong count here would mean the wiring, not the parser, is broken.
	if n != 3 {
		t.Fatalf("events = %d, want 3", n)
	}
}

// TestCodexParserState_ResetsBetweenFiles lays out two rollout files
// under one root, the second declaring a LOWER cumulative total than
// the first. If the Reader reused one codexParser across both files
// (instead of one per path), the second file's first reading would look
// like a within-session decrease against the first file's leftover
// running total — deltaEvent's restart rule — and silently contribute
// NO event at all, dropping that file's entire spend. A correctly reset
// (or, here, freshly allocated per path) parser instead treats the
// second file's first reading as its own baseline and reports it.
func TestCodexParserState_ResetsBetweenFiles(t *testing.T) {
	root := t.TempDir()
	dirA := filepath.Join(root, "2026", "08", "09")
	dirB := filepath.Join(root, "2026", "08", "10")
	if err := os.MkdirAll(dirA, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dirB, 0o755); err != nil {
		t.Fatal(err)
	}

	fileA := `{"timestamp":"2026-08-09T08:00:00.000Z","type":"session_meta","payload":{"session_id":"a1","cwd":"/Users/me/src/proj-a"}}` + "\n" +
		`{"timestamp":"2026-08-09T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":800,"cached_input_tokens":200,"output_tokens":200,"total_tokens":1000}}}}` + "\n"
	// File B's cumulative total (50) is far lower than file A's (1000).
	fileB := `{"timestamp":"2026-08-10T08:00:00.000Z","type":"session_meta","payload":{"session_id":"b1","cwd":"/Users/me/src/proj-b"}}` + "\n" +
		`{"timestamp":"2026-08-10T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}` + "\n"

	if err := os.WriteFile(filepath.Join(dirA, "rollout-a.jsonl"), []byte(fileA), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dirB, "rollout-b.jsonl"), []byte(fileB), 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 64)
	r := New(ch)
	src := sources.Source{Vendor: "codex", Label: "codex", Root: root}
	if err := r.InitialScanSource(src, time.Time{}); err != nil {
		t.Fatal(err)
	}
	close(ch)

	byProject := map[string]Event{}
	for e := range ch {
		byProject[e.Project] = e
	}

	evA, ok := byProject["-Users-me-src-proj-a"]
	if !ok {
		t.Fatal("missing event from file A")
	}
	if evA.Usage.InputTokens != 600 || evA.Usage.OutputTokens != 200 {
		t.Fatalf("file A event = %+v, want In=600 Out=200 (its own first-reading delta)", evA.Usage)
	}

	evB, ok := byProject["-Users-me-src-proj-b"]
	if !ok {
		t.Fatal("missing event from file B — a shared/unreset parser would silently drop it as a within-session decrease")
	}
	if evB.Usage.InputTokens != 30 || evB.Usage.OutputTokens != 10 {
		t.Fatalf("file B event = %+v, want In=30 Out=10 (its own first-reading delta, not a delta against file A's totals)", evB.Usage)
	}
}

// TestCodexParserState_ResumesAcrossOnChangeCalls is the resume case
// TestCodexParserState_ResetsBetweenFiles does not cover: OnChange is
// called twice on the SAME growing path, the way the live watcher does,
// with session_meta appearing only in the first chunk. A per-call fresh
// parser (rather than one persisted per path — see codexParser's doc
// comment and Controller ruling R3) would make the second call's delta
// equal the session's entire total-so-far instead of just what was
// appended, and would lose the project/subagent attribution that only
// session_meta carries.
func TestCodexParserState_ResumesAcrossOnChangeCalls(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rollout-resume.jsonl")

	first := `{"timestamp":"2026-08-09T08:00:00.000Z","type":"session_meta","payload":{"session_id":"r1","cwd":"/Users/me/src/resumeproj","parent_thread_id":"parent-9"}}` + "\n" +
		`{"timestamp":"2026-08-09T08:00:05.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-sol"}}}` + "\n" +
		`{"timestamp":"2026-08-09T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"total_tokens":1100}}}}` + "\n"
	if err := os.WriteFile(path, []byte(first), 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 8)
	r := New(ch)
	src := sources.Source{Vendor: "codex", Label: "codex", Root: dir}
	if err := r.OnChangeSource(src, path); err != nil {
		t.Fatal(err)
	}

	var firstEvents []Event
	for {
		select {
		case e := <-ch:
			firstEvents = append(firstEvents, e)
			continue
		default:
		}
		break
	}
	if len(firstEvents) != 1 {
		t.Fatalf("first OnChange: events = %d, want 1", len(firstEvents))
	}
	ev0 := firstEvents[0]
	if ev0.Usage.InputTokens != 800 || ev0.Usage.OutputTokens != 100 || ev0.Usage.CacheReadInputTokens != 200 {
		t.Fatalf("first event usage = %+v, want In=800 Out=100 CacheRead=200", ev0.Usage)
	}
	if ev0.Project != "-Users-me-src-resumeproj" || !ev0.IsSubagent {
		t.Fatalf("first event Project/IsSubagent = %q/%v, want -Users-me-src-resumeproj/true", ev0.Project, ev0.IsSubagent)
	}

	// Append a second token_count WITHOUT another session_meta line —
	// exactly what a real rollout file does after its first line.
	more := `{"timestamp":"2026-08-09T08:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":300,"output_tokens":150,"total_tokens":1650}}}}` + "\n"
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(more); err != nil {
		t.Fatal(err)
	}
	f.Close()

	if err := r.OnChangeSource(src, path); err != nil {
		t.Fatal(err)
	}
	var resumedEvents []Event
	for {
		select {
		case e := <-ch:
			resumedEvents = append(resumedEvents, e)
			continue
		default:
		}
		break
	}
	if len(resumedEvents) != 1 {
		t.Fatalf("resumed OnChange: events = %d, want 1", len(resumedEvents))
	}
	ev1 := resumedEvents[0]
	// Delta against the RETAINED running total (1000/200/100), not a
	// fresh-parser reading of the full cumulative total (1500/300/150).
	if ev1.Usage.InputTokens != 400 || ev1.Usage.OutputTokens != 50 || ev1.Usage.CacheReadInputTokens != 100 {
		t.Fatalf("resumed event usage = %+v, want In=400 Out=50 CacheRead=100 (delta against the retained baseline, not from zero)", ev1.Usage)
	}
	// session_meta was only ever seen in the first chunk; these must
	// still be correct, proving the SAME parser instance (not a fresh
	// one) handled this call.
	if ev1.Project != "-Users-me-src-resumeproj" || !ev1.IsSubagent {
		t.Fatalf("resumed event Project/IsSubagent = %q/%v, want -Users-me-src-resumeproj/true (state must survive across OnChange calls)", ev1.Project, ev1.IsSubagent)
	}
}

// TestCodexParserState_ResetsOnTruncation covers the other half of R3's
// lifecycle rule that TestCodexParserState_ResetsBetweenFiles and
// TestCodexParserState_ResumesAcrossOnChangeCalls don't: the SAME path
// read from byte offset 0 again because the file shrank or was
// replaced — the existing `stat.Size() < start` branch OnChange already
// detects. Without codexParser.Reset() there, the second read's first
// (lower) total_tokens reading looks like a within-session decrease
// against the leftover running total from before the truncation, and
// deltaEvent's restart rule contributes nothing — the same silent
// whole-file loss TestCodexParserState_ResetsBetweenFiles catches for
// two distinct paths, but here for one path reused.
func TestCodexParserState_ResetsOnTruncation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rollout-shrink.jsonl")

	first := `{"timestamp":"2026-08-09T08:00:00.000Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/shrinkproj"}}` + "\n" +
		`{"timestamp":"2026-08-09T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":800,"cached_input_tokens":200,"output_tokens":200,"total_tokens":1000}}}}` + "\n"
	if err := os.WriteFile(path, []byte(first), 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 8)
	r := New(ch)
	src := sources.Source{Vendor: "codex", Label: "codex", Root: dir}
	if err := r.OnChangeSource(src, path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		if ev.Usage.InputTokens != 600 || ev.Usage.OutputTokens != 200 {
			t.Fatalf("first read event = %+v, want In=600 Out=200", ev.Usage)
		}
	default:
		t.Fatal("expected an event from the first read")
	}

	// Replace the file with a shorter one (its cumulative total is much
	// LOWER than 1000) so stat.Size() < the recorded offset, exercising
	// OnChange's truncation branch.
	shrunk := `{"timestamp":"2026-08-09T09:00:00.000Z","type":"session_meta","payload":{"session_id":"s2","cwd":"/Users/me/src/shrinkproj"}}` + "\n" +
		`{"timestamp":"2026-08-09T09:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":10,"output_tokens":10,"total_tokens":50}}}}` + "\n"
	if len(shrunk) >= len(first) {
		t.Fatalf("test fixture bug: shrunk (%d bytes) must be shorter than first (%d bytes)", len(shrunk), len(first))
	}
	if err := os.WriteFile(path, []byte(shrunk), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := r.OnChangeSource(src, path); err != nil {
		t.Fatal(err)
	}
	select {
	case ev := <-ch:
		// A reset parser treats this as its own first reading: In =
		// 40-10 = 30, Out = 10. An unreset parser would instead see
		// 50 < the leftover total of 1000, take the "decreased" branch,
		// and emit NOTHING — this assertion catches exactly that.
		if ev.Usage.InputTokens != 30 || ev.Usage.OutputTokens != 10 {
			t.Fatalf("post-truncation event = %+v, want In=30 Out=10 (fresh baseline, not a decrease against the pre-truncation total)", ev.Usage)
		}
	default:
		t.Fatal("expected an event after truncation — a missing Reset() silently drops it as a within-session decrease")
	}
}

// TestReader_ForgetDropsCodexParserState asserts Forget removes a path's
// entry from codexParsers, not just from offsets: a long-running watcher
// that never dropped the codex side of this bookkeeping would leak one
// *codexParser per file ever seen, including deleted ones.
func TestReader_ForgetDropsCodexParserState(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rollout-forget.jsonl")
	content := `{"timestamp":"2026-08-09T08:00:00.000Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/proj"}}` + "\n" +
		`{"timestamp":"2026-08-09T08:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"total_tokens":110}}}}` + "\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 8)
	r := New(ch)
	src := sources.Source{Vendor: "codex", Label: "codex", Root: dir}
	if err := r.OnChangeSource(src, path); err != nil {
		t.Fatal(err)
	}

	r.mu.Lock()
	n := len(r.codexParsers)
	r.mu.Unlock()
	if n != 1 {
		t.Fatalf("codexParsers has %d entries after OnChange, want 1", n)
	}

	r.Forget(path)

	r.mu.Lock()
	n = len(r.codexParsers)
	r.mu.Unlock()
	if n != 0 {
		t.Fatalf("codexParsers has %d entries after Forget, want 0 (leaked)", n)
	}
}

// The old single-root entry point must keep working unchanged, tagged
// with the default source, so existing callers see no behaviour change.
func TestInitialScanDefaultsToClaudeSource(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "proj-a")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(filepath.Join("testdata", "session_normal.jsonl"))
	_ = os.WriteFile(filepath.Join(dir, "s.jsonl"), body, 0o644)

	ch := make(chan Event, 256)
	r := New(ch)
	if err := r.InitialScan(root, time.Time{}); err != nil {
		t.Fatalf("InitialScan: %v", err)
	}
	close(ch)
	for e := range ch {
		if e.Vendor != "claude" || e.Source != "claude/claude" {
			t.Fatalf("default tagging wrong: vendor=%q source=%q", e.Vendor, e.Source)
		}
	}
}

// TestReader_OnChange_ConcurrentSamePath_NoRaceNoDuplication is Finding
// 2 of the final review: watchers are registered CONCURRENTLY with
// InitialScanSource in main.go, and the pipeline consumes watcher events
// during backfill — so two goroutines can enter OnChange for the SAME
// path at once. Before the per-path lock, they'd fetch the SAME
// *codexParser from parserForChange's map and both call Parse on it
// without synchronization (a genuine data race on its unlocked fields),
// and could both observe the pre-call offset before either commits it,
// duplicating whatever bytes both of them read.
//
// A long fixture (many token_count readings, not just two) is used
// deliberately: OnChange's per-line parse loop needs to run long enough
// for two concurrently-launched goroutines to actually overlap inside
// it under `go test -race`, not just take turns entirely before/after
// each other by scheduling luck.
func TestReader_OnChange_ConcurrentSamePath_NoRaceNoDuplication(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "rollout-race.jsonl")

	base := time.Date(2026, 8, 16, 8, 0, 0, 0, time.UTC)
	var sb strings.Builder
	sb.WriteString(`{"timestamp":"` + base.Format(time.RFC3339Nano) +
		`","type":"session_meta","payload":{"session_id":"race1","cwd":"/Users/me/src/race"}}` + "\n")

	const readings = 300
	var wantTotal int64
	for i := 1; i <= readings; i++ {
		wantTotal += 10
		ts := base.Add(time.Duration(i) * time.Second).Format(time.RFC3339Nano)
		sb.WriteString(fmt.Sprintf(
			`{"timestamp":"%s","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%d,"cached_input_tokens":0,"output_tokens":0,"total_tokens":%d}}}}`+"\n",
			ts, wantTotal, wantTotal))
	}
	if err := os.WriteFile(path, []byte(sb.String()), 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, readings*2+8)
	r := New(ch)
	r.src = sources.Source{Vendor: "codex", Label: "codex", Root: dir}

	start := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	for i := 0; i < 2; i++ {
		go func() {
			defer wg.Done()
			<-start
			_ = r.OnChange(path)
		}()
	}
	close(start)
	wg.Wait()
	close(ch)

	var gotTotal int64
	for e := range ch {
		gotTotal += int64(e.Usage.InputTokens)
	}
	// Deltas telescope to the file's single-pass total regardless of how
	// the two calls split the reads between them — UNLESS the race lets
	// them both read from offset 0 (or both see the same stale
	// codexParser state), which duplicates a portion of the file.
	if gotTotal != wantTotal {
		t.Fatalf("summed input tokens across both concurrent OnChange calls = %d, want %d (single-pass total, not duplicated)", gotTotal, wantTotal)
	}
}
