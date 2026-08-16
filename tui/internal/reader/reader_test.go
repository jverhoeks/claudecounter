package reader

import (
	"os"
	"path/filepath"
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
