# 🍎 ClaudeCounterBar

> A native macOS menu bar app that shows your Claude Code spend in
> (near) real time.

```
 ▁▂▁▃▂▅▄▃ $34.87
        ↑ click for the dashboard popover
```

The menu bar item shows a sparkline of today's last 8 hours of spend
plus today's running total. Click for a popover with hero today/month
numbers, an hourly chart, by-model and by-project tables, and a live
tail of recent events.

For the shared philosophy, math, "missing files" calibration story,
and pricing source see the [root README](../README.md).

## ✨ What it shows

**Menu bar item (always visible):**
- 8-bar sparkline of today's spend per hour
- `$today` (compact format, e.g. `$34.87` / `$1,247`)
- Pulses softly while the initial scan runs, then snaps to live numbers
- `—` when `~/.claude/projects` is missing

**Popover (~520×440px, on click):**
- Hero today + month numbers
- 24-bar hourly chart for today (future hours dimmed)
- "By model · month" table with USD and %
- "By project · month" table with main / subagent split
- Live tail — last 8 events as they arrive
- Footer: "Updated Xs ago" · Refresh button · ⚙ menu

**⚙ menu:**
- Refresh pricing (fetches from LiteLLM and writes to the in-app override)
- Quit

## 🚀 Install / build

### From the repo root

```bash
git clone https://github.com/jverhoeks/claudecounter
cd claudecounter
make macapp
open dist/ClaudeCounterBar.app
```

The app is **menu-bar-only** (`LSUIElement = YES`) — no Dock icon, no
window. Quit via the ⚙ menu inside the popover or `osascript -e 'tell
application "ClaudeCounterBar" to quit'`.

### From this directory

```bash
cd macapp
./scripts/build-app.sh release   # → ../dist/ClaudeCounterBar.app
swift test                       # 72 unit tests
```

### Requirements

- macOS 13+ (uses `MenuBarExtra` and `SMAppService`)
- Xcode 15+ / Swift 5.9+ (Swift 6 mode is fine)
- No third-party dependencies — everything is in-tree

## 🧠 Architecture

Same layered design as the [Go TUI](../tui), ported to Swift:

```
┌──────────────────────────────────────────────────────────────────┐
│  SwiftUI layer (MenuBarExtra + Popover)                          │
└────────────────▲─────────────────────────────────────────────────┘
                 │ @Published Snapshot
┌────────────────┴─────────────────────────────────────────────────┐
│  AppState     coordinates Watcher → Reader → Aggregator →        │
│                 Snapshot, debounces UI updates to 250ms          │
└────────────────▲─────────────────────────────────────────────────┘
                 │
┌────────────────┴─────────────────────────────────────────────────┐
│  Aggregator   actor; cells keyed by (day, project, model, isSub) │
│                 holds Tokens(in,out,cacheCreate,cacheRead)       │
│                 snapshot() applies Pricing → Totals              │
└────────────────▲─────────────────────────────────────────────────┘
                 │ UsageEvent stream
┌────────────────┴─────────────────────────────────────────────────┐
│  Reader       actor; tails JSONL with byte offsets               │
│                 dedupes by messageId:requestId (first-seen)      │
│                 filters <synthetic>, attributes project/sub      │
└────────────────▲─────────────────────────────────────────────────┘
                 │ FileChange events
┌────────────────┴─────────────────────────────────────────────────┐
│  Watcher      FSEventStream on ~/.claude/projects (recursive)    │
└──────────────────────────────────────────────────────────────────┘

Side-attached:
  Pricing       LiteLLM table + TOML override layering + refresh
  Cache         persists aggregator state to ~/Library/Application
                Support/claudecounter-bar/cache.json
```

## 🎯 Algorithm parity with the Go TUI

The macapp's `ClaudeCounterCore` library is a byte-for-byte port of
the Go internal packages:

| Go (`tui/internal/`) | Swift (`macapp/Sources/ClaudeCounterCore/`) |
|---|---|
| `pricing/` | `Pricing.swift`, `PricingFetch.swift`, `TOML.swift` |
| `reader/` | `Reader.swift` |
| `agg/` | `Aggregator.swift` |
| `watcher/` (fsnotify) | `Watcher.swift` (FSEventStream) |
| (no equivalent) | `Cache.swift`, `AppState.swift`, `LiveEventBuffer.swift` |

The Swift test suite includes **cross-language conformance tests**
that load the same `session_normal.jsonl` and `session_malformed.jsonl`
fixtures the Go tests use, and assert identical token totals. That's
the regression net against algorithm drift.

The directory walk order is also matched to Go's `filepath.WalkDir`
(`Reader.walkDirLikeGo`) so first-seen-wins dedupe attributes shared
events between main / subagent files identically. See ["the missing
files" story in the root README](../README.md#-the-case-of-the-missing-files)
for the calibration history.

## 💾 Persistence

The aggregator state is persisted to:

```
~/Library/Application Support/claudecounter-bar/
  cache.json     ← aggregator cells + perMsg dedupe set + per-file offsets
  pricing.toml   ← in-app override (in-app refresh writes here)
```

Cache is written:
- Right after the initial scan completes (so the post-backfill state
  is durable even if the app crashes a moment later)
- Every 60s while running
- On `applicationWillTerminate` (best-effort during quit)

Read flow on launch: load cache → seed aggregator + reader offsets →
publish snapshot immediately (cached numbers visible within a frame
or two) → start FSEventStream → run incremental scan with
`notBefore = max(cache.writtenAt - 5min, min(firstOfMonth, now-35d))`
so we re-parse only the few KB modified since cache was written.

Manual **Refresh** in the popover invalidates the cache and rescans
from `min(firstOfMonth, now-35d)` — useful if you want to verify the
numbers from scratch.

## 🛠️ Pricing resolution

Order (first hit wins, falls back to bake-in defaults):

1. `~/Library/Application Support/claudecounter-bar/pricing.toml` —
   in-app override; the "⚙ → Refresh pricing" menu item writes here
2. `$XDG_CONFIG_HOME/claudecounter/pricing.toml` or
   `~/.config/claudecounter/pricing.toml` — shared with the Go TUI;
   if you've already configured pricing for the TUI, the menu bar
   app picks it up for free
3. Bake-in defaults (Swift port of the Go TUI's `pricing/defaults.go`)

The "Refresh pricing" menu item fetches LiteLLM's
`model_prices_and_context_window.json` (same source as `ccusage`),
filters Anthropic models, normalises any `anthropic/` prefix, converts
per-token → per-mtok, and writes the in-app override.

## 📁 Layout

```
Package.swift                         SPM manifest, macOS 13+, no deps
Sources/
  ClaudeCounterCore/                  headless library, all testable
    Pricing.swift                     Usage, ModelPrice, PricingTable, defaults
    PricingFetch.swift                LiteLLM JSON fetch + parse
    TOML.swift                        minimal TOML decode/encode + layering
    Reader.swift                      JSONL tail, parseLine, walkDirLikeGo
    Aggregator.swift                  TokenCounts, CivilDay, snapshot
    Watcher.swift                     FSEventStream wrapper
    Cache.swift                       JSON persist/restore
    LiveEventBuffer.swift             ring buffer for the popover live tail
    AppState.swift                    @MainActor coordinator + lifecycle
  ClaudeCounterBar/                   the macOS app target
    App.swift                         @main, AppDelegate, MenuBarExtra
    MenuBarLabel.swift                sparkline + $today, with loading pulse
    PopoverView.swift                 hero, hourly chart, tables, live tail
    Resources/                        SPM-processed resources
Tests/ClaudeCounterCoreTests/         72 unit tests
  Fixtures/                           JSONL fixtures shared with Go tests
  PricingTests.swift                  9 tests
  ReaderTests.swift                   21 tests, incl. cross-language conformance
  AggregatorTests.swift               12 tests
  WatcherTests.swift                  7 tests, incl. live FSEvents smoke test
  CacheTests.swift                    6 tests
  PricingFetchAndTOMLTests.swift      10 tests, incl. mock URL session
  AppStateTests.swift                 7 tests, incl. live pipeline + refresh
Resources/Info.plist                  CFBundle*, LSUIElement = YES
scripts/build-app.sh                  bundle .app from `swift build`
```

## 🧪 Tests

From the repo root:

```bash
make macapp-test     # cd macapp && swift test
make test-all        # Go + Swift suites
```

Or directly from `macapp/`:

```bash
swift test
```

What's covered:
- **Pricing math** — known/unknown models, all four token types, per-model defaults
- **Reader** — parse rules, dedupe-on-empty-keys, byte offsets, truncation,
  partial-line safety, project/subagent attribution, plus
  cross-language conformance against the Go fixtures
- **Aggregator** — dedupe (happy + empty-id paths), civil-day boundary,
  per-project main/sub split, multi-model per-project costing, daily
  window, hourly buckets
- **Watcher** — flag mapping (create/modify/remove/rename), live
  FSEvents smoke test (write a JSONL, assert event arrives within 5s)
- **Cache** — round-trip, missing-file (nil), corrupt-file (throws),
  invalidate, dedupe-survives-restart
- **TOML + Fetch** — decode/encode round-trip, resolution paths with
  and without `XDG_CONFIG_HOME`, mock-session fetch, non-200 raises
- **AppState** — live-buffer ordering + cap, scanCutoff in three modes,
  end-to-end FSEvents pipeline + refresh

UI is intentionally not pixel-tested (thin SwiftUI layer; visual
verification via `make macapp-run`).

## 🛠️ Makefile targets (run from repo root)

| target | what |
|---|---|
| `make macapp` | Build `.app` bundle (release) → `dist/ClaudeCounterBar.app` |
| `make macapp-debug` | Build a debug `.app` for fast iteration |
| `make macapp-test` | Run the Swift unit tests |
| `make macapp-run` | Build and launch the menu bar app |
| `make test-all` | Run Go + Swift suites |
| `make clean` | Remove `dist/`, `.build/`, `.swiftpm/`, etc. |

## 🚧 Out of scope (v1)

These were considered and deferred:

- Notarization / signed `.dmg` / Homebrew cask
- Launch-at-login UI toggle (`SMAppService.mainApp.register()` is
  available; the popover hook isn't wired yet)
- Budget alerts / red-tint when today exceeds a threshold
- Per-day or per-week popover views
- CSV export
- Sparkle auto-update

## 📜 License

MIT. See [root LICENSE info](../README.md#-license).
