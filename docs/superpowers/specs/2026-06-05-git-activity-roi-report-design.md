# Git activity & ROI report — design

**Date:** 2026-06-05
**Status:** Approved (pending spec review)
**Surface:** New view + CLI flag in the existing Go TUI (`tui/`). No new binary.

## Summary

Add a report that, per git-repo project, places what you **spent** (Claude $)
beside what you **produced** (commits, +lines, −lines, files) over a
30/90/180-day window, bucketed by day/week/month. It also derives the
`$/commit` and `$/line` ratios — shown as secondary garnish, not headline
numbers.

### Why the ratios are garnish, not measurements

There is **no commit↔spend linkage anywhere in the JSONL** — the transcripts
only carry token `usage`. Attribution is therefore purely **temporal**: "cost
in project P during window W" next to "git activity in repo(P) during window
W". Claude spend often produces no commits (debugging, reading, exploration),
and commits happen without Claude. So the design shows the **raw components
prominently** and treats ratios as a derived convenience. The raw components
are the trustworthy part.

### Hardening baked into v1

- `git log --no-merges` — merge commits don't represent authored work.
- **+lines and −lines are always shown separately, never net.** One
  `go.sum` / `package-lock.json` / generated-file commit is +30k −10k lines
  and would otherwise make a day look "incredibly cheap".
- Commits are bucketed by **commit-date in local time**, matching how `agg`
  buckets cost by local calendar day (author-date would drift).

## Decisions

| Decision | Choice |
|---|---|
| **Author filter** | Ratios use **my commits only** (per-repo `git config user.email`). The all-authors commit count is **also displayed** alongside, so team vs. solo is visible. |
| **PR/MR** | **Deferred to v2.** v1 is local `git log` only — zero network, zero auth. |
| **Generated-file exclusion** | Out of scope for v1 (possible optional pathspec flag later). |
| **Grouping** | By **repo root** (`git rev-parse --show-toplevel`). Worktrees/subdirs that fan into multiple project keys collapse into one repo so the denominator lines up. |
| **Non-repo projects** | Skipped (the temp-folder project, `~/.claude`, etc. are not repos). |

## Surfaces

Both surfaces reuse the same core; only presentation differs.

1. **CLI flag** — `claudecounter --report --days 90 --bucket week`
   - One-shot: scan → collect git → print text table → exit.
   - Sits beside the existing `--once`.
   - `--days` ∈ {30, 90, 180} (default 90). `--bucket` ∈ {day, week, month}
     (default week). Values outside the set are accepted but the three
     presets are what the TUI cycles through.

2. **TUI screen** — new view reachable with key `4` (joins `1/2/3/tab`).
   - **Lazily computed.** The live cost views (`1/2/3`) keep their fast cold
     start. The first time the user presses `4`, a bubbletea `Cmd` runs the
     wide scan + git collection in the background with a spinner; a
     `ReportMsg` delivers the result and the table renders.
   - Within the screen, keys cycle window (30/90/180) and bucket
     (day/week/month), each re-triggering the background recompute.

## Architecture

Four pieces. Pieces 1–3 are pure/IO-isolated and unit-testable; piece 4 is
wiring.

### 1. `internal/agg` — small additions (reuse the deduped cells)

The aggregator already holds deduped per-(day, project, model, isSub) token
cells. Add:

- `projectCwd map[string]string`, populated in `Apply` from `Event.Cwd`
  (first non-empty wins). Project↔cwd is bijective, so no path decoding is
  needed.
- `CwdFor(project string) string`.
- A new snapshot method:

  ```go
  type ProjDayCost struct {
      Project string
      Cwd     string
      Day     string // YYYY-MM-DD, local
      USD     float64
      Tokens  TokenCounts
  }
  func (a *Aggregator) ProjectDaily() []ProjDayCost
  ```

  Walks the existing cells, applies pricing per (model) cell exactly as
  `Snapshot()` does, and emits one row per (project, local-day). The report
  layer buckets from there. **No JSONL parsing is duplicated** — dedupe and
  pricing stay in `agg`.

This does **not** change `Snapshot()` or the live views.

### 2. `internal/gitstat` — new (shells out to `git`)

The only new external dependency. No third-party Go packages — uses
`os/exec` + `git`.

```go
// RepoRoot returns the toplevel of the repo containing cwd.
// ok=false for non-repos (skip silently).
func RepoRoot(cwd string) (root string, ok bool)

type Commit struct {
    Date    time.Time // commit-date, local
    Author  string    // author email
    Added   int
    Deleted int
    Files   int
    Mine    bool       // Author == repo's git config user.email
}

// Collect runs: git -C root log --no-merges --numstat --date=…
//   --since=<since> --pretty=… , parses numstat, marks Mine.
func Collect(root string, since time.Time, myEmail string) ([]Commit, error)

// MyEmail returns the repo-local user.email (git -C root config user.email).
func MyEmail(root string) string
```

- Binary/`-` numstat rows (no line counts) contribute to `Files` but add 0
  to Added/Deleted.
- Bucketing helper rolls `[]Commit` into day/week/month buckets keyed by a
  local-time bucket label.

### 3. `internal/report` — new (pure join, no I/O)

```go
type Bucket struct {
    Label       string  // e.g. "2026-W23" / "2026-06-05" / "2026-06"
    USD         float64
    CommitsMine int
    CommitsAll  int
    Added       int     // mine
    Deleted     int     // mine
    Files       int     // mine
    // Derived (garnish):
    USDPerCommit float64 // USD / CommitsMine  (0 when CommitsMine == 0)
    USDPerLine   float64 // USD / (Added+Deleted) of mine
}

type RepoReport struct {
    Root    string
    Buckets []Bucket // chronological
    Total   Bucket   // window total
}

// Build groups ProjDayCost by repo root (via gitstat.RepoRoot), joins with
// per-repo commit buckets, computes ratios from "mine" only.
func Build(costs []agg.ProjDayCost, window time.Duration, bucket BucketSize) []RepoReport
```

Cost from **all** project keys mapping to a repo root is summed into that
repo. Ratios divide repo cost by *my* commits/lines.

### 4. `internal/ui` + `cmd/claudecounter` — wiring

- New `ModeReport` in the `ViewMode` enum; key `4` selects it; `tab` includes
  it in the cycle.
- New `ReportMsg{Reports []report.RepoReport, Err error}` and a bubbletea
  `Cmd` that performs the wide scan (into a **separate** `agg.Aggregator`
  with `notBefore = now − days`) and git collection off the UI goroutine.
- `viewReport(...)` renders, per repo, a header line (repo short name +
  window total) and one table row per bucket:

  ```
  repo  ·  $142.10 total · 87 commits (mine) / 103 all · +12,340 −4,210 · 156 files
    bucket      $        commits(mine/all)   +lines   −lines   files   $/commit   $/line
    2026-W21    38.40    21 / 26              3,100    980      42      1.83       0.0095
    …
  ```

- CLI `--report` prints the same table as plain text (mirrors how `--once`
  reuses snapshot data), driven by `runReport(root, table, days, bucket)`.

## Data flow

```
JSONL ──reader──▶ Event{Cwd,Project,Usage}
                     │
                  agg.Apply  (dedupe, projectCwd side map)
                     │
            agg.ProjectDaily() ──▶ []ProjDayCost
                                        │
   git log ──gitstat.Collect──▶ []Commit (per repo root)
                                        │
                            report.Build (group by repo root, bucket, ratios)
                                        │
                         ┌──────────────┴──────────────┐
                   --report CLI                   ModeReport (key 4)
                   (text table)                   (lazy ReportMsg + spinner)
```

## Error handling

- `git` not on PATH, or a repo command failing → that repo is omitted; a
  footer note states how many projects were skipped (non-repo vs. git error).
- A project cwd that no longer exists on disk → skipped as non-repo.
- Empty window (no commits) → repo still shown with cost and `0` commits;
  ratios render as `—` (avoid divide-by-zero noise).
- The wide scan reuses the same parse-error / dupe counters; surfaced in the
  report footer the same way the live view surfaces them.

## Testing

- `agg`: `ProjectDaily()` returns correct per-project per-day USD across
  multiple models and main/subagent split; `projectCwd` captures first cwd.
- `gitstat`: parse fixture `git log --numstat` output (normal, binary `-`
  rows, multi-file commits, non-mine author); `RepoRoot` ok/not-ok. Use a
  temporary `git init` repo with scripted commits for an integration test.
- `report.Build`: grouping of multiple project keys into one repo root;
  bucketing into day/week/month boundaries (local TZ); ratio math including
  the divide-by-zero `—` case; +/− kept separate.
- UI: `viewReport` golden-ish render of a fixed `[]RepoReport`.

## Out of scope (v2+)

- PR/MR counts (`gh`/`glab`, network + auth, per-remote detection).
- Generated-file / pathspec exclusion flag.
- Any attempt to causally link a commit to a Claude session.
- Mac menu-bar surface.
