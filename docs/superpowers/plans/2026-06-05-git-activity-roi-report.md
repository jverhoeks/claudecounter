# Git activity & ROI report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-repo report (new TUI screen `4` + `--report` CLI flag) that places Claude spend beside git output (commits, +lines, −lines, files) over a window, bucketed by day/week/month, with `$/commit` and `$/line` ratios.

**Architecture:** Reuse the existing deduped `agg` cells (new `ProjectDaily()` snapshot + a `projectCwd` side map). A new `internal/gitstat` package shells out to `git log` per repo root. A new `internal/report` package joins cost-by-repo with commits-by-repo (pure `Build`) and orchestrates scan+collect (`Scan`, `Gather`). The UI adds a lazily-computed `ModeReport`; `cmd` adds a `--report` one-shot.

**Tech Stack:** Go 1.25, bubbletea/lipgloss (TUI), `os/exec` + system `git`. No new third-party deps.

All commands run from the `tui/` directory unless stated otherwise.

---

### Task 1: `agg` — capture cwd + `ProjectDaily()` snapshot

**Files:**
- Modify: `internal/agg/agg.go`
- Test: `internal/agg/agg_test.go`

- [ ] **Step 1: Write the failing test**

Append to `internal/agg/agg_test.go`:

```go
func mkProjEvent(ts, project, cwd, model string, inTok, outTok uint64) reader.Event {
	t, _ := time.Parse(time.RFC3339, ts)
	return reader.Event{
		Timestamp: t,
		Project:   project,
		Cwd:       cwd,
		Model:     model,
		Usage:     pricing.Usage{InputTokens: inTok, OutputTokens: outTok},
	}
}

func TestProjectDaily_PerProjectPerDayCostAndCwd(t *testing.T) {
	now := time.Date(2026, 4, 24, 15, 0, 0, 0, time.Local)
	a := NewWithClock(priced(), func() time.Time { return now })

	day1 := now.UTC().Format(time.RFC3339)
	day2 := now.Add(-24 * time.Hour).UTC().Format(time.RFC3339)

	// alpha: opus today (1M input = $15) + sonnet today (1M output = $15)
	a.Apply(mkProjEvent(day1, "-Users-me-alpha", "/Users/me/alpha", "claude-opus-4-7", 1_000_000, 0))
	a.Apply(mkProjEvent(day1, "-Users-me-alpha", "/Users/me/alpha", "claude-sonnet-4-6", 0, 1_000_000))
	// alpha: opus yesterday ($15)
	a.Apply(mkProjEvent(day2, "-Users-me-alpha", "/Users/me/alpha", "claude-opus-4-7", 1_000_000, 0))
	// beta: opus today ($15)
	a.Apply(mkProjEvent(day1, "-Users-me-beta", "/Users/me/beta", "claude-opus-4-7", 1_000_000, 0))

	rows := a.ProjectDaily()

	type key struct {
		proj string
		day  string
	}
	got := map[key]float64{}
	cwds := map[string]string{}
	for _, r := range rows {
		got[key{r.Project, r.Day.Format("2006-01-02")}] = r.USD
		cwds[r.Project] = r.Cwd
	}

	today := now.Format("2006-01-02")
	yday := now.Add(-24 * time.Hour).Format("2006-01-02")

	if v := got[key{"-Users-me-alpha", today}]; v != 30 {
		t.Errorf("alpha today USD = %v, want 30", v)
	}
	if v := got[key{"-Users-me-alpha", yday}]; v != 15 {
		t.Errorf("alpha yesterday USD = %v, want 15", v)
	}
	if v := got[key{"-Users-me-beta", today}]; v != 15 {
		t.Errorf("beta today USD = %v, want 15", v)
	}
	if cwds["-Users-me-alpha"] != "/Users/me/alpha" {
		t.Errorf("alpha cwd = %q", cwds["-Users-me-alpha"])
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/agg/ -run TestProjectDaily -v`
Expected: FAIL — `a.ProjectDaily undefined` (compile error).

- [ ] **Step 3: Add the `projectCwd` field and populate it**

In `internal/agg/agg.go`, add a field to the `Aggregator` struct (after `unknownMsgs`):

```go
	projectCwd  map[string]string   // project key -> first non-empty cwd seen
```

In `NewWithClock`, add the map to the returned struct literal:

```go
		projectCwd:  map[string]string{},
```

In `Apply`, after the `k := cellKey{...}` block is built (just before `cur := a.cells[k]`), record the cwd:

```go
	if e.Cwd != "" {
		if _, ok := a.projectCwd[e.Project]; !ok {
			a.projectCwd[e.Project] = e.Cwd
		}
	}
```

- [ ] **Step 4: Add the `ProjDayCost` type and `ProjectDaily()` method**

Append to `internal/agg/agg.go`:

```go
// ProjDayCost is one (project, local-day) cost+token cell, with the
// project's working directory attached so a downstream report can map it
// to a git repo. Cost counts only priced models (matching the rest of the
// UI); tokens count all models.
type ProjDayCost struct {
	Project string
	Cwd     string
	Day     time.Time // local midnight of the day
	USD     float64
	Tokens  TokenCounts
}

// ProjectDaily collapses the accumulated cells into one row per
// (project, local-day) across the aggregator's full range. Pricing is
// applied per (model) cell exactly as Snapshot does, so dollar figures
// match the live views. The range is bounded by whatever was scanned in.
func (a *Aggregator) ProjectDaily() []ProjDayCost {
	a.mu.Lock()
	defer a.mu.Unlock()

	type key struct {
		proj string
		day  civilDay
	}
	type acc struct {
		usd float64
		tok TokenCounts
	}
	m := map[key]*acc{}
	for ck, t := range a.cells {
		kk := key{ck.Project, ck.Day}
		e := m[kk]
		if e == nil {
			e = &acc{}
			m[kk] = e
		}
		if a.pricing.Has(ck.Model) {
			e.usd += a.pricing.Cost(ck.Model, t.ToUsage())
		}
		e.tok = e.tok.Add(t)
	}

	out := make([]ProjDayCost, 0, len(m))
	for kk, v := range m {
		out = append(out, ProjDayCost{
			Project: kk.proj,
			Cwd:     a.projectCwd[kk.proj],
			Day:     time.Date(kk.day.Y, kk.day.M, kk.day.D, 0, 0, 0, 0, time.Local),
			USD:     v.usd,
			Tokens:  v.tok,
		})
	}
	return out
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `go test ./internal/agg/ -run TestProjectDaily -v`
Expected: PASS.

- [ ] **Step 6: Run the full agg suite (no regressions)**

Run: `go test ./internal/agg/`
Expected: `ok` (all existing tests still pass).

- [ ] **Step 7: Commit**

```bash
git add internal/agg/agg.go internal/agg/agg_test.go
git commit -m "feat(agg): add projectCwd map and ProjectDaily() snapshot"
```

---

### Task 2: `gitstat` — `RepoRoot` and `MyEmail`

**Files:**
- Create: `internal/gitstat/gitstat.go`
- Test: `internal/gitstat/gitstat_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/gitstat/gitstat_test.go`:

```go
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/gitstat/ -v`
Expected: FAIL — `RepoRoot`/`MyEmail` undefined (no non-test file yet).

- [ ] **Step 3: Implement `RepoRoot` and `MyEmail`**

Create `internal/gitstat/gitstat.go`:

```go
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/gitstat/ -v`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add internal/gitstat/gitstat.go internal/gitstat/gitstat_test.go
git commit -m "feat(gitstat): add RepoRoot and MyEmail helpers"
```

---

### Task 3: `gitstat` — `Collect` (parse `git log --numstat`)

**Files:**
- Modify: `internal/gitstat/gitstat.go`
- Test: `internal/gitstat/gitstat_test.go`

The log format uses a NUL byte to mark each commit header line, then tab
fields `hash<TAB>authorEmail<TAB>unixCommitDate`, followed by numstat rows
`added<TAB>deleted<TAB>path` (binary files emit `-<TAB>-<TAB>path`).

- [ ] **Step 1: Write the failing test for the pure parser**

Append to `internal/gitstat/gitstat_test.go`:

```go
import (
	// keep existing imports; add:
	"time"
)

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/gitstat/ -run TestParseLog -v`
Expected: FAIL — `parseLog` / `Commit` undefined.

- [ ] **Step 3: Implement `Commit`, `parseLog`, and `Collect`**

Add to the imports block in `internal/gitstat/gitstat.go`:

```go
	"bufio"
	"bytes"
	"strconv"
	"time"
```

Append to `internal/gitstat/gitstat.go`:

```go
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
// accumulate into it until the next NUL (or EOF).
func parseLog(out []byte, myEmail string) []Commit {
	var commits []Commit
	var cur *Commit

	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		if line[0] == '\x00' {
			commits = append(commits, Commit{})
			cur = &commits[len(commits)-1]
			fields := strings.Split(line[1:], "\t")
			if len(fields) >= 3 {
				cur.Author = fields[1]
				cur.Mine = myEmail != "" && fields[1] == myEmail
				if sec, err := strconv.ParseInt(fields[2], 10, 64); err == nil {
					cur.Date = time.Unix(sec, 0)
				}
			}
			continue
		}
		if cur == nil {
			continue
		}
		// numstat row: added<TAB>deleted<TAB>path
		parts := strings.SplitN(line, "\t", 3)
		if len(parts) < 3 {
			continue
		}
		cur.Files++
		if a, err := strconv.Atoi(parts[0]); err == nil {
			cur.Added += a
		}
		if d, err := strconv.Atoi(parts[1]); err == nil {
			cur.Deleted += d
		}
	}
	return commits
}
```

- [ ] **Step 4: Run the parser test to verify it passes**

Run: `go test ./internal/gitstat/ -run TestParseLog -v`
Expected: PASS.

- [ ] **Step 5: Add an integration test for `Collect` against a real repo**

Append to `internal/gitstat/gitstat_test.go`:

```go
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
```

- [ ] **Step 6: Run the gitstat suite to verify it passes**

Run: `go test ./internal/gitstat/ -v`
Expected: PASS (all tests).

- [ ] **Step 7: Commit**

```bash
git add internal/gitstat/gitstat.go internal/gitstat/gitstat_test.go
git commit -m "feat(gitstat): collect non-merge commit stats via git log --numstat"
```

---

### Task 4: `report` — pure `Build` (group by repo, bucket, ratios)

**Files:**
- Create: `internal/report/report.go`
- Test: `internal/report/report_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/report/report_test.go`:

```go
package report

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/gitstat"
)

func day(y int, m time.Month, d int) time.Time {
	return time.Date(y, m, d, 12, 0, 0, 0, time.Local)
}

func TestBuild_BucketsRatiosAndMineVsAll(t *testing.T) {
	inputs := []RepoInput{{
		Root: "/repo/alpha",
		CostDays: []CostDay{
			{Day: day(2026, 6, 1), USD: 8},  // Mon, ISO 2026-W23
			{Day: day(2026, 6, 2), USD: 2},  // Tue, same week
			{Day: day(2026, 6, 8), USD: 5},  // next Mon, 2026-W24
		},
		Commits: []gitstat.Commit{
			{Date: day(2026, 6, 1), Added: 100, Deleted: 0, Files: 2, Mine: true},
			{Date: day(2026, 6, 2), Added: 0, Deleted: 0, Files: 1, Mine: false}, // coworker
			{Date: day(2026, 6, 8), Added: 50, Deleted: 50, Files: 1, Mine: true},
		},
	}}

	reports := Build(inputs, BucketWeek)
	if len(reports) != 1 {
		t.Fatalf("got %d repos, want 1", len(reports))
	}
	r := reports[0]
	if len(r.Buckets) != 2 {
		t.Fatalf("got %d buckets, want 2", len(r.Buckets))
	}

	// Buckets are chronological.
	w23 := r.Buckets[0]
	if w23.USD != 10 {
		t.Errorf("W23 USD = %v, want 10", w23.USD)
	}
	if w23.CommitsMine != 1 || w23.CommitsAll != 2 {
		t.Errorf("W23 commits = mine %d / all %d, want 1/2", w23.CommitsMine, w23.CommitsAll)
	}
	// $/commit uses mine only: 10 / 1 = 10
	if w23.USDPerCommit != 10 {
		t.Errorf("W23 $/commit = %v, want 10", w23.USDPerCommit)
	}
	// $/line uses mine added+deleted: 10 / 100 = 0.1
	if w23.USDPerLine != 0.1 {
		t.Errorf("W23 $/line = %v, want 0.1", w23.USDPerLine)
	}

	if r.Total.USD != 15 {
		t.Errorf("total USD = %v, want 15", r.Total.USD)
	}
	if r.Total.CommitsMine != 2 {
		t.Errorf("total commits mine = %d, want 2", r.Total.CommitsMine)
	}
}

func TestBuild_ZeroCommitsNoDivideByZero(t *testing.T) {
	inputs := []RepoInput{{
		Root:     "/repo/beta",
		CostDays: []CostDay{{Day: day(2026, 6, 1), USD: 12}},
		Commits:  nil,
	}}
	r := Build(inputs, BucketWeek)[0]
	if r.Buckets[0].USDPerCommit != 0 {
		t.Errorf("$/commit with no commits should be 0, got %v", r.Buckets[0].USDPerCommit)
	}
	if r.Buckets[0].USDPerLine != 0 {
		t.Errorf("$/line with no lines should be 0, got %v", r.Buckets[0].USDPerLine)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/report/ -v`
Expected: FAIL — `RepoInput`, `Build`, `BucketWeek` undefined.

- [ ] **Step 3: Implement the types and pure `Build`**

Create `internal/report/report.go`:

```go
// Package report joins Claude spend (per project/day, from agg) with git
// activity (per repo, from gitstat) into per-repo, per-bucket rows. Build
// is pure and unit-tested; Scan and Gather (next task) wrap it with I/O.
package report

import (
	"fmt"
	"sort"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/gitstat"
)

// BucketSize is the time granularity of report rows.
type BucketSize int

const (
	BucketDay BucketSize = iota
	BucketWeek
	BucketMonth
)

// CostDay is one day's Claude cost attributed to a repo (summed across all
// project keys that map to the repo root).
type CostDay struct {
	Day time.Time
	USD float64
}

// RepoInput is the pre-grouped cost + commits for a single repo root.
type RepoInput struct {
	Root     string
	CostDays []CostDay
	Commits  []gitstat.Commit
}

// Bucket is one (repo, time-bucket) row. Raw components are primary; the
// ratios are derived garnish and are 0 when their denominator is 0.
type Bucket struct {
	Label        string
	Sort         string // sortable key (same as Label for our formats)
	USD          float64
	CommitsMine  int
	CommitsAll   int
	Added        int // mine
	Deleted      int // mine
	Files        int // mine
	USDPerCommit float64
	USDPerLine   float64
}

// RepoReport is all buckets for one repo plus the window total.
type RepoReport struct {
	Root    string
	Buckets []Bucket
	Total   Bucket
}

// bucketLabel returns the (label, sortKey) for t at the given granularity.
func bucketLabel(t time.Time, size BucketSize) (string, string) {
	lt := t.Local()
	switch size {
	case BucketDay:
		s := lt.Format("2006-01-02")
		return s, s
	case BucketMonth:
		s := lt.Format("2006-01")
		return s, s
	default: // BucketWeek
		y, w := lt.ISOWeek()
		s := fmt.Sprintf("%04d-W%02d", y, w)
		return s, s
	}
}

func ratios(b *Bucket) {
	if b.CommitsMine > 0 {
		b.USDPerCommit = b.USD / float64(b.CommitsMine)
	}
	if lines := b.Added + b.Deleted; lines > 0 {
		b.USDPerLine = b.USD / float64(lines)
	}
}

// Build joins each repo's cost-days and commits into chronological buckets,
// computing ratios from "mine" commits/lines only. Repos are returned
// sorted by descending total spend.
func Build(inputs []RepoInput, size BucketSize) []RepoReport {
	var out []RepoReport
	for _, in := range inputs {
		byLabel := map[string]*Bucket{}
		get := func(t time.Time) *Bucket {
			label, sortKey := bucketLabel(t, size)
			b := byLabel[label]
			if b == nil {
				b = &Bucket{Label: label, Sort: sortKey}
				byLabel[label] = b
			}
			return b
		}

		total := Bucket{Label: "total"}
		for _, c := range in.CostDays {
			get(c.Day).USD += c.USD
			total.USD += c.USD
		}
		for _, c := range in.Commits {
			b := get(c.Date)
			b.CommitsAll++
			total.CommitsAll++
			if c.Mine {
				b.CommitsMine++
				b.Added += c.Added
				b.Deleted += c.Deleted
				b.Files += c.Files
				total.CommitsMine++
				total.Added += c.Added
				total.Deleted += c.Deleted
				total.Files += c.Files
			}
		}

		buckets := make([]Bucket, 0, len(byLabel))
		for _, b := range byLabel {
			ratios(b)
			buckets = append(buckets, *b)
		}
		sort.Slice(buckets, func(i, j int) bool { return buckets[i].Sort < buckets[j].Sort })
		ratios(&total)

		out = append(out, RepoReport{Root: in.Root, Buckets: buckets, Total: total})
	}

	sort.Slice(out, func(i, j int) bool { return out[i].Total.USD > out[j].Total.USD })
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/report/ -v`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add internal/report/report.go internal/report/report_test.go
git commit -m "feat(report): pure Build joining cost and commits into ratio buckets"
```

---

### Task 5: `report` — `Scan` + `Gather` orchestration (I/O)

**Files:**
- Create: `internal/report/gather.go`
- Test: `internal/report/gather_test.go`

`Scan` does a wide JSONL scan into a fresh aggregator and returns
`[]agg.ProjDayCost`. `Gather` groups those by repo root (via `gitstat`),
collects commits per repo, and calls `Build`. `Gather` is tested with a real
temp repo; `Scan` is thin and exercised via the CLI in Task 7.

- [ ] **Step 1: Write the failing test**

Create `internal/report/gather_test.go`:

```go
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
	}

	reports, skipped := Gather(costs, BucketDay, time.Now().Add(-48*time.Hour))
	if len(reports) != 1 {
		t.Fatalf("got %d repos, want 1 (non-repo dropped)", len(reports))
	}
	if reports[0].Total.USD != 10 {
		t.Errorf("merged repo USD = %v, want 10", reports[0].Total.USD)
	}
	if skipped != 1 {
		t.Errorf("skipped = %d, want 1", skipped)
	}
	// The repo has 1 commit by me in the window.
	if reports[0].Total.CommitsMine != 1 {
		t.Errorf("commits mine = %d, want 1", reports[0].Total.CommitsMine)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/report/ -run TestGather -v`
Expected: FAIL — `Gather` undefined.

- [ ] **Step 3: Implement `Scan` and `Gather`**

Create `internal/report/gather.go`:

```go
package report

import (
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/gitstat"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/reader"
)

// ScanStats reports parse/dedupe counters from a wide scan.
type ScanStats struct {
	ParseErrors int
	Dupes       int
}

// Scan reads every transcript under root modified at/after notBefore into a
// fresh aggregator and returns the per-project per-day cost rows. It does
// not touch the live aggregator, so the report can use a wider window than
// the live views without disturbing them.
func Scan(root string, table pricing.Table, notBefore time.Time) ([]agg.ProjDayCost, ScanStats, error) {
	evCh := make(chan reader.Event, 1024)
	r := reader.New(evCh)
	a := agg.New(table)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for e := range evCh {
			a.Apply(e)
		}
	}()

	if err := r.InitialScan(root, notBefore); err != nil {
		close(evCh)
		<-done
		return nil, ScanStats{}, err
	}
	close(evCh)
	<-done

	return a.ProjectDaily(), ScanStats{ParseErrors: r.ParseErrors(), Dupes: a.Dupes()}, nil
}

// Gather groups cost rows by git repo root, collects each repo's commits
// since `since`, and builds the report. Cost rows whose cwd is not inside a
// git work tree are dropped; skipped is their count. Repos sharing a root
// (worktrees/subdirs) merge into one.
func Gather(costs []agg.ProjDayCost, size BucketSize, since time.Time) (reports []RepoReport, skipped int) {
	// cwd -> repo root, memoised so we run rev-parse once per distinct cwd.
	rootOf := map[string]string{}
	resolve := func(cwd string) (string, bool) {
		if r, seen := rootOf[cwd]; seen {
			return r, r != ""
		}
		r, ok := gitstat.RepoRoot(cwd)
		if !ok {
			rootOf[cwd] = ""
			return "", false
		}
		rootOf[cwd] = r
		return r, true
	}

	costByRoot := map[string][]CostDay{}
	for _, c := range costs {
		root, ok := resolve(c.Cwd)
		if !ok {
			skipped++
			continue
		}
		costByRoot[root] = append(costByRoot[root], CostDay{Day: c.Day, USD: c.USD})
	}

	inputs := make([]RepoInput, 0, len(costByRoot))
	for root, days := range costByRoot {
		commits, err := gitstat.Collect(root, since, gitstat.MyEmail(root))
		if err != nil {
			// A repo that errors on log still appears with cost and no commits.
			commits = nil
		}
		inputs = append(inputs, RepoInput{Root: root, CostDays: days, Commits: commits})
	}

	return Build(inputs, size), skipped
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/report/ -run TestGather -v`
Expected: PASS.

- [ ] **Step 5: Run the full report suite**

Run: `go test ./internal/report/`
Expected: `ok`.

- [ ] **Step 6: Commit**

```bash
git add internal/report/gather.go internal/report/gather_test.go
git commit -m "feat(report): Scan (wide JSONL) and Gather (group by repo root)"
```

---

### Task 6: `ui` — render + lazy `ModeReport` screen

**Files:**
- Create: `internal/ui/view_report.go`
- Modify: `internal/ui/model.go`
- Test: `internal/ui/view_report_test.go`

The render function is pure (`[]report.RepoReport` → string) and tested. The
model wiring (key `4`, spinner, background `Cmd`, `ReportMsg`) is added but
the background command itself (which needs root/table) is supplied by `cmd`
in Task 7 via a stored closure, so `ui` does not import `reader`/`pricing`.

- [ ] **Step 1: Write the failing test for the renderer**

Create `internal/ui/view_report_test.go`:

```go
package ui

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

func TestViewReport_RendersRawComponents(t *testing.T) {
	reports := []report.RepoReport{{
		Root: "/Users/me/git/alpha",
		Buckets: []report.Bucket{{
			Label: "2026-W23", USD: 10, CommitsMine: 3, CommitsAll: 5,
			Added: 120, Deleted: 40, Files: 8, USDPerCommit: 3.33, USDPerLine: 0.0625,
		}},
		Total: report.Bucket{
			USD: 10, CommitsMine: 3, CommitsAll: 5, Added: 120, Deleted: 40, Files: 8,
		},
	}}

	out := viewReport(reports, 90, report.BucketWeek, 0, false)

	for _, want := range []string{"alpha", "2026-W23", "3 / 5", "+120", "-40"} {
		if !strings.Contains(out, want) {
			t.Errorf("render missing %q\n---\n%s", want, out)
		}
	}
}

func TestViewReport_Empty(t *testing.T) {
	out := viewReport(nil, 90, report.BucketWeek, 0, false)
	if !strings.Contains(out, "No git activity") {
		t.Errorf("empty render should explain emptiness, got:\n%s", out)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ui/ -run TestViewReport -v`
Expected: FAIL — `viewReport` undefined.

- [ ] **Step 3: Implement `viewReport`**

Create `internal/ui/view_report.go`:

```go
package ui

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

func bucketName(size report.BucketSize) string {
	switch size {
	case report.BucketDay:
		return "day"
	case report.BucketMonth:
		return "month"
	default:
		return "week"
	}
}

// fmtRatio renders a ratio as a dollar figure, or "—" when zero (no
// denominator) so empty buckets don't read as "free".
func fmtRatio(v float64) string {
	if v <= 0 {
		return "—"
	}
	return FormatUSD(v)
}

// viewReport renders the git-activity report. days/size describe the active
// window; skipped is the count of non-repo projects dropped; loading shows
// the spinner line instead of the table.
func viewReport(reports []report.RepoReport, days int, size report.BucketSize, skipped int, loading bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n",
		styleHead.Render(fmt.Sprintf("Git activity & ROI — last %d days, by %s", days, bucketName(size))))
	b.WriteString(styleDim.Render("d/w/m: bucket   [/]: window   ratios are temporal, not causal") + "\n\n")

	if loading {
		b.WriteString("  collecting git stats…\n")
		return b.String()
	}
	if len(reports) == 0 {
		b.WriteString("  No git activity found for projects in this window.\n")
		return b.String()
	}

	for _, r := range reports {
		name := filepath.Base(r.Root)
		fmt.Fprintf(&b, "%s  %s · %d commits (mine) / %d all · %s%d %s%d · %d files\n",
			styleHead.Render(name),
			styleMoney.Render(FormatUSD(r.Total.USD)),
			r.Total.CommitsMine, r.Total.CommitsAll,
			styleDim.Render("+"), r.Total.Added,
			styleDim.Render("-"), r.Total.Deleted,
			r.Total.Files,
		)
		fmt.Fprintf(&b, "  %-12s %9s  %12s  %8s %8s %6s  %9s %9s\n",
			"bucket", "$", "commits", "+lines", "-lines", "files", "$/commit", "$/line")
		for _, bk := range r.Buckets {
			fmt.Fprintf(&b, "  %-12s %9s  %12s  %8d %8d %6d  %9s %9s\n",
				bk.Label,
				FormatUSD(bk.USD),
				fmt.Sprintf("%d / %d", bk.CommitsMine, bk.CommitsAll),
				bk.Added, bk.Deleted, bk.Files,
				fmtRatio(bk.USDPerCommit), fmtRatio(bk.USDPerLine),
			)
		}
		b.WriteString("\n")
	}

	if skipped > 0 {
		b.WriteString(styleDim.Render(fmt.Sprintf("(%d non-git projects skipped)", skipped)) + "\n")
	}
	return b.String()
}
```

- [ ] **Step 4: Run renderer test to verify it passes**

Run: `go test ./internal/ui/ -run TestViewReport -v`
Expected: PASS (both tests).

- [ ] **Step 5: Wire `ModeReport` into the model**

In `internal/ui/model.go`:

(a) Add the mode to the enum:

```go
const (
	ModeMinimal ViewMode = iota
	ModeSplit
	ModeFull
	ModeReport
)
```

(b) Add messages and fields. After the `BackfillDoneMsg` type, add:

```go
// ReportMsg delivers a freshly gathered git-activity report (or an error).
type ReportMsg struct {
	Reports []report.RepoReport
	Skipped int
	Days    int
	Bucket  report.BucketSize
	Err     error
}

// ReportFunc runs a wide scan + git collect for the given window/bucket and
// returns a ReportMsg. It is injected by main so ui needn't import reader.
type ReportFunc func(days int, size report.BucketSize) ReportMsg
```

Add the import:

```go
	"github.com/jverhoeks/claudecounter/tui/internal/report"
```

Add fields to the `Model` struct:

```go
	reportFn       ReportFunc
	reports        []report.RepoReport
	reportSkipped  int
	reportDays     int
	reportBucket   report.BucketSize
	reportErr      error
	reportLoading  bool
	reportLoaded   bool
```

(c) Add a setter and adjust `NewModel`. Add after `NewModel`:

```go
// SetReportFunc injects the report generator (called by main).
func (m *Model) SetReportFunc(fn ReportFunc) { m.reportFn = fn }
```

In `NewModel`, set sensible report defaults in the returned literal:

```go
		reportDays:   90,
		reportBucket: report.BucketWeek,
```

(d) Add a command helper at the end of `model.go`:

```go
func (m Model) runReportCmd() tea.Cmd {
	fn := m.reportFn
	days := m.reportDays
	size := m.reportBucket
	if fn == nil {
		return nil
	}
	return func() tea.Msg { return fn(days, size) }
}
```

(e) In `Update`, handle the new key, recompute keys, and the message. Replace the `case "tab":` line's body and add cases inside the `tea.KeyMsg` switch:

```go
		case "4":
			m.mode = ModeReport
			if !m.reportLoaded && !m.reportLoading {
				m.reportLoading = true
				return m, m.runReportCmd()
			}
		case "tab":
			m.mode = (m.mode + 1) % 4
			if m.mode == ModeReport && !m.reportLoaded && !m.reportLoading {
				m.reportLoading = true
				return m, m.runReportCmd()
			}
		case "d", "w", "m":
			if m.mode == ModeReport {
				switch msg.String() {
				case "d":
					m.reportBucket = report.BucketDay
				case "w":
					m.reportBucket = report.BucketWeek
				case "m":
					m.reportBucket = report.BucketMonth
				}
				m.reportLoading = true
				return m, m.runReportCmd()
			}
		case "[", "]":
			if m.mode == ModeReport {
				windows := []int{30, 90, 180}
				idx := 1
				for i, w := range windows {
					if w == m.reportDays {
						idx = i
					}
				}
				if msg.String() == "[" && idx > 0 {
					idx--
				}
				if msg.String() == "]" && idx < len(windows)-1 {
					idx++
				}
				m.reportDays = windows[idx]
				m.reportLoading = true
				return m, m.runReportCmd()
			}
```

Add a `case` for the message alongside the other `case` blocks in `Update`:

```go
	case ReportMsg:
		m.reportLoading = false
		m.reportLoaded = true
		m.reports = msg.Reports
		m.reportSkipped = msg.Skipped
		m.reportDays = msg.Days
		m.reportBucket = msg.Bucket
		m.reportErr = msg.Err
```

(f) In `View`, add the new mode to the switch and update the footer hint:

```go
	case ModeReport:
		if m.reportErr != nil {
			body = "report error: " + m.reportErr.Error()
		} else {
			body = viewReport(m.reports, m.reportDays, m.reportBucket, m.reportSkipped, m.reportLoading)
		}
```

Change the footer line to mention the new view:

```go
	footer := "1/2/3/4 or Tab: switch view   q: quit"
```

- [ ] **Step 6: Build and run the UI suite**

Run: `go build ./... && go test ./internal/ui/`
Expected: build succeeds; `ok` for ui tests.

- [ ] **Step 7: Commit**

```bash
git add internal/ui/view_report.go internal/ui/view_report_test.go internal/ui/model.go
git commit -m "feat(ui): lazy ModeReport screen (key 4) with window/bucket controls"
```

---

### Task 7: `cmd` — `--report` flag + inject the TUI report function

**Files:**
- Modify: `cmd/claudecounter/main.go`
- Test: `cmd/claudecounter/report_cli_test.go`

- [ ] **Step 1: Write the failing test for the bucket-flag parser**

Create `cmd/claudecounter/report_cli_test.go`:

```go
package main

import (
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/report"
)

func TestParseBucket(t *testing.T) {
	cases := map[string]report.BucketSize{
		"day":   report.BucketDay,
		"week":  report.BucketWeek,
		"month": report.BucketMonth,
		"":      report.BucketWeek, // default
		"bogus": report.BucketWeek, // fallback
	}
	for in, want := range cases {
		if got := parseBucket(in); got != want {
			t.Errorf("parseBucket(%q) = %v, want %v", in, got, want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./cmd/claudecounter/ -run TestParseBucket -v`
Expected: FAIL — `parseBucket` undefined.

- [ ] **Step 3: Add flags, `parseBucket`, `reportSince`, `runReport`, and wire the TUI**

In `cmd/claudecounter/main.go`, add the import (`report` is the only new one
`main` needs directly — it reaches `gitstat` transitively):

```go
	"github.com/jverhoeks/claudecounter/tui/internal/report"
```

In `main()`, add flags after the `once` flag:

```go
	reportFlag := flag.Bool("report", false, "scan once, print the git-activity report, and exit")
	days := flag.Int("days", 90, "report window in days (30/90/180)")
	bucket := flag.String("bucket", "week", "report bucket: day|week|month")
```

After the existing `if *once { … }` block, add:

```go
	if *reportFlag {
		runReport(*root, table, *days, parseBucket(*bucket))
		return
	}
```

Append these functions to `main.go`:

```go
func parseBucket(s string) report.BucketSize {
	switch s {
	case "day":
		return report.BucketDay
	case "month":
		return report.BucketMonth
	default:
		return report.BucketWeek
	}
}

// reportSince converts a day-count window into the scan/commit cutoff.
func reportSince(now time.Time, days int) time.Time {
	if days <= 0 {
		days = 90
	}
	return now.AddDate(0, 0, -days)
}

// gatherReport runs the wide scan + git collect for a window. Shared by the
// CLI and the TUI's injected ReportFunc.
func gatherReport(root string, table pricing.Table, days int, size report.BucketSize) ([]report.RepoReport, int, error) {
	since := reportSince(time.Now().Local(), days)
	costs, _, err := report.Scan(root, table, since)
	if err != nil {
		return nil, 0, err
	}
	reports, skipped := report.Gather(costs, size, since)
	return reports, skipped, nil
}

func runReport(root string, table pricing.Table, days int, size report.BucketSize) {
	fmt.Fprintf(os.Stderr, "scanning %s (last %d days) …\n", root, days)
	reports, skipped, err := gatherReport(root, table, days, size)
	if err != nil {
		log.Fatalf("report scan: %v", err)
	}
	if len(reports) == 0 {
		fmt.Println("No git activity found for projects in this window.")
		return
	}
	for _, r := range reports {
		fmt.Printf("\n%s   %s · %d commits (mine) / %d all · +%d -%d · %d files\n",
			r.Root, ui.FormatUSD(r.Total.USD),
			r.Total.CommitsMine, r.Total.CommitsAll,
			r.Total.Added, r.Total.Deleted, r.Total.Files)
		fmt.Printf("  %-12s %10s %14s %9s %9s %7s %10s %10s\n",
			"bucket", "$", "commits(m/all)", "+lines", "-lines", "files", "$/commit", "$/line")
		for _, bk := range r.Buckets {
			pc, pl := "—", "—"
			if bk.USDPerCommit > 0 {
				pc = ui.FormatUSD(bk.USDPerCommit)
			}
			if bk.USDPerLine > 0 {
				pl = ui.FormatUSD(bk.USDPerLine)
			}
			fmt.Printf("  %-12s %10s %14s %9d %9d %7d %10s %10s\n",
				bk.Label, ui.FormatUSD(bk.USD),
				fmt.Sprintf("%d/%d", bk.CommitsMine, bk.CommitsAll),
				bk.Added, bk.Deleted, bk.Files, pc, pl)
		}
	}
	if skipped > 0 {
		fmt.Printf("\n(%d non-git projects skipped)\n", skipped)
	}
}
```

In `runTUI`, after `m := ui.NewModel()`, inject the report function:

```go
	m.SetReportFunc(func(days int, size report.BucketSize) ui.ReportMsg {
		reports, skipped, err := gatherReport(root, table, days, size)
		return ui.ReportMsg{
			Reports: reports, Skipped: skipped,
			Days: days, Bucket: size, Err: err,
		}
	})
```

Because `SetReportFunc` has a pointer receiver, change the model
construction so the injection mutates the value passed to bubbletea:

```go
	m := ui.NewModel()
	m.SetReportFunc(func(days int, size report.BucketSize) ui.ReportMsg {
		reports, skipped, err := gatherReport(root, table, days, size)
		return ui.ReportMsg{Reports: reports, Skipped: skipped, Days: days, Bucket: size, Err: err}
	})
	prog := tea.NewProgram(m, tea.WithAltScreen())
```

(`NewModel` returns a value; calling the pointer method on the addressable
local `m` before passing it to `tea.NewProgram` is correct.)

- [ ] **Step 4: Run the parser test to verify it passes**

Run: `go test ./cmd/claudecounter/ -run TestParseBucket -v`
Expected: PASS.

- [ ] **Step 5: Build everything and run the full suite**

Run: `go build ./... && go test ./...`
Expected: build succeeds; all packages report `ok`.

- [ ] **Step 6: Smoke-test the CLI against real data**

Run: `go run ./cmd/claudecounter --report --days 30 --bucket week`
Expected: prints one block per git repo among your Claude projects, with
per-week `$`, commit counts, +/− lines, files, and `$/commit` / `$/line`
columns; ends with a "(N non-git projects skipped)" line. (Exact numbers
depend on your data.)

- [ ] **Step 7: Commit**

```bash
git add cmd/claudecounter/main.go cmd/claudecounter/report_cli_test.go
git commit -m "feat(cmd): --report one-shot and inject report fn into the TUI"
```

---

### Task 8: Manual TUI verification + README

**Files:**
- Modify: `README.md` (and `tui/README.md` if it documents views/flags)

- [ ] **Step 1: Manually verify the TUI screen**

Run: `go run ./cmd/claudecounter`
Then: press `4`. Expected: a "collecting git stats…" line briefly, then the
per-repo report. Press `d` / `w` / `m` to change bucket; press `[` / `]` to
change the window (30↔90↔180); press `1`/`2`/`3` to return to cost views;
`q` to quit. Confirm switching back to `4` is instant after the first load
(unless you changed window/bucket).

- [ ] **Step 2: Document the new view and flag**

In the repo `README.md` view/usage section, add a row/line documenting:
- TUI: key `4` — "Git activity & ROI: spend vs. commits/lines/files per
  repo, with $/commit and $/line; `d`/`w`/`m` bucket, `[`/`]` window."
- CLI: `claudecounter --report [--days 30|90|180] [--bucket day|week|month]`.

Include the honesty caveat in one sentence: ratios are a temporal
juxtaposition (no commit↔spend link exists in the data), `+`/`−` lines are
shown separately, merge commits are excluded, and `$/commit` uses your own
commits (per-repo `user.email`) while the all-authors count is shown
alongside.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document the git-activity & ROI report (view 4 / --report)"
```

---

## Self-Review notes

- **Spec coverage:** windows 30/90/180 (Tasks 5/7 `reportSince`, `[`/`]`), buckets day/week/month (Task 4 `bucketLabel`, `d`/`w`/`m`), per-repo grouping incl. worktrees (Task 5 `Gather`), non-repo skip (Task 5), my-vs-all commits (Tasks 3/4), `$/commit` & `$/line` from mine (Task 4 `ratios`), +/− separate & no-net & `--no-merges` (Tasks 3/4/6), lazy TUI compute (Task 6), `--report` CLI (Task 7), PR/MR explicitly absent (v2). Covered.
- **No placeholders:** every code step is complete and compiles against the real APIs (`pricing.Table.Cost/Has`, `agg.New`, `reader.New`/`InitialScan`, `ui.FormatUSD`, lipgloss styles `styleHead`/`styleMoney`/`styleDim`).
- **Type consistency:** `report.BucketSize`/`BucketDay/Week/Month`, `report.RepoReport`/`Bucket`/`CostDay`/`RepoInput`, `gitstat.Commit`/`Collect`/`RepoRoot`/`MyEmail`, `agg.ProjDayCost`/`ProjectDaily`, `ui.ReportMsg`/`ReportFunc`/`SetReportFunc`/`viewReport` are used identically everywhere they appear.
