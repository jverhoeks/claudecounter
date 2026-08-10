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
- 📈 **30-day twin charts**: daily cost (green) and daily token volume
  (blue) stacked, so you can see at a glance whether spend tracked
  usage or whether a model price was driving the bill
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
- `4` — git activity & ROI report (`d`/`w`/`m` bucket, `[`/`]` window)
- `5` — permission-mode safety report (`[`/`]` window)
- `v` — cycle the grouping shown in views `1`/`2`/`3`: model → vendor →
  source → total → model (see the [root README's Multiple sources &
  grouping
  section](../README.md#-multiple-sources--grouping-tui-key-v--popover-segmented-control))
- `↑`/`↓` `PgUp`/`PgDn` `g`/`G` — scroll (report/safety views)
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
| `--root` | `~/.claude/projects` | Where to read JSONL transcripts from. Passing this explicitly overrides `sources.toml` entirely with a single implicit source rooted there — the pre-`sources.toml` contract, kept for anyone who hasn't adopted the config file |
| `--sources-config` | `~/.config/claudecounter/sources.toml` | Path to `sources.toml`, for monitoring more than one Claude subscription. Only consulted by the live TUI and `--once`/`--limits`; the report-family flags (`--report`, `--safety`, `--scorecard`, `--timeline`, `--phases`) still take `--root` directly. See the [root README's Multiple sources & grouping section](../README.md#-multiple-sources--grouping-tui-key-v--popover-segmented-control) |
| `--pricing` | `~/.config/claudecounter/pricing.toml` | Custom pricing table |
| `--refresh-pricing` | off | Fetch the latest pricing from Anthropic docs and write it to disk |
| `--once` | off | Print summary and exit (no TUI, no watcher) |
| `--report` | off | Print the git-activity & ROI report and exit |
| `--safety` | off | Print the permission-mode safety report and exit |
| `--csv` | off | CSV export to stdout (of `--report`, or of `--safety` when combined) |
| `--days` | 90 | Window for `--report`/`--safety` (30/90/180) |
| `--bucket` | week | Report bucket: `day`\|`week`\|`month` |
| `--scorecard` | off | Print a per-session scorecard (tools, failures, waste, tokens) and exit |
| `--timeline` | off | Print a per-session chronological audit log and exit |
| `--session` | most recent | Session id prefix for `--scorecard`/`--timeline` |
| `--limits` | off | Scan once, print budget and plan-limit gauges, and exit |
| `--limits-config` | `~/.config/claudecounter/limits.toml` | Path to `limits.toml` |

The same gauge block also renders live inside views `1` (minimal) and
`2` (split, default), refreshed every 30s — not in view `3` (full
dashboard). See the [root README's Limits
section](../README.md#-limits--plan-utilisation-tui-views-12----limits)
for the config format and what each row means.

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
make test       # cd tui && TZ=UTC go test ./...
make cover      # produces coverage.out + summary
make test-v     # verbose
```

Or directly from `tui/`:

```bash
cd tui && TZ=UTC go test ./...
```

`TZ=UTC` matters here: `limits.Evaluate` hardcodes `time.Local` (no
location seam yet), and the cross-language limits parity fixture
compares it against Swift's UTC-pinned test. Without `TZ=UTC`, a
contributor outside UTC+0/+1/+2 (e.g. UTC+13/+14) gets a failing
`TestParityFixture` for a timezone mismatch, not a real regression. The
`make` targets above set it for you; set it yourself if you run `go
test` directly.

Coverage: pricing math · JSONL parsing · offset / partial-line safety
· fsnotify wiring · day/month boundaries · dedupe rules · per-project
attribution · format helpers · `sources.toml` load/validate (duplicate
and nested-root rejection, tilde expansion, same label across vendors)
· grouping (all four modes partition the same total). UI rendering is
intentionally not tested (thin layer; visual verification).

## 📁 Layout

```
cmd/claudecounter/        main, CLI report/safety/scorecard/timeline, tests
internal/pricing/         LiteLLM table, fetch, defaults, TOML override
internal/sources/         sources.toml load + validate (multiple subscriptions)
internal/reader/          JSONL tailing + project/subagent attribution
internal/agg/             token aggregator, snapshot, civil-day bucketing,
                          grouping (model/vendor/source/total)
internal/watcher/         fsnotify wrapper with recursive AddTree
internal/report/          git activity & ROI report (spend × commits)
internal/gitstat/         git repo-root mapping + commit collection
internal/safety/          permission-mode aggregation + container heuristic
internal/session/         per-session transcript parser (tools, modes, tokens)
internal/ui/              bubbletea model + five views
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
