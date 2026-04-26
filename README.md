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

Pre-built binaries are published to
**[GitHub Releases](https://github.com/jverhoeks/claudecounter/releases)**.

**Go TUI** (tags shaped `vX.Y.Z`):

```bash
# macOS Apple Silicon — adjust filename for your platform
curl -L -o claudecounter \
  https://github.com/jverhoeks/claudecounter/releases/latest/download/claudecounter-darwin-arm64
chmod +x claudecounter && ./claudecounter
```

Other platform binaries on the same release page: `darwin-amd64`,
`linux-amd64`, `linux-arm64`, `windows-amd64.exe`, `windows-arm64.exe`.

**Mac menu bar app** (tags shaped `macapp-vX.Y.Z`):

```bash
# Find the latest macapp tag — releases use a separate namespace
TAG=$(curl -s https://api.github.com/repos/jverhoeks/claudecounter/releases \
      | grep '"tag_name":' | grep macapp | head -1 | cut -d'"' -f4)
ZIP="ClaudeCounterBar-${TAG#macapp-}-macos-arm64.zip"

curl -LO "https://github.com/jverhoeks/claudecounter/releases/download/${TAG}/${ZIP}"
ditto -xk "$ZIP" /Applications/

# Strip Gatekeeper quarantine — the build is ad-hoc signed, not yet
# notarized (see macapp/README.md "About signing" for context)
xattr -dr com.apple.quarantine /Applications/ClaudeCounterBar.app

open /Applications/ClaudeCounterBar.app
```

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
  cmd/claudecounter/            main, integration test
  internal/{pricing,reader,    pricing math · JSONL tailing · token aggregator
            agg,watcher,ui}/    · fsnotify wrapper · bubbletea views
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
