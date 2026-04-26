# claudecounter-bar — macOS menu bar app

**Status:** design approved, pending implementation plan
**Date:** 2026-04-26
**Companion to:** the Go TUI (`cmd/claudecounter`) — same data, same algorithm, fully independent app

## Goal

Show today's Claude Code spend in the macOS menu bar in (near) real time, with a glanceable sparkline and a click-through dashboard. Run as either app — TUI or menu bar — never both required.

## Non-goals (v1)

- Budget alerts and threshold colors
- Per-day / per-week popover views
- CSV export
- Notarization, signed `.dmg`, `brew cask` distribution
- Auto-update (Sparkle)
- Windows / Linux

## Constraints

- **Fully standalone.** No invocation of the Go binary. No shared daemon. Either app reads `~/.claude/projects` directly.
- **Algorithm parity with the Go binary.** Parsing, dedupe, civil-day bucketing, and snapshot math are byte-for-byte ports. Cross-language conformance tests use the same JSONL fixtures.
- **macOS 13+** (for `MenuBarExtra`, `SMAppService.mainApp`).
- **Native Swift / SwiftUI.** No Electron, no Catalyst, no shell-out.

## Architecture

Same layered design as the Go app, ported to Swift:

```
┌──────────────────────────────────────────────────────────────────┐
│  SwiftUI layer (MenuBarExtra + Popover)                          │
│  - sparkline + $today in title                                   │
│  - popover with hero / chart / models / projects / live          │
└────────────────▲─────────────────────────────────────────────────┘
                 │ @Published Snapshot
┌────────────────┴─────────────────────────────────────────────────┐
│  Aggregator           keyed by (day, project, model, isSubagent) │
│                       holds Tokens(in,out,cacheCreate,cacheRead) │
│                       snapshot() applies Pricing → Totals        │
└────────────────▲─────────────────────────────────────────────────┘
                 │ UsageEvent stream
┌────────────────┴─────────────────────────────────────────────────┐
│  Reader         tails JSONL with byte offsets                    │
│                 dedupes by messageId:requestId (first-seen)      │
│                 filters <synthetic>, attributes project/sub      │
└────────────────▲─────────────────────────────────────────────────┘
                 │ file change events
┌────────────────┴─────────────────────────────────────────────────┐
│  Watcher        FSEventStream on ~/.claude/projects (recursive)  │
└──────────────────────────────────────────────────────────────────┘

Side-attached:
  Pricing       LiteLLM table + TOML overrides + LiteLLM refresh
  Cache         persists aggregator state + per-file offsets
  AppLifecycle  LSUIElement, launch-at-login, refresh, quit
```

### Module breakdown

Swift Package `ClaudeCounterCore` (testable, headless) plus the macOS app target.

| Module | Responsibility |
|---|---|
| `Watcher` | `FSEventStream` wrapper; emits `FileChange(path, kind)` |
| `Reader` | JSONL tailing, offsets, dedupe support, project/subagent attribution |
| `Aggregator` | token bucket per `(day, project, model, isSubagent)` |
| `Pricing` | LiteLLM table; TOML load with override layering; refresh from web |
| `Cache` | snapshot + offset persistence under `~/Library/Application Support/claudecounter-bar/` |
| `Snapshot` | derived `Totals` view model (today/month/by-model/by-project/live) |
| `App` | SwiftUI views, `MenuBarExtra`, popover layout |

## Algorithm contract (port of Go internals — must not drift)

The promise: same JSONL → same numbers, on Swift or Go. Every rule below is a port of behavior already in `internal/reader/reader.go` and `internal/agg/agg.go`.

### Reader rules

1. **Inclusion filter.** Any line with `message.usage` is included, regardless of `type` or `model` name. Mirrors ccusage's permissive rule.
2. **Skip rule.** Drop the line silently if:
   - `message` is null OR `message.usage` is null
   - `message.model == "<synthetic>"` (all-zero bookkeeping events)
3. **JSON field map** (exact field names that ship today):
   ```
   type, timestamp, sessionId, cwd, requestId
   message.id, message.model
   message.usage.input_tokens
   message.usage.output_tokens
   message.usage.cache_creation_input_tokens
   message.usage.cache_read_input_tokens
   ```
4. **Token type is `UInt64`** end-to-end. No `Int`. No `Double` until pricing applies.
5. **Path normalization.** Replace `\` with `/` BEFORE attribution checks (Windows-safe; harmless on macOS — kept for cross-platform parity).
6. **Subagent detection.** Exact substring match: `path.contains("/subagents/")`.
7. **Project key.** Substring after `/projects/` up to the next `/`. Empty if `/projects/` not in path.
8. **Per-file byte offset.** Dictionary `[path: Int64]`. Open, seek to offset, read to EOF.
9. **Truncation handling.** `if fileSize < storedOffset { offset = 0 }`.
10. **Incomplete tail safety.** Split on `\n` only; bytes after the last `\n` stay unconsumed; offset advances to *just past last `\n`*. Next change event picks up from there.
11. **Empty / whitespace-only line.** Skip silently.
12. **Parse error.** Increment `parseErrors` counter, continue. Never aborts the file.
13. **File removed event.** Drop from offset map (`Forget(path)`).
14. **Initial scan.** Walk `root` recursively, take every `*.jsonl` whose mtime ≥ `notBefore`, run through `OnChange`. `notBefore = min(firstOfMonth, now-35d)` matches the Go cutoff.

### Aggregator rules

15. **Dedupe key.** `"\(messageId):\(requestId)"`. Only deduped if BOTH non-empty. First-seen wins; `dupes` counter increments on dupe.
16. **Cell key.** `(civilDay, project, model, isSubagent)`.
17. **Civil day.** `(year, month, day)` in **local** timezone. Use `Calendar.current` (matches Go's `time.Now().Local()` semantics).
18. **Cost computed only at snapshot time.** Per-event accumulation is `UInt64` tokens. Pricing × tokens → `Double` once per `(scope, model)` cell.
19. **Per-project cost.** When computing per-project totals, walk cells with `model` preserved (a project may span multiple models with different prices). Don't merge cross-model tokens before applying pricing.
20. **Daily window.** Last 30 days, oldest→newest, today is last entry. Drives the menu bar sparkline.

### Watcher rules — Swift-native, same contract

21. **macOS uses FSEvents** (`FSEventStreamCreate`) with `kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot`. FSEvents is recursive by design — no manual subdir add.
22. **Filter.** Emit only for paths ending in `.jsonl`.
23. **Event mapping.** Created/Modified → drive `OnChange(path)`; Removed/Renamed → `Forget(path)`.

### Cross-language conformance tests

Reuse `internal/reader/testdata/session_normal.jsonl` and `session_malformed.jsonl`. Symlink (or check in a copy of) into `macapp/Tests/Fixtures/`. Swift tests assert the same per-token totals as the Go tests on the same input — that's the regression net against algorithm drift.

## UI structure

### Menu bar item

`MenuBarExtra` (SwiftUI, macOS 13+) with custom label view.

- **Title content:** 8-bar sparkline + `$<today>`. Sparkline data source: last 8 hours of today's spend (one bar per hour). Updates whenever the snapshot changes.
- Bar fill: SF Symbol-style green for normal. (Budget threshold red is out of scope for v1.)
- Falls back to plain `$0.00` until first snapshot is ready.

### Popover

Opens on click of the menu bar item, dismisses on outside click. Root view is a `ScrollView` (degrades gracefully on shorter screens). Approximate size: 520 × 440 px.

```
┌─ Popover ───────────────────────────────────────────────────────┐
│  $34.87  TODAY                          $5,676.51  MONTH        │
│                                                                  │
│  ┌─── Today's spend (one bar per hour, 0–23) ────────────────┐  │
│  │       ▁▂▁▃▂▅▄▃▆▇█▆▅▃▂                                    │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ By model ─────────┐  ┌─ By project (M/sub) ─────────────┐  │
│  │ opus-4-6   $3,624  │  │ project1   $2,386 (M $1,422)    │  │
│  │ opus-4-7   $1,932  │  │ project2   $2,176 (M $1,900)    │  │
│  │ sonnet-4-6   $89   │  │ project3     $252 (M   $198)    │  │
│  │ haiku-4-5    $30   │  │ …                                │  │
│  └────────────────────┘  └──────────────────────────────────┘  │
│                                                                  │
│  Live                                                            │
│   10:21:14  project1   opus    +$0.062 (sub)                    │
│   10:21:09  project1   opus    +$0.041                          │
│   10:20:48  project2   sonnet  +$0.008                          │
│                                                                  │
│  Updated 0.4s ago                          [⟳ Refresh]  [⚙]     │
└──────────────────────────────────────────────────────────────────┘
```

### Components & data feeds

| View | Data source | Update trigger |
|---|---|---|
| Hero today/month | `Snapshot.todayUSD`, `Snapshot.monthUSD` | `@Published Snapshot` |
| Hourly chart | `Snapshot.todayHourly: [UInt64]` (24 buckets in tokens, costed at render) | snapshot tick |
| By-model table | `Snapshot.modelMonth: [(String, Double, Double)]` (name, USD, pct) | snapshot tick |
| By-project table | `Snapshot.projectMonth: [(String, Double, Double, Double)]` (name, total, main, sub) | snapshot tick |
| Live tail | Ring buffer of last 50 `LiveEvent` (timestamp, project, model, USD, isSub) | each `Aggregator.apply()` |
| "Updated Xs ago" | `Snapshot.asOf` | 1 Hz timer |
| Refresh button | `Aggregator.reset() + Cache.invalidate() + InitialScan` | click |
| ⚙ menu | Launch-at-login toggle, "Refresh pricing", Quit | click |

### Snapshot tick rate

UI receives a new `Snapshot` at most every 250 ms (same debounce as the Go TUI's `pipeline()` ticker). Live tail events are emitted per-event (not debounced) so the bottom of the popover ticks visibly.

### Aggregator additions vs Go version

- `todayHourly: [UInt64]` — 24 token-by-hour buckets for today (bucket by `event.timestamp.local().hour`). Costed at render with today's average $/token ratio applied to per-hour token totals. Sparkline is for *shape*, not absolute precision — exact per-hour USD is overkill.
- `liveEvents: RingBuffer<LiveEvent>` (capacity 50) — only populated after initial scan completes (same `liveTail` gate as the Go version), so backfill doesn't flood it.

## Persistence & cache

### Location

`~/Library/Application Support/claudecounter-bar/`:

```
cache.json       aggregator state + per-file offsets
pricing.toml     local pricing override (in-app refresh writes here)
settings.json    launch-at-login toggle (and future preferences)
```

### `cache.json` schema

```json
{
  "version": 1,
  "writtenAt": "2026-04-26T14:22:11Z",
  "cells": [
    {
      "day": "2026-04-26",
      "project": "Users-jjverhoeks-src-tries-claudecounter",
      "model": "claude-opus-4-7",
      "isSub": false,
      "in": 1234567,
      "out": 89012,
      "cacheCreate": 45678,
      "cacheRead": 234567
    }
  ],
  "perMsg": ["msg_01ABC...:req_01XYZ..."],
  "offsets": {
    "/Users/.../session-uuid.jsonl": 24580,
    "/Users/.../subagents/agent-1.jsonl": 8192
  },
  "parseErrors": 0,
  "dupes": 12453,
  "unknownMsgs": []
}
```

### Write triggers

- `applicationWillTerminate` (graceful quit / Cmd-Q)
- Every 60 s while running (insurance against crashes / force-quit)
- On manual "Refresh" — *delete* cache, force full rescan, write fresh after backfill

### Read flow on launch

1. Load `cache.json` → seed `Aggregator` (cells + perMsg + counters), seed `Reader` (offsets).
2. Show numbers IMMEDIATELY (cache snapshot is the truth at this instant).
3. Start `FSEventStream`.
4. Run `InitialScan` with `notBefore = max(cache.writtenAt − 5 min, min(firstOfMonth, now−35d))`. Per-file offsets mean we re-parse very few bytes.
5. New snapshot publishes → UI ticks.

### Cache invalidation rules

Fall back to a full scan from `min(firstOfMonth, now−35d)` if any of:

- `cache.json` missing or fails to parse
- `version` mismatch
- `writtenAt` older than start of current calendar month (a month boundary crossed while quit)
- User clicked "Refresh"

### Why `perMsg` is in the cache

Without it, after a relaunch we could re-process the same `(messageId:requestId)` for any file whose offset is now zero (e.g., file truncated/rotated) and double-count. With it, dedupe survives restarts.

### Why `unknownMsgs` is in the cache

Keeps the diagnostic counter stable across launches — otherwise the popover footer would lie about parse health right after a relaunch.

### Memory note

`perMsg` grows. On a heavy month it could be ~10⁵ entries × ~80 bytes ≈ 8 MB in memory, ~3 MB on disk after JSON encoding. Acceptable. We *could* prune entries whose timestamp is older than the cell window (35 days), but YAGNI for v1.

## Pricing

### Resolution order

`PricingTable.load()` consults sources in this order; first hit wins; falls back to bake-in:

1. **In-app override** — `~/Library/Application Support/claudecounter-bar/pricing.toml`
2. **Shared with Go app** — `~/.config/claudecounter/pricing.toml` (or `$XDG_CONFIG_HOME/claudecounter/pricing.toml`)
3. **Bake-in defaults** — Swift port of `internal/pricing/defaults.go`, embedded as a resource

### Refresh

Popover ⚙ → "Refresh pricing" fetches `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`, parses Anthropic models, writes `~/Library/Application Support/claudecounter-bar/pricing.toml`, and reloads in place. Same source as the Go binary's `--refresh-pricing`.

### Failure handling

If fetch fails: keep current table, show timestamped error in popover banner, *never* silently revert to defaults.

## Error handling

Explicit, no silent failures.

| Failure | Behavior |
|---|---|
| `~/.claude/projects` missing | Popover shows "No Claude Code data found at ~/.claude/projects" with a button to choose a custom path. Menu title shows `—`. |
| `cache.json` corrupt | Log to `os_log`, delete cache, fall back to full `InitialScan`. Popover footer flags "rebuilt cache". |
| FSEventStream fails to start | Log + popover banner. UI still works on a 60 s polling fallback (same scan as `--once`). |
| Per-line JSON parse error | Increment `parseErrors`. Continue. Surface count in popover footer. |
| Unknown model (no price) | Tokens still bucketed; `unknownMsgs` set logged. Footer shows count. |
| Pricing fetch fails (refresh) | Keep current table. Show timestamped error banner. Never silently revert. |
| Time goes backward (clock skew) | `civilDay` recomputes per snapshot — self-corrects on next tick. |
| `applicationWillTerminate` interrupted | 60 s periodic flush ensures at most 60 s of state is lost. |

## Testing

### Conformance fixtures (cross-language)

Copy `internal/reader/testdata/session_normal.jsonl` and `session_malformed.jsonl` into `macapp/Tests/Fixtures/`. Swift `XCTest` parses them and asserts the same per-token totals as the Go tests. This is the regression net against algorithm drift.

### Unit tests per module

- `ReaderTests` — parse, dedupe-on-empty-keys, offset, truncation, partial line, project extraction, subagent detection, path normalization
- `AggregatorTests` — cellKey bucketing, civil-day boundary, snapshot math, daily window, per-project per-model split
- `PricingTests` — lookup miss, override layering, refresh fetch with mock URL session
- `CacheTests` — round-trip, version mismatch, corrupt file, missing-keys tolerance

### Integration test

Write a temp directory mirroring `projects/<encoded>/<sess>.jsonl` + `subagents/agent-*.jsonl`, append lines, drive `Watcher → Reader → Aggregator`, assert snapshot matches expected totals.

### UI

Light snapshot tests on view models (not pixel diffs). The popover layout itself is visually verified, like the Go TUI.

## Build & distribution (v1)

### Project layout

```
macapp/
  ClaudeCounterBar.xcodeproj/
  Sources/
    ClaudeCounterCore/      # Swift package, headless, testable
      Watcher.swift
      Reader.swift
      Aggregator.swift
      Pricing.swift
      Cache.swift
      Snapshot.swift
    ClaudeCounterBar/       # macOS app target
      App.swift
      MenuBarLabel.swift
      PopoverView.swift
      ChartView.swift
      LiveTailView.swift
      SettingsMenu.swift
  Tests/
    ClaudeCounterCoreTests/
    Fixtures/               # symlinks to ../../internal/reader/testdata/
```

### Targets

- App: `ClaudeCounterBar.app`, depends on `ClaudeCounterCore`
- `Info.plist`: `LSUIElement = YES` (no Dock icon, menu-bar-only)
- macOS deployment target: **macOS 13** (for `MenuBarExtra` and `SMAppService.mainApp`)
- Launch-at-login via `SMAppService.mainApp.register()` toggled from popover ⚙
- Signing: ad-hoc local for dev; notarization deferred

### Makefile target

A `make macapp` target invokes `xcodebuild` for the Release configuration of the `ClaudeCounterBar` scheme and copies the resulting `.app` into `dist/`. Exact incantation (xcodebuild flags, derived data path, copy command) is filled in by the implementation plan, not the design.

### Versioning

`v1.0.0` for first menu bar release. Tag and release alongside the next Go binary release.

## Open questions

None at design time. Implementation may surface integration questions (FSEvents coalescing behavior on heavy bursts, Swift `JSONDecoder` performance vs streaming for the 47k-event backfill) — those will be flagged in the implementation plan.

## Acceptance criteria

A user with the Go TUI already running can:

1. Build and launch `ClaudeCounterBar.app` on the same machine.
2. See today's cost in the menu bar within ~1 s of launch (cache hit) or ~5–15 s (cold start).
3. Watch the menu bar number tick up in near-real-time as Claude Code writes new JSONL lines.
4. Open the popover and see today / month / by-model / by-project / live tail — values matching the TUI to the cent at any moment.
5. Quit and relaunch without a measurable rescan delay.
6. Click "Refresh" and see numbers reconverge after a full rescan.
7. Click ⚙ → "Refresh pricing" and see the table update.
8. Toggle "Launch at login" and have the app start on next login.
