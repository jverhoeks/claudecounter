# 💸 claudecounter

> Two tiny, fast tools that watch your Claude Code spend in real time.

Both apps tail `~/.claude/projects/**/*.jsonl` (recursively, including
subagent transcripts) via OS-native file events, dedupe by
`messageId:requestId`, and apply the same LiteLLM pricing table that
[ccusage](https://github.com/ryoppippi/ccusage) uses. Same JSONL in →
same dollars out, to the cent.

| | [Go TUI](./tui) | [Mac menu bar](./macapp) |
|---|---|---|
| **Surface** | Full-screen terminal dashboard | macOS menu bar item + popover |
| **Best for** | Power users, SSH sessions, scripting | "Glance and go" — always-on indicator |
| **Languages** | Go (single static binary) | Swift / SwiftUI (`.app` bundle) |
| **Platforms** | macOS · Linux · Windows | macOS 13+ on Apple Silicon |
| **One-shot mode** | `claudecounter --once` | (use the TUI) |
| **Persists between runs?** | No | Yes (`~/Library/Application Support/...`) |
| **Live updates** | fsnotify-driven | FSEventStream-driven |

Pick the one that fits your workflow — they're independent, run side
by side without conflict, and produce identical numbers.

## ⬇️ Download

Both apps ship together on a single
**[GitHub Releases](https://github.com/jverhoeks/claudecounter/releases)**
page. Tags shaped `vX.Y.Z` mean "version X.Y.Z of the project as a whole" —
each release contains all 6 cross-platform TUI binaries plus the
macOS menu bar app `.zip`.

**Go TUI** — pick your platform:

```bash
# macOS Apple Silicon
curl -L -o claudecounter \
  https://github.com/jverhoeks/claudecounter/releases/latest/download/claudecounter-darwin-arm64
chmod +x claudecounter && ./claudecounter
```

Available in every release: `darwin-arm64`, `darwin-amd64`,
`linux-amd64`, `linux-arm64`, `windows-amd64.exe`, `windows-arm64.exe`.

**Mac menu bar app:**

```bash
# Replace v1.0.0 with the latest tag on the Releases page
VERSION=v1.0.0
ZIP="ClaudeCounterBar-${VERSION}-macos-arm64.zip"

curl -LO "https://github.com/jverhoeks/claudecounter/releases/download/${VERSION}/${ZIP}"
ditto -xk "$ZIP" /Applications/

# Strip Gatekeeper quarantine — the build is ad-hoc signed, not yet
# notarized (see macapp/README.md "About signing" for context)
xattr -dr com.apple.quarantine /Applications/ClaudeCounterBar.app

open /Applications/ClaudeCounterBar.app
```

> **Out-of-cycle macapp patches** are also published under
> `macapp-vX.Y.Z` tags for fixes that don't warrant rebuilding the
> Go TUI. Either tag namespace works for the menu bar app.

Or build from source — see the [Quick start](#quick-start) below.

## TUI preview

```
┌──────────────────────────────────────────────────────────────┐
│ Today  $34.87    Month $5,676.51                             │
├─────────────── by model ────────────────────────────────────┤
│  claude-opus-4-6                $3,624.89   64%              │
│  claude-opus-4-7                $1,932.20   34%              │
│  claude-sonnet-4-6                 $88.66    2%              │
├─────────── by project (this month) — main · sub ────────────┤
│  project1             $2,385.96   main $1,421.71 · sub $964 │
│  project2             $2,176.17   main $1,900.02 · sub $276 │
├─────────────── live ────────────────────────────────────────┤
│ 10:21:14  project1        opus    +$0.062 (sub)              │
│ 10:21:09  project1        opus    +$0.041                    │
└──────────────────────────────────────────────────────────────┘
```

→ Full TUI docs: **[`tui/README.md`](./tui/README.md)**

## 📈 Git activity & ROI (TUI view `4` / `--report`)

Press **`4`** in the TUI (or run `claudecounter --report`) for a per-repo
view that puts what you *spent* beside what you *produced* — commits,
`+`/`−` lines, and files — bucketed over a window, with `$/commit` and
`$/line` ratios:

```
sqlengine   $4,016.58 · 440 commits (mine) / 446 all · +269,230 −15,578 · 2,527 files
  bucket            $   commits(m/all)   +lines   -lines   files   $/commit   $/line
  2026-W19  $1,243.81       108 / 108    39,593    4,486     546     $11.52    $0.03
  2026-W20    $980.22        96 / 101    21,140    3,002     410     $10.21    $0.05
```

In the TUI: **`d`/`w`/`m`** switch the bucket (day/week/month), **`[`/`]`**
cycle the window (30/90/180 days), and **`↑`/`↓` `PgUp`/`PgDn` `g`/`G`**
scroll the report (it can run to many repos × buckets). The view is
computed lazily the first time you open it, with a spinner while git is
collected.

CLI (non-interactive):

```bash
claudecounter --report [--days 30|90|180] [--bucket day|week|month]   # human table
claudecounter --csv    [--days 30|90|180] [--bucket day|week|month]   # CSV to stdout
```

Alongside cost, each bucket also shows **`$/commit`**, **`$/line`** (to 4
decimals — per-line cost is fractions of a cent), **`tok/commit`** and
**`tok/line`** (token volume per commit/line, with k/M suffixes), plus the
repo's total token volume.

`--csv` prints one row per repo+bucket
(`repo,bucket,usd,commits_mine,commits_all,added,deleted,files,usd_per_commit,usd_per_line,tokens,tokens_per_commit,tokens_per_line`)
— undefined ratios are empty cells — so you can pipe it into a sheet or
`awk`. Progress goes to stderr, so `--csv … > out.csv` stays clean.

It maps each Claude project's working directory to its git repo
(`git rev-parse --show-toplevel`), so worktrees and subdirs of one repo
merge together; non-git projects are skipped.

**Read the ratios as a rough guide, not a measurement.** Nothing in the
transcripts links a commit to a Claude session — the report simply places
*spend during a window* next to *git activity during the same window*.
Spend often produces no commits (debugging, reading), and commits happen
without Claude. `+`/`−` lines are shown separately (a single lockfile
commit can be +30k lines), merge commits are excluded, and `$/commit`
uses **your own** commits — the per-repo `user.email` — while the
all-authors count is shown alongside. PR/MR counts are not included yet.

## 🛡️ Permission-mode safety (TUI view `5` / `--safety`)

Press **`5`** in the TUI (or run `claudecounter --safety`) for a per-project
view of which permission modes your sessions ran under — and how much of
your work happens with permissions bypassed
(`--dangerously-skip-permissions`):

```
⚠ 1673 turns (60.5%) ran with permissions bypassed, in 7 project(s)
project              turns  sess  default accept  plan  auto dontAsk  BYPASS  container? entry
terraform-provider     195     8       2%      ·     ·     ·       ·     98%  no         sdk-py
data-platform          782    89      10%     1%     ·    6%       ·     83%  no         cli,sdk-py
```

Every real prompt turn in the transcripts carries a `permissionMode`
(`default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`),
so the percentages are exact. The **`container?`** column is different: the
transcripts have no hard docker/container signal, so it's a **cwd-path
heuristic** — a session whose cwd doesn't follow the host's home-dir
convention (e.g. `/workspace`, `/app`, `/root` on a macOS host) is marked
`likely`. Read it as a hint, not a fact. Note that container sessions only
show up at all when the container's `~/.claude` is volume-mounted to the
host. `--safety --csv` exports raw per-mode counts.

## 🔬 Per-session scorecard & timeline (`--scorecard` / `--timeline`)

Deterministic, stats-only cousins of [arx](https://github.com/berbyte/arx-ce)'s
session reports — no LLM judging, just what's measurable in the transcript.
They operate on one session (default: the most recent; pick another with
`--session <id-prefix>`), including its Task-tool subagent transcripts:

```bash
claudecounter --scorecard            # tool calls & failure rate per tool,
                                     # files Read 2+ times, tokens by category
                                     # + USD, peak context size, mode history
claudecounter --timeline             # chronological audit log: every tool
                                     # call (ok/ERR), permission-mode change ⚠,
                                     # and priced assistant turn
claudecounter --timeline --session 14a8997f
```

```
06-10 11:44:34  mode       (start) → default
06-10 11:44:53  Bash       go test ./...                                   ok
06-10 11:45:14  Edit       tui/internal/ui/view_report.go                  ERR
06-10 11:45:24  turn       opus                                            +$0.41  (sub)
```

Turn counts and token sums reuse the counter's `messageId:requestId`
dedupe; tool calls dedupe by `tool_use` block id. Models missing from the
pricing table are flagged as unpriced rather than silently counted as $0.

## 🔎 Corpus insights (`claudeinsights`)

A separate binary that scans the whole transcript corpus for **token waste,
tool abuse, skill overload, context overload, and loop patterns** — ranking
the worst sessions and projects so you can see where effort (and money) leaks.
It reuses the same session parsing as the scorecard and runs entirely locally.

```bash
claudeinsights                 # ranked corpus leaderboard (last 90 days)
claudeinsights --days 30       # narrower window
claudeinsights --session 1a2b  # drill into one session's findings
claudeinsights --json          # full structured output
claudeinsights --csv           # one row per finding
claudeinsights --session 1a2b --digest   # compact JSON digest (LLM input / export)
```

```
Corpus  $12,352 spent · $272 estimated waste · 847 sessions
Worst sessions (top 15):
  session  project              $       waste$   findings  top finding
  43b9d8b8 data-platform   $880.38    $57.53        ...   waste: 8 failed tool call(s) …
```

Findings are tiered by confidence. The **structural** tier (waste, abuse,
skill, context, loops, sprawl, model-routing) is always on. Waste $ counts only
new tokens — cache-read reuse is not waste. Results are cached under
`$XDG_CACHE_HOME/claudeinsights/` so re-runs are ~25× faster (`--no-cache` /
`--refresh` to control).

The **coaching** tier is opt-in and uses your local `claude -p` CLI (no API
token required) to read the actual prompts and judge friction, corrections,
loops, prompt clarity, and recurring **CLAUDE.md/memory candidates** per
project. It runs only on the worst flagged sessions and caches every reply so
you don't re-pay:

```bash
claudeinsights --llm                 # coach the worst flagged sessions (~$0.10 each)
claudeinsights --llm --llm-max 5     # cap how many sessions get the LLM pass
claudeinsights --session 1a2b --llm  # coach one specific session
```

`--llm` also prints a **`══ Top actions ══`** list — the per-session advice rolled
up into a deduped, prioritized "what to change in how you work" summary.

Turn the mined CLAUDE.md candidates into real changes with `--apply`. It uses
`claude -p` to merge them into each flagged project's `<cwd>/CLAUDE.md`,
preserving your existing content and only appending a deduped
`## Insights (auto-suggested)` section. **Dry-run by default** — it prints a diff
and writes nothing; add `--write` to apply (atomically):

```bash
claudeinsights --llm --apply          # show the CLAUDE.md merge diffs (writes nothing)
claudeinsights --llm --apply --write  # actually write the merged CLAUDE.md files
```

Cost-without-delivery (high-$ sessions with no commit and no PR) is checked via
git for expensive sessions. Build with `make build-insights` (or `make build`,
which now produces both binaries).

## Mac menu bar preview

```
 ▁▂▁▃▂▅▄▃ $34.87
        ↑ click for full dashboard popover
```

The popover shows hero today/month numbers, an hourly chart, by-model
and by-project tables, and a live tail of recent events.

→ Full menu bar app docs: **[`macapp/README.md`](./macapp/README.md)**

## Quick start

```bash
git clone https://github.com/jverhoeks/claudecounter
cd claudecounter

# Build the TUI binary → ./claudecounter
make build && ./claudecounter

# Build the macOS menu bar app → dist/ClaudeCounterBar.app
make macapp && open dist/ClaudeCounterBar.app

# Run both test suites (Go + Swift)
make test-all
```

`make` from the repo root drives everything. Run `make help` for the
full target list.

## ✨ Features (shared between both apps)

- 🔁 **Real-time** — file-watcher-driven, numbers tick up the moment
  Claude Code writes a new line. No polling.
- 🧩 **Per-project breakdown** with main vs subagent (Task tool) split.
- 📈 **Git activity & ROI** (TUI only) — per-repo spend vs. commits/lines/
  files with `$/commit` and `$/line`, over a 30/90/180-day window. See the
  [Git activity & ROI](#-git-activity--roi-tui-view-4----report) section.
- 🛡️ **Permission-mode safety report** (TUI only) — % of turns per project
  run with permissions bypassed, with a container-likely heuristic. See
  [Permission-mode safety](#️-permission-mode-safety-tui-view-5----safety).
- 🔬 **Per-session scorecard & timeline** (TUI only, CLI flags) — tool
  success rates, duplicate reads, token/cost breakdown, and a full
  chronological audit log per session. See
  [scorecard & timeline](#-per-session-scorecard--timeline---scorecard----timeline).
- 🎯 **Token-first math** — cost is derived from accumulated token
  counts at snapshot time, never from running float sums. No
  accumulation drift; daily and monthly numbers are reproducible to
  the cent across runs.
- 🪶 **No daemon, no Node, no Python** — single Go binary or a single
  Swift `.app`. Both watch `~/.claude/projects` directly.
- 💾 **Zero-config** — defaults work; pricing falls back to a baked-in
  table when no `pricing.toml` is present.
- 🛠 **Custom pricing** via `~/.config/claudecounter/pricing.toml`
  (TUI), the same file the menu bar app picks up too, plus an in-app
  refresh that fetches LiteLLM directly.

## 🔍 How the math works

Each line in a Claude Code JSONL is an assistant turn with a `usage`
object. Both apps:

1. **Recurse** the projects directory (subagent transcripts live two
   levels deeper — see "the case of the missing files" below).
2. **Dedupe** by `messageId:requestId` (first-seen wins). Claude Code
   re-serialises the same turn during streaming, so a single response
   can appear up to ~25× in the JSONL.
3. **Filter** internal `<synthetic>` events that have no billable usage.
4. **Bucket** by local-day (Europe/Amsterdam etc. — uses your system
   timezone) so late-night sessions land on the right day.
5. **Sum tokens** per `(day, project, model, isSubagent)` cell.
6. **Apply pricing** at snapshot time only, by summing tokens first
   then multiplying — token math is exact (uint64 / UInt64), so the
   daily and monthly numbers are reproducible to the cent across runs.

The four token types (`input`, `output`, `cache_creation`, `cache_read`)
are kept separate end-to-end and only collapsed into a single dollar
column at display time.

The Swift menu bar app is a byte-for-byte port of the Go TUI's
algorithm. The Swift test suite includes cross-language conformance
tests that parse the same JSONL fixtures the Go tests use and assert
identical token totals — that's the regression net against algorithm
drift.

## 🕵️ The case of the missing files

Early versions of claudecounter consistently undercounted busy days by
30–50% vs `ccusage`. The structural fixes (correct LiteLLM Opus prices,
`messageId:requestId` first-seen dedupe, local-day bucketing) all
helped, but a stubborn ~30% gap remained on heavy days even after the
rules matched ccusage's exactly.

The breakthrough came from running ccusage in JSON mode and diffing
each day per token category. The ratios were not uniform — `input`
ratios on heavy days hit **18×**, but `cache_create` stayed at 1.1×.
That non-uniform inflation pointed away from a dedupe quirk and toward
**missing data**.

Sure enough: Claude Code writes Task-tool subagent transcripts to
`<project>/<session-uuid>/subagents/agent-*.jsonl` — two levels deeper
than regular session jsonls. The original `*/*.jsonl` glob caught only
the top-level files. ccusage uses a recursive `**/*.jsonl` (via
tinyglobby) and was reading **2,544 of the 2,734 transcripts in the
tree** that were skipped (93%!). On the test machine, that single
change closed the gap from ~$130/day to **6 cents on $5,676
month-to-date**.

A subtler twist showed up later in the Swift port: roughly 30% of
turns appear in *both* the main session JSONL and one of its subagent
JSONLs (Claude Code logs the Task-tool result in both). With
first-seen-wins dedupe, scan order decides whether such a turn is
booked as "main" or "sub". Go's `filepath.WalkDir` visits `<uuid>/`
(directory) before `<uuid>.jsonl` (file) because `.` sorts after
end-of-string, so subagent files are read first — sub wins. We mirror
that walk order exactly in `Reader.candidateJSONLs` so both apps
attribute identically.

Big credit to [ccusage](https://github.com/ryoppippi/ccusage) as the
ground-truth reference throughout this calibration. We mirror their
LiteLLM pricing source, their dedupe key, and their recursive scan.
Numbers should match within rounding noise on every clean comparison.

## 🛠️ Pricing

Both apps ship with a baked-in pricing table for the Claude 4.5 / 4.6
/ 4.7 family (Opus, Sonnet, Haiku) sourced from
[LiteLLM](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json),
the same source ccusage uses.

To override pricing, drop a TOML file at:

```toml
# ~/.config/claudecounter/pricing.toml — read by BOTH apps

[models."claude-opus-4-7"]
input_per_mtok          = 5.00
output_per_mtok         = 25.00
cache_creation_per_mtok = 6.25
cache_read_per_mtok     = 0.50
```

The macapp also accepts an override at
`~/Library/Application Support/claudecounter-bar/pricing.toml` which
takes precedence over the shared file. The macapp's "⚙ → Refresh
pricing" menu item fetches LiteLLM and writes that file.

The TUI's `--refresh-pricing` flag does the same, scraping the
Anthropic docs page and writing `~/.config/claudecounter/pricing.toml`.

## 📁 Project layout

```
tui/                          ← Go TUI (`claudecounter` binary)
  cmd/claudecounter/            main, CLI reports, integration test
  internal/{pricing,reader,    pricing math · JSONL tailing · token aggregator
            agg,watcher,ui}/    · fsnotify wrapper · bubbletea views
  internal/{report,gitstat}/    git activity & ROI report
  internal/{safety,session}/    permission-mode report · per-session parser
  go.mod                        module: github.com/jverhoeks/claudecounter/tui

macapp/                       ← Swift menu bar app (ClaudeCounterBar.app)
  Package.swift
  Sources/ClaudeCounterCore/    headless library (Pricing, Reader,
                                Aggregator, Watcher, Cache, AppState)
  Sources/ClaudeCounterBar/     SwiftUI MenuBarExtra + popover
  Tests/                        72 unit tests, incl. cross-language
                                conformance against the Go fixtures
  scripts/build-app.sh          assemble `.app` from the SPM exe

Makefile                      ← drives both: `make build` (TUI),
                                `make macapp`, `make test-all`, etc.
docs/superpowers/             ← design specs and implementation plans
```

## 📜 License

MIT.

## 🙏 Credits

- [ccusage](https://github.com/ryoppippi/ccusage) for the reference
  implementation and ground-truth numbers throughout calibration
- [Bubble Tea](https://github.com/charmbracelet/bubbletea) /
  [Lipgloss](https://github.com/charmbracelet/lipgloss) for the TUI
- [LiteLLM](https://github.com/BerriAI/litellm) for the pricing table
- [fsnotify](https://github.com/fsnotify/fsnotify) for the Go watcher
- Apple's [`MenuBarExtra`](https://developer.apple.com/documentation/swiftui/menubarextra)
  + [FSEventStream](https://developer.apple.com/documentation/coreservices/file_system_events)
  for the macOS menu bar app
