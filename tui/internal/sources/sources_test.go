package sources

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "sources.toml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// A missing file is the normal state: fall back to today's hardcoded
// roots so an existing user sees no change at all.
func TestLoadMissingFileYieldsDefaults(t *testing.T) {
	got, err := Load(filepath.Join(t.TempDir(), "absent.toml"), "/home/u")
	if err != nil {
		t.Fatalf("missing file must not error: %v", err)
	}
	want := Defaults("/home/u")
	if len(got.Sources) != len(want) || len(got.Sources) == 0 {
		t.Fatalf("got %+v, want defaults %+v", got.Sources, want)
	}
	if got.Sources[0] != want[0] {
		t.Fatalf("got %+v, want %+v", got.Sources[0], want[0])
	}
}

func TestDefaultsAreClaudeProjectsUnderHome(t *testing.T) {
	d := Defaults("/home/u")
	if len(d) != 1 {
		t.Fatalf("Phase A ships one default source, got %+v", d)
	}
	if d[0].Vendor != "claude" || d[0].Label != "claude" {
		t.Fatalf("got %+v", d[0])
	}
	if d[0].Root != "/home/u/.claude/projects" {
		t.Fatalf("Root = %q", d[0].Root)
	}
}

// A Grok install is picked up without any configuration, matching how
// planlimits already discovers ~/.grok with zero config. The Claude
// entry stays first so callers can rely on the ordering.
func TestDefaults_DiscoversGrokWhenPresent(t *testing.T) {
	home := t.TempDir()
	mustMkdirAll(t, filepath.Join(home, ".claude", "projects"))
	mustMkdirAll(t, filepath.Join(home, ".grok", "sessions"))

	got := Defaults(home)
	if len(got) != 2 {
		t.Fatalf("got %d sources, want 2: %+v", len(got), got)
	}
	if got[0].Vendor != "claude" {
		t.Fatalf("got[0].Vendor = %q, want claude first", got[0].Vendor)
	}
	want := Source{
		Vendor: "grok", Label: "grok",
		Root: filepath.Join(home, ".grok", "sessions"),
	}
	if got[1] != want {
		t.Fatalf("got[1] = %+v, want %+v", got[1], want)
	}
}

// A Codex install is picked up the same way Grok is, and alongside it:
// the Claude entry stays first, but nothing here asserts Codex is
// second-and-only-second, since a real machine could have both Grok and
// Codex installed.
func TestDefaults_DiscoversCodexWhenPresent(t *testing.T) {
	home := t.TempDir()
	mustMkdirAll(t, filepath.Join(home, ".claude", "projects"))
	mustMkdirAll(t, filepath.Join(home, ".codex", "sessions"))

	got := Defaults(home)
	if len(got) != 2 {
		t.Fatalf("got %d sources, want 2: %+v", len(got), got)
	}
	if got[0].Vendor != "claude" {
		t.Fatalf("got[0].Vendor = %q, want claude first", got[0].Vendor)
	}
	want := Source{
		Vendor: "codex", Label: "codex",
		Root: filepath.Join(home, ".codex", "sessions"),
	}
	if got[1] != want {
		t.Fatalf("got[1] = %+v, want %+v", got[1], want)
	}
}

// No ~/.grok means no Grok source and, critically, no change whatsoever
// for the existing Claude-only user.
func TestDefaults_OmitsGrokWhenAbsent(t *testing.T) {
	home := t.TempDir()
	mustMkdirAll(t, filepath.Join(home, ".claude", "projects"))

	got := Defaults(home)
	if len(got) != 1 || got[0].Vendor != "claude" {
		t.Fatalf("got %+v, want exactly the Claude default", got)
	}
}

// The Claude default root is still required to exist — that contract
// predates sources.toml and guards against a confident silent $0.00.
// An auto-discovered vendor is not: it is only ever added when its
// directory exists, and a race that removes it must not kill the process.
func TestDefaults_ClaudeRootStillRequiredButGrokIsNot(t *testing.T) {
	home := t.TempDir()
	// No .claude at all.
	mustMkdirAll(t, filepath.Join(home, ".grok", "sessions"))
	got := Defaults(home)
	if len(got) != 2 || got[0].Vendor != "claude" {
		t.Fatalf("got %+v, want the Claude default present even when absent on disk", got)
	}
}

// A discovered root nested inside the Claude root is dropped. Load()
// rejects that arrangement outright; a list we assemble ourselves must
// not be able to produce it, or every event in the overlap counts twice.
// Reachable via a CLAUDE_CONFIG_DIR pointing under ~/.grok.
func TestDefaults_DropsAnOverlappingDiscoveredRoot(t *testing.T) {
	home := t.TempDir()
	// Make the Claude root an ancestor of where Grok would be found.
	claudeRoot := filepath.Join(home, ".claude", "projects")
	mustMkdirAll(t, claudeRoot)
	mustMkdirAll(t, filepath.Join(home, ".grok", "sessions"))

	got := DefaultsWithClaudeRoot(home, home)
	if len(got) != 1 || got[0].Vendor != "claude" {
		t.Fatalf("got %+v, want only the Claude entry when the discovered root nests inside it", got)
	}
}

func mustMkdirAll(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestIDIsVendorSlashLabel(t *testing.T) {
	s := Source{Vendor: "claude", Label: "work"}
	if s.ID() != "claude/work" {
		t.Fatalf("ID() = %q", s.ID())
	}
}

func TestLoadParsesAndExpandsTilde(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "work"
root   = "~/.claude/projects"

[[source]]
vendor = "claude"
label  = "personal"
root   = "~/.claude-personal/projects"
`)
	got, err := Load(p, "/home/u")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.Sources) != 2 {
		t.Fatalf("got %d sources", len(got.Sources))
	}
	if got.Sources[0].Root != "/home/u/.claude/projects" {
		t.Fatalf("tilde not expanded: %q", got.Sources[0].Root)
	}
	if got.Sources[1].ID() != "claude/personal" {
		t.Fatalf("ID = %q", got.Sources[1].ID())
	}
}

// A sources.toml naming vendor = "codex" must load, exactly like grok
// did in Phase B before a Codex reader existed.
func TestLoad_AcceptsCodexVendor(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "codex"
label  = "codex"
root   = "~/.codex/sessions"
`)
	got, err := Load(p, "/home/u")
	if err != nil {
		t.Fatalf("codex vendor must be accepted: %v", err)
	}
	if len(got.Sources) != 1 || got.Sources[0].Vendor != "codex" {
		t.Fatalf("got %+v", got.Sources)
	}
}

// The same label under different vendors is a legitimate configuration —
// they are distinct series and must not be rejected.
func TestLoadAllowsSameLabelAcrossVendors(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "personal"
root   = "~/.claude/projects"

[[source]]
vendor = "grok"
label  = "personal"
root   = "~/.grok/sessions"
`)
	if _, err := Load(p, "/home/u"); err != nil {
		t.Fatalf("same label across vendors must be allowed: %v", err)
	}
}

func TestLoadRejectsDuplicateLabelWithinVendor(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "work"
root   = "~/.claude/projects"

[[source]]
vendor = "claude"
label  = "work"
root   = "~/.other/projects"
`)
	_, err := Load(p, "/home/u")
	if err == nil {
		t.Fatal("duplicate (vendor,label) must be rejected — it would silently merge two subscriptions")
	}
	if !strings.Contains(err.Error(), "claude/work") {
		t.Fatalf("error should name the offending series, got %v", err)
	}
}

// Overlapping roots would count every event in the overlap twice.
func TestLoadRejectsNestedRoots(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "outer"
root   = "~/.claude/projects"

[[source]]
vendor = "claude"
label  = "inner"
root   = "~/.claude/projects/sub"
`)
	if _, err := Load(p, "/home/u"); err == nil {
		t.Fatal("nested roots must be rejected — events in the overlap would double-count")
	}
}

func TestLoadRejectsUnknownVendorAndEmptyFields(t *testing.T) {
	for name, body := range map[string]string{
		"unknown vendor": "[[source]]\nvendor = \"openai\"\nlabel = \"x\"\nroot = \"~/x\"\n",
		"empty label":    "[[source]]\nvendor = \"claude\"\nlabel = \"\"\nroot = \"~/x\"\n",
		"empty root":     "[[source]]\nvendor = \"claude\"\nlabel = \"x\"\nroot = \"\"\n",
	} {
		if _, err := Load(write(t, body), "/home/u"); err == nil {
			t.Errorf("%s must be rejected", name)
		}
	}
}

func TestLoadMalformedReturnsError(t *testing.T) {
	if _, err := Load(write(t, "[[source]]\nvendor = = =\n"), "/home/u"); err == nil {
		t.Fatal("malformed TOML must error so a typo is not read as 'no sources'")
	}
}

// A file that parses cleanly but names zero sources (a typo'd table
// name, or a file that is all comments) must be rejected, not silently
// treated as "no sources" — that would report a confident $0.00 with no
// indication anything went wrong. This used to be accepted; see
// final-review.md I1.
func TestLoadEmptyFileYieldsNoSources(t *testing.T) {
	if _, err := Load(write(t, "# nothing here\n"), "/home/u"); err == nil {
		t.Fatal("a file with zero [[source]] entries must be rejected, not read as 'no sources'")
	}
}

// The same rejection must fire for a typo'd table name, not just a
// comment-only file — both decode cleanly to zero entries.
func TestLoadRejectsTypoedTableName(t *testing.T) {
	if _, err := Load(write(t, "[[sources]]\nvendor = \"claude\"\nlabel = \"x\"\nroot = \"~/x\"\n"), "/home/u"); err == nil {
		t.Fatal("a typo'd table name ([[sources]] instead of [[source]]) must be rejected")
	}
}

// "/" is the root of the filesystem and contains all other paths.
// It must be rejected alongside any non-root path.
func TestLoadRejectsRootSlashAsSupersets(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "full-fs"
root   = "/"

[[source]]
vendor = "claude"
label  = "home"
root   = "/foo"
`)
	if _, err := Load(p, "/home/u"); err == nil {
		t.Fatal("root / alongside /foo must be rejected — every event under /foo would double-count")
	}
}

// Paths like /foo/bar and /foo/barbaz do not nest: one is not a prefix of
// the other. They must be allowed.
func TestLoadAllowsSiblingPaths(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "bar"
root   = "/foo/bar"

[[source]]
vendor = "claude"
label  = "barbaz"
root   = "/foo/barbaz"
`)
	if _, err := Load(p, "/home/u"); err != nil {
		t.Fatalf("sibling paths /foo/bar and /foo/barbaz must be allowed (not nested): %v", err)
	}
}

// A bare relative root (neither absolute nor "~"-prefixed) is resolved
// against whatever the process's CWD happens to be at scan time, which
// also lets it defeat checkOverlap's textual comparison against an
// absolute root naming the same tree. It must be rejected outright. See
// final-review.md M2/item 4.
func TestLoadRejectsRelativeRoot(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "rel"
root   = ".claude/projects"
`)
	if _, err := Load(p, "/home/u"); err == nil {
		t.Fatal("a bare relative root must be rejected")
	}
}

// A relative root must be rejected even when checkOverlap would never
// see it — i.e. the check must fire on its own, not merely as a side
// effect of an overlap comparison against another source.
func TestLoadRejectsRelativeRootAlone(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "rel"
root   = "relative/only"
`)
	if _, err := Load(p, "/home/u"); err == nil {
		t.Fatal("a single relative root, with nothing to overlap against, must still be rejected")
	}
}
