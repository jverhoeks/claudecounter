package session

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fixture lines for a small but complete session: two user prompts (mode
// default → bypassPermissions), two tool calls (one ok, one error), one
// duplicated assistant line (same messageId:requestId AND same tool_use
// block id — streaming re-serialisation).
const mainFixture = `{"type":"user","timestamp":"2026-06-01T10:00:00Z","sessionId":"s1","cwd":"/tmp/proj","entrypoint":"cli","permissionMode":"default","message":{"role":"user","content":"please do X"}}
{"type":"assistant","timestamp":"2026-06-01T10:00:05Z","sessionId":"s1","cwd":"/tmp/proj","requestId":"req1","message":{"id":"msg1","model":"claude-opus-4-7","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000},"content":[{"type":"text","text":"on it"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"go test ./..."}}]}}
{"type":"user","timestamp":"2026-06-01T10:00:09Z","sessionId":"s1","cwd":"/tmp/proj","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]}}
{"type":"user","timestamp":"2026-06-01T10:01:00Z","sessionId":"s1","cwd":"/tmp/proj","entrypoint":"cli","permissionMode":"bypassPermissions","message":{"role":"user","content":"now dangerously"}}
{"type":"assistant","timestamp":"2026-06-01T10:01:05Z","sessionId":"s1","cwd":"/tmp/proj","requestId":"req2","message":{"id":"msg2","model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":200},"content":[{"type":"tool_use","id":"tu2","name":"Edit","input":{"file_path":"/tmp/proj/main.go"}}]}}
{"type":"assistant","timestamp":"2026-06-01T10:01:05Z","sessionId":"s1","cwd":"/tmp/proj","requestId":"req2","message":{"id":"msg2","model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":200},"content":[{"type":"tool_use","id":"tu2","name":"Edit","input":{"file_path":"/tmp/proj/main.go"}}]}}
{"type":"user","timestamp":"2026-06-01T10:01:09Z","sessionId":"s1","cwd":"/tmp/proj","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu2","content":"no such file","is_error":true}]}}
{"type":"system","timestamp":"2026-06-01T10:02:00Z","sessionId":"s1","content":"done"}
`

const subFixture = `{"type":"assistant","timestamp":"2026-06-01T10:00:30Z","sessionId":"s1","cwd":"/tmp/proj","isSidechain":true,"requestId":"req9","message":{"id":"msg9","model":"claude-haiku-4-5","usage":{"input_tokens":7,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":[{"type":"tool_use","id":"tu9","name":"Read","input":{"file_path":"/tmp/proj/go.mod"}}]}}
{"type":"user","timestamp":"2026-06-01T10:00:31Z","sessionId":"s1","cwd":"/tmp/proj","isSidechain":true,"permissionMode":"bypassPermissions","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu9","content":"module x"}]}}
`

// writeFixture lays out <dir>/abc123.jsonl plus its subagents dir and
// returns the main path.
func writeFixture(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	main := filepath.Join(dir, "abc123.jsonl")
	if err := os.WriteFile(main, []byte(mainFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	subDir := filepath.Join(dir, "abc123", "subagents")
	if err := os.MkdirAll(subDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(subDir, "agent-1.jsonl"), []byte(subFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	return main
}

func TestParse_Basic(t *testing.T) {
	s, err := Parse(writeFixture(t))
	if err != nil {
		t.Fatal(err)
	}

	if s.ID != "abc123" {
		t.Errorf("ID = %q", s.ID)
	}
	if s.Cwd != "/tmp/proj" || s.Entrypoint != "cli" {
		t.Errorf("cwd/entrypoint: %q %q", s.Cwd, s.Entrypoint)
	}
	if s.Prompts != 2 {
		t.Errorf("Prompts = %d, want 2 (subagent prompt must not count)", s.Prompts)
	}
	if s.ModeTurns["default"] != 1 || s.ModeTurns["bypassPermissions"] != 1 {
		t.Errorf("ModeTurns = %v", s.ModeTurns)
	}
	if len(s.ModeChanges) != 2 ||
		s.ModeChanges[0].To != "default" || s.ModeChanges[0].From != "" ||
		s.ModeChanges[1].From != "default" || s.ModeChanges[1].To != "bypassPermissions" {
		t.Errorf("ModeChanges = %+v", s.ModeChanges)
	}

	// 3 tool calls (dup tu2 collapsed), chronological: Bash, Read(sub), Edit.
	if len(s.ToolCalls) != 3 {
		t.Fatalf("ToolCalls = %d, want 3: %+v", len(s.ToolCalls), s.ToolCalls)
	}
	if s.ToolCalls[0].Name != "Bash" || s.ToolCalls[0].Target != "go test ./..." ||
		s.ToolCalls[0].IsErr || !s.ToolCalls[0].HasResult || s.ToolCalls[0].Sub {
		t.Errorf("call[0] = %+v", s.ToolCalls[0])
	}
	if s.ToolCalls[1].Name != "Read" || !s.ToolCalls[1].Sub || s.ToolCalls[1].IsErr {
		t.Errorf("call[1] = %+v", s.ToolCalls[1])
	}
	if s.ToolCalls[2].Name != "Edit" || !s.ToolCalls[2].IsErr || !s.ToolCalls[2].HasResult {
		t.Errorf("call[2] = %+v", s.ToolCalls[2])
	}

	// Tokens: msg1 + msg2 (deduped) + sub msg9.
	if s.Tokens.InputTokens != 117 || s.Tokens.OutputTokens != 58 ||
		s.Tokens.CacheCreationInputTokens != 1100 || s.Tokens.CacheReadInputTokens != 2200 {
		t.Errorf("Tokens = %+v", s.Tokens)
	}
	if s.PeakContext != 3100 { // msg1: 100+1000+2000
		t.Errorf("PeakContext = %d", s.PeakContext)
	}
	if len(s.Turns) != 3 {
		t.Errorf("Turns = %d, want 3", len(s.Turns))
	}

	// Real user prose captured (both main prompts; subagent/tool_result excluded).
	if len(s.UserPrompts) != 2 ||
		s.UserPrompts[0].Text != "please do X" || s.UserPrompts[0].Mode != "default" ||
		s.UserPrompts[1].Text != "now dangerously" {
		t.Errorf("UserPrompts = %+v", s.UserPrompts)
	}

	start, _ := time.Parse(time.RFC3339, "2026-06-01T10:00:00Z")
	end, _ := time.Parse(time.RFC3339, "2026-06-01T10:02:00Z")
	if !s.Start.Equal(start) || !s.End.Equal(end) {
		t.Errorf("window: %v – %v", s.Start, s.End)
	}
}

func TestParse_PromptFilter(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "x.jsonl")
	// real prose; injected task-notification; isMeta; tool_result (no PM);
	// real prose with an embedded system-reminder to strip; text-block prompt.
	data := `{"type":"user","timestamp":"2026-06-01T10:00:00Z","permissionMode":"default","message":{"content":"fix the bug"}}
{"type":"user","timestamp":"2026-06-01T10:00:01Z","permissionMode":"default","message":{"content":"<task-notification> <task-id>b1</task-id>"}}
{"type":"user","timestamp":"2026-06-01T10:00:02Z","permissionMode":"default","isMeta":true,"message":{"content":"meta junk"}}
{"type":"user","timestamp":"2026-06-01T10:00:03Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"user","timestamp":"2026-06-01T10:00:04Z","permissionMode":"default","message":{"content":"keep this<system-reminder>drop me</system-reminder> part"}}
{"type":"user","timestamp":"2026-06-01T10:00:05Z","permissionMode":"default","message":{"content":[{"type":"text","text":"block prompt"}]}}
`
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Parse(p)
	if err != nil {
		t.Fatal(err)
	}
	got := make([]string, len(s.UserPrompts))
	for i, pr := range s.UserPrompts {
		got[i] = pr.Text
	}
	want := []string{"fix the bug", "keep this part", "block prompt"}
	if len(got) != len(want) {
		t.Fatalf("UserPrompts = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("prompt[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestParse_StringContentAndJunk(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "x.jsonl")
	data := `{"type":"user","timestamp":"2026-06-01T10:00:00Z","permissionMode":"plan","message":{"content":"hi"}}
not json at all
{"type":"queue-operation","operation":"add"}
`
	if err := os.WriteFile(p, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Parse(p)
	if err != nil {
		t.Fatal(err)
	}
	if s.Prompts != 1 || s.ModeTurns["plan"] != 1 {
		t.Errorf("prompts=%d modes=%v", s.Prompts, s.ModeTurns)
	}
}

func TestToolTarget(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{`{"command":"ls -la"}`, "ls -la"},
		{`{"file_path":"/a/b.go","old_string":"x"}`, "/a/b.go"},
		{`{"pattern":"foo.*bar"}`, "foo.*bar"},
		{`{"url":"https://x.test"}`, "https://x.test"},
		{`{"skill":"commit"}`, "commit"},
		{`{"prompt":"do the thing with details"}`, "do the thing with details"},
		{`{"unknown_key":true}`, ""},
		{``, ""},
	}
	for _, c := range cases {
		if got := toolTarget([]byte(c.in)); got != c.want {
			t.Errorf("toolTarget(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestFind(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "-tmp-proj")
	if err := os.MkdirAll(filepath.Join(proj, "olds", "subagents"), 0o755); err != nil {
		t.Fatal(err)
	}
	old := filepath.Join(proj, "older-session.jsonl")
	newer := filepath.Join(proj, "newer-session.jsonl")
	sub := filepath.Join(proj, "olds", "subagents", "agent-1.jsonl")
	for _, p := range []string{old, newer, sub} {
		if err := os.WriteFile(p, []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	past := time.Now().Add(-time.Hour)
	if err := os.Chtimes(old, past, past); err != nil {
		t.Fatal(err)
	}
	// Subagent files must never win "most recent" even with a fresh mtime.

	got, err := Find(root, "")
	if err != nil {
		t.Fatal(err)
	}
	if got != newer {
		t.Errorf("Find latest = %q, want %q", got, newer)
	}

	got, err = Find(root, "older")
	if err != nil {
		t.Fatal(err)
	}
	if got != old {
		t.Errorf("Find prefix = %q, want %q", got, old)
	}

	if _, err := Find(root, "nope"); err == nil {
		t.Error("Find with unmatched prefix should error")
	}
}
