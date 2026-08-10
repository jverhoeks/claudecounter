package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/sources"
)

// TestExplicitRootOverrideMissingIsFatal and
// TestConfiguredAbsentSourceIsSkippedSilently are deliberately pinned
// next to each other: the spec's "a configured root that does not exist
// contributes nothing and is not an error" is about a root LISTED in
// sources.toml (a subscription that legitimately isn't on this
// machine). It is not about a path the user just typed with --root,
// where the only plausible cause is a typo — that must still be fatal,
// exactly as it was before --sources-config existed. Same os.Stat
// check, opposite verdict, depending on how the root got there.
//
// resolveSources/tuiSources call requireRoot (log.Fatalf, i.e.
// os.Exit) only on the --root-override branch, so asserting that side
// needs a subprocess re-exec of the test binary — the standard Go
// pattern for testing an os.Exit path.
func TestExplicitRootOverrideMissingIsFatal(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "does-not-exist")

	if os.Getenv("CC_ROOT_OVERRIDE_CRASH_TEST") == "1" {
		resolveSources("/unused.toml", os.Getenv("CC_MISSING_ROOT"), true, "/unused-home")
		return // must not be reached: resolveSources should have exited
	}

	cmd := exec.Command(os.Args[0], "-test.run=TestExplicitRootOverrideMissingIsFatal")
	cmd.Env = append(os.Environ(), "CC_ROOT_OVERRIDE_CRASH_TEST=1", "CC_MISSING_ROOT="+missing)
	out, err := cmd.CombinedOutput()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.Success() {
		t.Fatalf("expected resolveSources to exit non-zero for a missing --root override; err=%v output=%s", err, out)
	}
	if !strings.Contains(string(out), "claude projects root not found") {
		t.Fatalf("expected the fatal message to name the missing root, got:\n%s", out)
	}
}

// Same case, but the missing root is only tuiSources's problem (the
// live-TUI equivalent of resolveSources) — same fatal contract.
func TestExplicitRootOverrideMissingIsFatalForTUI(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "does-not-exist")

	if os.Getenv("CC_TUI_ROOT_OVERRIDE_CRASH_TEST") == "1" {
		tuiSources("/unused.toml", os.Getenv("CC_MISSING_ROOT"), true, "/unused-home")
		return
	}

	cmd := exec.Command(os.Args[0], "-test.run=TestExplicitRootOverrideMissingIsFatalForTUI")
	cmd.Env = append(os.Environ(), "CC_TUI_ROOT_OVERRIDE_CRASH_TEST=1", "CC_MISSING_ROOT="+missing)
	out, err := cmd.CombinedOutput()
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.Success() {
		t.Fatalf("expected tuiSources to exit non-zero for a missing --root override; err=%v output=%s", err, out)
	}
}

// Contrast case: a root named IN sources.toml (never typed by the
// user) that doesn't exist is silently skipped, not fatal — this is
// TestScanSnapshotSkipsMissingRoot in sources_cli_test.go, exercised
// end to end. Re-asserted here at the resolveSources/tuiSources layer
// so the two behaviours are visibly pinned against the same helpers.
func TestConfiguredAbsentSourceIsSkippedSilently(t *testing.T) {
	home := t.TempDir()
	cfg := filepath.Join(home, "sources.toml")
	missing := filepath.Join(home, "does-not-exist")
	if err := os.WriteFile(cfg, []byte(`
[[source]]
vendor = "claude"
label  = "gone"
root   = "`+missing+`"
`), 0o644); err != nil {
		t.Fatal(err)
	}

	// rootSet=false: this is the configured-list path, not the --root
	// override, so no requireRoot call and no exit.
	srcs := resolveSources(cfg, "unused", false, home)
	if len(srcs) != 1 || srcs[0].Root != missing {
		t.Fatalf("expected the configured (absent) source to load without error, got %+v", srcs)
	}

	tuiSrcs, warn := tuiSources(cfg, "unused", false, home)
	if warn != "" {
		t.Fatalf("a well-formed config naming an absent root must not warn, got %q", warn)
	}
	if len(tuiSrcs) != 1 || tuiSrcs[0].Root != missing {
		t.Fatalf("expected the configured (absent) source to load without error, got %+v", tuiSrcs)
	}
}

// splitReachable must distinguish "absent" (silently skipped, no
// warning) from "present but unreachable" (skipped too, but with a
// warning): an EACCES/ESTALE/... class of stat error must not look
// like a legitimately-absent subscription, or the user sees a
// confident zero for a source that's actually broken right now.
func TestSplitReachableWarnsOnUnreachableRoot(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX permission semantics assumed")
	}
	if os.Geteuid() == 0 {
		t.Skip("root reads through a 0-permission directory; this test needs a real permission wall")
	}

	parent := t.TempDir()
	blocked := filepath.Join(parent, "blocked")
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, 0o000); err != nil {
		t.Fatal(err)
	}
	// Restore permissions before t.TempDir()'s own cleanup tries to
	// remove the tree (cleanups run LIFO, so this one — registered
	// after TempDir's — runs first).
	t.Cleanup(func() { _ = os.Chmod(parent, 0o755) })

	src := sources.Source{Vendor: "claude", Label: "walled", Root: blocked}
	scannable, warnings := splitReachable([]sources.Source{src})
	if len(scannable) != 0 {
		t.Fatalf("an unreachable root must not be scanned, got %+v", scannable)
	}
	if len(warnings) != 1 {
		t.Fatalf("expected exactly one warning, got %+v", warnings)
	}
	if !strings.Contains(warnings[0], "claude/walled") {
		t.Fatalf("warning should identify the source, got %q", warnings[0])
	}
}
