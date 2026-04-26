# 💸 claudecounter TUI

> A tiny, fast Go TUI that watches your Claude Code spend in real time.

Tails `~/.claude/projects/**/*.jsonl` (recursively, including subagents)
via `fsnotify`, dedupes events by `messageId:requestId`, applies the
LiteLLM pricing table, and shows you today's and this month's cost at
a glance.

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
├─────────────── live ────────────────────────────────────────┤
│ 10:21:14  project1        opus    +$0.062 (sub)              │
│ 10:21:09  project1        opus    +$0.041                    │
└──────────────────────────────────────────────────────────────┘
```

For the shared philosophy, math, "missing files" calibration story,
and pricing source see the [root README](../README.md).

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

Joint releases ship both apps under tags shaped `vX.Y.Z`. Grab the
right artefact for your OS from
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
# macOS / Linux — uses GitHub's "latest" alias, no version number needed
curl -L -o claudecounter \
  https://github.com/jverhoeks/claudecounter/releases/latest/download/claudecounter-darwin-arm64
chmod +x claudecounter
./claudecounter
```

### Build from source

From the **repo root**:

```bash
git clone https://github.com/jverhoeks/claudecounter
cd claudecounter
make build         # → ./claudecounter
./claudecounter
```

Or, working inside `tui/` directly:

```bash
cd tui
go build -o ../claudecounter ./cmd/claudecounter
```

Or via `go install`:

```bash
go install github.com/jverhoeks/claudecounter/tui/cmd/claudecounter@latest
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

## 🧪 Tests

From the repo root:

```bash
make test       # cd tui && go test ./...
make cover      # produces coverage.out + summary
make test-v     # verbose
```

Or directly from `tui/`:

```bash
cd tui && go test ./...
```

Coverage: pricing math · JSONL parsing · offset / partial-line safety
· fsnotify wiring · day/month boundaries · dedupe rules · per-project
attribution · format helpers. UI rendering is intentionally not tested
(thin layer; visual verification).

## 📁 Layout

```
cmd/claudecounter/        main, integration test, scan-cutoff test
internal/pricing/         LiteLLM table, fetch, defaults, TOML override
internal/reader/          JSONL tailing + project/subagent attribution
internal/agg/             token aggregator, snapshot, civil-day bucketing
internal/watcher/         fsnotify wrapper with recursive AddTree
internal/ui/              bubbletea model + three views (minimal/split/full)
go.mod                    module: github.com/jverhoeks/claudecounter/tui
```

## 🛠️ Makefile targets

(All run from the repo root.)

| target | what |
|---|---|
| `make build` | Build TUI for current platform → `./claudecounter` |
| `make run` | Build and launch the TUI |
| `make once` | Build and run `--once` |
| `make test` / `make test-v` / `make cover` | Run Go tests |
| `make build-all` | Cross-build all 6 platforms into `dist/` |
| `make ccusage-diff` | Diff today's totals against `ccusage` |
| `make release VERSION=v0.x.y` | Tag + cross-build + GitHub release |

## 📜 License

MIT. See [root LICENSE info](../README.md#-license).
