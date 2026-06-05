// Package gitstat shells out to the system `git` binary to collect
// per-repository commit statistics. It is the only I/O boundary for the
// git-activity report; everything downstream operates on its plain structs.
package gitstat

import (
	"bufio"
	"bytes"
	"os/exec"
	"strconv"
	"strings"
	"time"
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

// Commit is one non-merge commit's contribution within the window.
// Added/Deleted/Files are summed across the commit's files; binary files
// contribute to Files but add 0 lines.
type Commit struct {
	Date    time.Time // commit date (local zone)
	Author  string    // author email
	Added   int
	Deleted int
	Files   int
	Mine    bool // Author == repo-local user.email
}

// Collect runs `git log` over [since, now] in root and returns one Commit
// per non-merge commit. myEmail marks commits as Mine; pass MyEmail(root).
func Collect(root string, since time.Time, myEmail string) ([]Commit, error) {
	cmd := exec.Command("git", "-C", root, "log",
		"--no-merges",
		"--numstat",
		"--date=unix",
		"--since="+since.Format(time.RFC3339),
		// %cd = committer date, matching --since and the cost day-buckets
		// (vs author date which drifts on rebase).
		"--pretty=format:%x00%H%x09%ae%x09%cd",
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	return parseLog(out, myEmail), nil
}

// parseLog is the pure parser for the format Collect requests. A line
// beginning with a NUL byte starts a new commit; subsequent numstat lines
// accumulate into it until the next NUL (or EOF). The in-progress commit is
// held in a standalone *pending and appended by value once it's complete, so
// no pointer ever aliases into the (possibly reallocated) commits slice.
func parseLog(out []byte, myEmail string) []Commit {
	var commits []Commit
	var pending *Commit

	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		if line[0] == '\x00' {
			if pending != nil {
				commits = append(commits, *pending)
			}
			pending = &Commit{}
			fields := strings.Split(line[1:], "\t")
			if len(fields) >= 3 {
				pending.Author = fields[1]
				pending.Mine = myEmail != "" && fields[1] == myEmail
				if sec, err := strconv.ParseInt(fields[2], 10, 64); err == nil {
					pending.Date = time.Unix(sec, 0)
				}
			}
			continue
		}
		if pending == nil {
			continue
		}
		// numstat row: added<TAB>deleted<TAB>path
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 3 {
			continue
		}
		pending.Files++
		// Binary files show "-"; Atoi errors and the line count stays 0.
		if a, err := strconv.Atoi(parts[0]); err == nil {
			pending.Added += a
		}
		if d, err := strconv.Atoi(parts[1]); err == nil {
			pending.Deleted += d
		}
	}
	if pending != nil {
		commits = append(commits, *pending)
	}
	return commits
}
