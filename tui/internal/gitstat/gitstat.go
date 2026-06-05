// Package gitstat shells out to the system `git` binary to collect
// per-repository commit statistics. It is the only I/O boundary for the
// git-activity report; everything downstream operates on its plain structs.
package gitstat

import (
	"os/exec"
	"strings"
)

// RepoRoot resolves the toplevel directory of the repo containing cwd.
// ok is false when cwd is not inside a git work tree (e.g. a temp folder),
// in which case the caller should skip it silently.
func RepoRoot(cwd string) (root string, ok bool) {
	cmd := exec.Command("git", "-C", cwd, "rev-parse", "--show-toplevel")
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	root = strings.TrimSpace(string(out))
	return root, root != ""
}

// MyEmail returns the repo-local user.email, or "" if unset. This is the
// per-repo identity used to mark commits as "mine" for the ratio
// denominators — deliberately the repo-local value, not the global one, so
// a team repo doesn't fold coworkers into your cost-per-commit.
func MyEmail(root string) string {
	cmd := exec.Command("git", "-C", root, "config", "user.email")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
