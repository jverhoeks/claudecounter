package gitstat

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
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

func TestParseLog(t *testing.T) {
	// Two commits. Commit dates are unix seconds. h1 by me (3 files, one
	// binary), h2 by someone else (1 file).
	raw := "\x00h1\tme@example.com\t1700000000\n" +
		"10\t2\tmain.go\n" +
		"5\t0\tutil.go\n" +
		"-\t-\timage.png\n" +
		"\x00h2\tother@example.com\t1700086400\n" +
		"3\t1\tREADME.md\n"

	commits := parseLog([]byte(raw), "me@example.com")
	if len(commits) != 2 {
		t.Fatalf("got %d commits, want 2", len(commits))
	}

	c1 := commits[0]
	if !c1.Mine {
		t.Error("c1 should be mine")
	}
	if c1.Added != 15 || c1.Deleted != 2 {
		t.Errorf("c1 lines = +%d -%d, want +15 -2", c1.Added, c1.Deleted)
	}
	if c1.Files != 3 {
		t.Errorf("c1 files = %d, want 3 (binary counts as a file)", c1.Files)
	}
	if !c1.Date.Equal(time.Unix(1700000000, 0)) {
		t.Errorf("c1 date = %v", c1.Date)
	}

	c2 := commits[1]
	if c2.Mine {
		t.Error("c2 should not be mine")
	}
	if c2.Files != 1 || c2.Added != 3 {
		t.Errorf("c2 = +%d files %d", c2.Added, c2.Files)
	}
}

func TestCollect_RealRepo(t *testing.T) {
	root := newRepo(t) // one commit by me@example.com (a.txt, +1)
	// second commit, also me
	if err := os.WriteFile(filepath.Join(root, "b.txt"), []byte("x\ny\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "b.txt")
	runGit(t, root, "commit", "-q", "-m", "second")

	commits, err := Collect(root, time.Now().Add(-24*time.Hour), MyEmail(root))
	if err != nil {
		t.Fatal(err)
	}
	if len(commits) != 2 {
		t.Fatalf("got %d commits, want 2", len(commits))
	}
	for _, c := range commits {
		if !c.Mine {
			t.Errorf("commit by %q should be mine", c.Author)
		}
	}
}
