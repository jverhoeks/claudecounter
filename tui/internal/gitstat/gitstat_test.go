package gitstat

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// newRepo creates a throwaway git repo with one commit and returns its root.
func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	runGit(t, dir, "init", "-q")
	runGit(t, dir, "config", "user.email", "me@example.com")
	runGit(t, dir, "config", "user.name", "Me")
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, dir, "add", "a.txt")
	runGit(t, dir, "commit", "-q", "-m", "init")
	return dir
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

func TestRepoRoot(t *testing.T) {
	root := newRepo(t)
	sub := filepath.Join(root, "nested")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatal(err)
	}

	got, ok := RepoRoot(sub)
	if !ok {
		t.Fatal("expected sub dir to resolve to a repo root")
	}
	// macOS TempDir may be symlinked (/var -> /private/var); compare resolved.
	gotResolved, _ := filepath.EvalSymlinks(got)
	wantResolved, _ := filepath.EvalSymlinks(root)
	if gotResolved != wantResolved {
		t.Errorf("RepoRoot = %q, want %q", gotResolved, wantResolved)
	}

	if _, ok := RepoRoot(t.TempDir()); ok {
		t.Error("a non-repo dir should return ok=false")
	}
}

func TestMyEmail(t *testing.T) {
	root := newRepo(t)
	if got := MyEmail(root); got != "me@example.com" {
		t.Errorf("MyEmail = %q, want me@example.com", got)
	}
}
