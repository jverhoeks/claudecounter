# 💸 claudecounter

> A tiny, fast TUI that watches your Claude Code spend in real time.

Tails `~/.claude/projects/**/*.jsonl` (recursively, including subagents) via
`fsnotify`, dedupes events by `messageId:requestId`, applies the same
LiteLLM pricing table that [ccusage](https://github.com/ryoppippi/ccusage)
uses, and shows you today's and this month's cost at a glance.

```
┌──────────────────────────────────────────────────────────────┐
│ Today  $34.87    Month $5,676.51                             │
├─────────────── by model ────────────────────────────────────┤
│  claude-opus-4-6                $3,624.89   64%              │
│  claude-opus-4-7                $1,932.20   34%              │
│  claude-sonnet-4-6                 $88.66    2%              │
│  claude-haiku-4-5-20251001         $30.76    1%              │
├─────────── by project (this month) — main · sub ────────────┤
│  project1             $2,385.96   main $1,421.71 · sub $964 │
│  project2             $2,176.17   main $1,900.02 · sub $276 │
│  project3               $251.79   main   $197.86 · sub  $54 │
│  …                                                           │
├─────────────── live ────────────────────────────────────────┤
│ 10:21:14  project1        opus    +$0.062 (sub)              │
│ 10:21:09  project1        opus    +$0.041                    │
└──────────────────────────────────────────────────────────────┘
```

## ✨ Features

- 📊 **Three views**: minimal · split (default) · full dashboard with live tail
- 🔁 **Real-time**: fsnotify-driven; numbers tick up as Claude Code writes
- 🧩 **Per-project breakdown** with main vs subagent (Task tool) split
- 🎯 **Token-first math**: cost is derived from accumulated tokens at
  snapshot time, never from running float sums (no accumulation drift)
- 🪶 **Single binary** — no Node, no Python, no daemon
- 🌍 **Cross-platform**: macOS · Linux · Windows (testers welcome 🪟 — see below)
- 💾 **Zero-config**: defaults work; pricing falls back to a baked-in
  table when no `pricing.toml` is present

## 🚀 Install

### Download a release binary

Grab the right artefact for your OS from
[Releases](https://github.com/jverhoeks/claudecounter/releases):

| OS / arch | file |
|---|---|
| macOS Apple Silicon | `claudecounter-darwin-arm64` |
| macOS Intel | `claudecounter-darwin-amd64` |
| Linux x86-64 | `claudecounter-linux-amd64` |
| Linux ARM64 | `claudecounter-linux-arm64` |
| Windows x86-64 | `claudecounter-windows-amd64.exe` |
| Windows ARM64 | `claudecounter-windows-arm64.exe` |

```bash
# macOS / Linux
curl -L https://github.com/jverhoeks/claudecounter/releases/download/v0.1.0/claudecounter-darwin-arm64 -o claudecounter
chmod +x claudecounter
./claudecounter
```

### Or build from source

```bash
git clone https://github.com/jverhoeks/claudecounter
cd claudecounter
go build ./cmd/claudecounter
./claudecounter
```

Requires Go 1.22+.

## 🎮 Usage

### Live TUI

```bash
./claudecounter
```

Keys:
- `1` / `2` / `3` — minimal · split · full view
- `Tab` — cycle views
- `q` / `Ctrl+C` — quit

### One-shot (great for scripting / cron / status bars)

```bash
./claudecounter --once
```

Prints today's cost, the month-to-date total, a per-model breakdown,
and a per-project breakdown with main/subagent split — then exits.

### Flags

| flag | default | what |
|---|---|---|
| `--root` | `~/.claude/projects` | Where to read JSONL transcripts from |
| `--pricing` | `~/.config/claudecounter/pricing.toml` | Custom pricing table |
| `--refresh-pricing` | off | Fetch the latest pricing from Anthropic docs and write it to disk |
| `--once` | off | Print summary and exit (no TUI, no watcher) |

## 🪟 Windows testers wanted

The Windows binaries are cross-compiled but **not yet road-tested**.
What should work:

- `%USERPROFILE%\.claude\projects` is auto-detected
- Path separators are normalised before project + subagent attribution
- `fsnotify` uses `ReadDirectoryChangesW` under the hood — should pick
  up live writes the same way macOS/Linux does

If you run claudecounter on Windows and find anything off (paths,
keybindings, terminal rendering, fsnotify quirks), please open an
[issue](https://github.com/jverhoeks/claudecounter/issues) — gold-tier
contribution, much appreciated. 🙏

## 🔍 How the math works

Each line in a Claude Code JSONL is an assistant turn with a `usage`
object. claudecounter:

1. **Recurses** the projects directory (subagent transcripts live two
   levels deeper — see "the missing files" below)
2. **Dedupes** by `messageId:requestId` (first-seen wins). Claude Code
   re-serialises the same turn during streaming, so a single response
   can appear up to ~25× in the JSONL
3. **Filters** internal `<synthetic>` events that have no billable usage
4. **Buckets** by local-day (Europe/Amsterdam etc. — uses your system
   timezone) so late-night sessions land on the right day
5. **Sums tokens** per `(day, project, model, isSubagent)` cell
6. **Applies pricing** at snapshot time only, by summing tokens first
   then multiplying — token math is exact (uint64), so the daily and
   monthly numbers are reproducible to the cent across runs

The four token types (`input`, `output`, `cache_creation`, `cache_read`)
are kept separate end-to-end and only collapsed into a single dollar
column at display time.

## 🕵️ The case of the missing files

Early versions of claudecounter consistently undercounted busy days by
30-50 % vs `ccusage`. The structural fixes (correct LiteLLM Opus prices,
`messageId:requestId` first-seen dedupe, local-day bucketing) all
helped, but a stubborn ~30 % gap remained on heavy days even after the
rules matched ccusage's exactly.

The breakthrough came from running ccusage in JSON mode and diffing
each day per token category. The ratios were not uniform — `input`
ratios on heavy days hit **18×**, but `cache_create` stayed at 1.1×.
That non-uniform inflation pointed away from a dedupe quirk and toward
**missing data**.

Sure enough: Claude Code writes Task-tool subagent transcripts to
`<project>/<session-uuid>/subagents/agent-*.jsonl` — two levels deeper
than regular session jsonls. Our `*/*.jsonl` glob caught only the
top-level files. ccusage uses a recursive `**/*.jsonl` (via tinyglobby)
and was reading **2,544 of the 2,734 transcripts in the tree** that we
were skipping (93 %!). On the test machine, that single change closed
the gap from ~$130/day to **6 cents on $5,676 month-to-date**.

Big credit to [ccusage](https://github.com/ryoppippi/ccusage) as the
ground-truth reference throughout this calibration. We mirror their
LiteLLM pricing source, their dedupe key, and their recursive scan.
Numbers should match within rounding noise on every clean comparison.

## 🛠️ Pricing

claudecounter ships with a baked-in pricing table for the Claude 4.5 /
4.6 / 4.7 family (Opus, Sonnet, Haiku) sourced from
[LiteLLM](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json),
the same source ccusage uses. To override:

```toml
# ~/.config/claudecounter/pricing.toml

[models."claude-opus-4-7"]
input_per_mtok          = 5.00
output_per_mtok         = 25.00
cache_creation_per_mtok = 6.25
cache_read_per_mtok     = 0.50
```

Or run `./claudecounter --refresh-pricing` to scrape the current
Anthropic docs page and write a fresh `pricing.toml` (best-effort —
the live page format can change).

## 🧪 Tests

```bash
go test ./...
```

Coverage: pricing math · JSONL parsing · offset / partial-line safety
· fsnotify wiring · day/month boundaries · dedupe rules · per-project
attribution · format helpers. UI rendering is intentionally not tested
(thin layer; visual verification).

## 📁 Project layout

```
cmd/claudecounter/        main, integration test
internal/pricing/         model pricing table, fetch, defaults
internal/reader/          JSONL tailing + project/subagent attribution
internal/agg/             token aggregator, snapshot, civil-day bucketing
internal/watcher/         fsnotify wrapper with recursive AddTree
internal/ui/              bubbletea model + three views
```

## 📜 License

MIT.

## 🙏 Credits

- [ccusage](https://github.com/ryoppippi/ccusage) for the reference
  implementation and ground-truth numbers throughout calibration
- [Bubble Tea](https://github.com/charmbracelet/bubbletea) /
  [Lipgloss](https://github.com/charmbracelet/lipgloss) for the TUI
- [LiteLLM](https://github.com/BerriAI/litellm) for the pricing table
- [fsnotify](https://github.com/fsnotify/fsnotify) for the file watcher
