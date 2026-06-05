package report

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, args := range [][]string{
		{"init", "-q"},
		{"config", "user.email", "me@example.com"},
		{"config", "user.name", "Me"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("1\n2\n3\n"), 0o644)
	for _, args := range [][]string{
		{"add", "a.txt"},
		{"commit", "-q", "-m", "init"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	return dir
}

func TestGather_GroupsCostByRepoRootAndSkipsNonRepos(t *testing.T) {
	repo := newRepo(t)
	sub := filepath.Join(repo, "pkg")
	os.MkdirAll(sub, 0o755)
	nonRepo := t.TempDir()

	today := time.Now()
	costs := []agg.ProjDayCost{
		// two project keys under the same repo (root + subdir) must merge
		{Project: "p1", Cwd: repo, Day: today, USD: 6},
		{Project: "p2", Cwd: sub, Day: today, USD: 4},
		// a non-repo cwd must be dropped
		{Project: "p3", Cwd: nonRepo, Day: today, USD: 99},
		// a cost dated well before the window must be clamped out: commits
		// are bounded by `git log --since`, so out-of-window spend would
		// inflate the ratio numerator with no commits to match.
		{Project: "p1", Cwd: repo, Day: time.Now().AddDate(0, 0, -90), USD: 50},
	}

	reports, skipped := Gather(costs, BucketDay, time.Now().Add(-48*time.Hour))
	if len(reports) != 1 {
		t.Fatalf("got %d repos, want 1 (non-repo dropped)", len(reports))
	}
	// Only the two in-window rows merge (6+4); the $50 row dated 90 days
	// before the window must be clamped out, so total stays 10 (not 60).
	if reports[0].Total.USD != 10 {
		t.Errorf("merged repo USD = %v, want 10 (out-of-window $50 must be clamped)", reports[0].Total.USD)
	}
	if skipped != 1 {
		t.Errorf("skipped = %d, want 1", skipped)
	}
	// The repo has 1 commit by me in the window.
	if reports[0].Total.CommitsMine != 1 {
		t.Errorf("commits mine = %d, want 1", reports[0].Total.CommitsMine)
	}
}
