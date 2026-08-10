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
