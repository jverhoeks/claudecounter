package reader

import (
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
