package safety

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestLikelyContainer(t *testing.T) {
	home := "/Users/jane"
	cases := []struct {
		cwd  string
		want bool
	}{
		{"/Users/jane/src/proj", false},
		{"/Users/other/src", false}, // same /Users parent → host convention
		{"/workspace", true},
		{"/app/src", true},
		{"/home/node/app", true}, // linux-style home on a /Users host
		{"/root", true},
		{"/var/folders/8d/xyz/T/scratch", false}, // macOS $TMPDIR is host
		{"/tmp/scratch", false},
		{"/private/tmp/x", false},
		{"", false}, // unknown — never assert
	}
	for _, c := range cases {
		if got := LikelyContainer(c.cwd, home); got != c.want {
			t.Errorf("LikelyContainer(%q) = %v, want %v", c.cwd, got, c.want)
		}
	}
}

func TestBuild(t *testing.T) {
	sessions := []SessionInfo{
		{Project: "-Users-jane-src-alpha", Cwd: "/Users/jane/src/alpha", Entrypoint: "cli",
			ModeTurns: map[string]int{"default": 6, "bypassPermissions": 2}},
		{Project: "-Users-jane-src-alpha", Cwd: "/Users/jane/src/alpha", Entrypoint: "sdk-py",
			ModeTurns: map[string]int{"auto": 2}},
		{Project: "-workspace", Cwd: "/workspace", Entrypoint: "cli",
			ModeTurns: map[string]int{"bypassPermissions": 10}},
		{Project: "-Users-jane-src-beta", Cwd: "/Users/jane/src/beta", Entrypoint: "cli",
			ModeTurns: map[string]int{"plan": 1, "default": 4}},
	}
	rows, sum := Build(sessions, "/Users/jane")

	if len(rows) != 3 {
		t.Fatalf("rows = %d, want 3", len(rows))
	}
	// Sorted by bypass%% desc: workspace (100%), alpha (20%), beta (0%).
	if rows[0].Project != "-workspace" || rows[1].Project != "-Users-jane-src-alpha" {
		t.Errorf("order: %q, %q, %q", rows[0].Project, rows[1].Project, rows[2].Project)
	}
	w := rows[0]
	if w.Turns != 10 || w.Sessions != 1 || w.BypassTurns != 10 || w.BypassPct != 100 || w.ContainerSessions != 1 {
		t.Errorf("workspace row = %+v", w)
	}
	a := rows[1]
	if a.Turns != 10 || a.Sessions != 2 || a.BypassTurns != 2 || a.BypassPct != 20 || a.ContainerSessions != 0 {
		t.Errorf("alpha row = %+v", a)
	}
	if got := a.Entrypoints; len(got) != 2 || got[0] != "cli" || got[1] != "sdk-py" {
		t.Errorf("alpha entrypoints = %v", got)
	}
	b := rows[2]
	if b.BypassTurns != 0 || b.Turns != 5 {
		t.Errorf("beta row = %+v", b)
	}

	if sum.TotalTurns != 25 || sum.BypassTurns != 12 {
		t.Errorf("summary turns = %+v", sum)
	}
	if sum.BypassProjects != 2 || sum.ContainerSessions != 1 {
		t.Errorf("summary = %+v", sum)
	}
}

func TestScan(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "-tmp-x")
	if err := os.MkdirAll(filepath.Join(proj, "sess1", "subagents"), 0o755); err != nil {
		t.Fatal(err)
	}
	main := `{"type":"user","timestamp":"2026-06-10T10:00:00Z","cwd":"/tmp/x","entrypoint":"cli","permissionMode":"default","message":{"content":"a"}}
{"type":"user","timestamp":"2026-06-10T10:01:00Z","cwd":"/tmp/x","permissionMode":"bypassPermissions","message":{"content":"b"}}
{"type":"user","timestamp":"2020-01-01T00:00:00Z","cwd":"/tmp/x","permissionMode":"default","message":{"content":"ancient, outside window"}}
{"type":"assistant","timestamp":"2026-06-10T10:00:05Z","message":{"model":"m","usage":{"input_tokens":1}}}
`
	sub := `{"type":"user","timestamp":"2026-06-10T10:00:30Z","cwd":"/tmp/x","permissionMode":"bypassPermissions","isSidechain":true,"message":{"content":"sub prompt must not count"}}
`
	if err := os.WriteFile(filepath.Join(proj, "sess1.jsonl"), []byte(main), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, "sess1", "subagents", "agent-1.jsonl"), []byte(sub), 0o644); err != nil {
		t.Fatal(err)
	}

	notBefore := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	got, err := Scan(root, notBefore)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("sessions = %d, want 1 (subagent file skipped): %+v", len(got), got)
	}
	s := got[0]
	if s.Project != "-tmp-x" || s.Cwd != "/tmp/x" || s.Entrypoint != "cli" {
		t.Errorf("session = %+v", s)
	}
	if s.ModeTurns["default"] != 1 || s.ModeTurns["bypassPermissions"] != 1 {
		t.Errorf("ModeTurns = %v (out-of-window turn must be dropped)", s.ModeTurns)
	}
}
