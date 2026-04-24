package reader

import (
	"os"
	"path/filepath"
	"testing"
	"time"
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

func TestParseLine_SkipsNonAssistant(t *testing.T) {
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

func TestParseLine_SkipsSyntheticModel(t *testing.T) {
	line := []byte(`{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T10:00:00Z","sessionId":"s","cwd":"/x"}`)
	_, ok, err := parseLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("expected <synthetic> event to be skipped")
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
