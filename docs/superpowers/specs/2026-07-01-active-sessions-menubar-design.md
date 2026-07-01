# Active Sessions in the Mac menu bar — design

## Goal

Replace the popover's bottom "Live" event tail with an **Active Sessions**
panel that shows, per live Claude Code session: session cost, last-5-minute
cost, context size, cache usage, and age in turns. Surface warnings when a
session runs too long, its context grows too large, or it burns money
re-creating cache. Escalate the two urgent warnings to macOS notifications,
and turn the menu-bar spend label red whenever any active session is in a
warning state.

This is a menu-bar-app-only change (`macapp/`). The Go TUI is untouched.

## Background (verified facts)

- `UsageEvent` (see `Reader.swift`) already carries `sessionID`, `cwd`,
  `project`, `model`, `timestamp`, `isSubagent`, and a `Usage`
  (`input` / `output` / `cacheCreate` / `cacheRead`).
- **Subagent transcripts share the parent's `sessionId`.** Confirmed against
  on-disk data: a `.../<session-uuid>/subagents/agent-*.jsonl` line has the
  same `sessionId` as `.../<session-uuid>.jsonl`, plus `isSidechain: true`.
  So grouping by `sessionId` folds subagent cost into the parent session,
  while the existing path-derived `isSubagent` flag lets us exclude subagent
  turns where they don't belong (context size, age-in-turns).
- The `Aggregator` sums tokens into `(day, project, model, isSub)` cells and
  discards "latest turn" and per-session identity. It therefore cannot answer
  "current context size" or "age in turns" — these need a **separate
  session tracker** consuming the same event stream. The `Aggregator` is not
  extended.
- Dedup (`messageID:requestID`, first-seen-wins) currently lives inside
  `Aggregator.apply`. The tracker must not double-count, so dedup stays a
  single source of truth (see §3).
- `PricingTable.cost(model:usage:)` sums per-component costs, so the
  cache-creation cost alone is `cost(model, Usage(cacheCreate: n))`.
- The startup scan replays ~35 days of events every launch, so session state
  rebuilds on boot. **No cache-file / `CacheFile` changes are needed** —
  active sessions are recent by definition.

## Components

### 1. `SessionTracker` (new actor, `ClaudeCounterCore`)

Consumes `UsageEvent`s (post-dedup) and holds one accumulator per `sessionId`.

```
struct SessionAgg {
    var sessionID: String
    var project: String            // canonical project key
    var latestMainModel: String    // model of the latest main turn
    var firstTS: Date
    var lastTS: Date               // any turn (main or sub)
    var mainTurns: Int             // billable non-subagent turns
    var subTurns: Int
    var totalCostUSD: Double        // main + sub
    var cacheCreateCostUSD: Double  // cache-creation component only
    var latestMainTS: Date          // timestamp of latest main turn
    var latestMainContextTokens: UInt64  // input+cacheRead+cacheCreate of that turn
    var peakContextTokens: UInt64        // max context ever seen (main turns) — window inference
    var recent: [(ts: Date, usd: Double)]  // trailing turns for 5-min cost
}
```

`apply(_ ev: UsageEvent)` (tracker holds a `PricingTable` ref, updated via
`setPricing`):

- `usd = pricing.cost(ev.model, ev.usage)`; `totalCostUSD += usd`.
- `cacheCreateCostUSD += pricing.cost(ev.model, Usage(cacheCreate: ev.usage.cacheCreate))`.
- Update `firstTS = min`, `lastTS = max`.
- Append `(ev.timestamp, usd)` to `recent`; drop entries older than 5 min
  (also capped at a small length as a backstop).
- If **not** subagent:
  - `mainTurns += 1`.
  - `ctx = ev.usage.input + ev.usage.cacheRead + ev.usage.cacheCreate`.
  - `peakContextTokens = max(peakContextTokens, ctx)`.
  - If `ev.timestamp >= latestMainTS`: set `latestMainTS`, `latestMainModel`,
    `latestMainContextTokens = ctx`. **(Picked by timestamp, not apply
    order — the Reader applies subagents first for dedup.)**
- Else `subTurns += 1`. (Subagent turns contribute cost only; never context
  or age-in-turns.)

`snapshot(now:) -> [SessionStat]`:

- Prune sessions with `lastTS < now − 6h` (bounds memory; can't be active).
- For each remaining session compute a `SessionStat` (below).
- `isActive = lastTS >= now − activeWindow` (default 15 min).
- Return only active sessions, sorted by last-5-min cost descending.

`SessionStat` (Sendable snapshot for the UI + notification layer):

```
struct SessionStat {
    let sessionID: String
    let project: String
    let model: String
    let costUSD: Double
    let cost5mUSD: Double
    let contextTokens: UInt64
    let contextWindow: UInt64      // inferred limit
    let contextPct: Double         // contextTokens / contextWindow, clamped 0…1
    let cacheCreateCostUSD: Double
    let turns: Int                 // main turns
    let ageSeconds: Int            // lastTS − firstTS
    let warnings: SessionWarnings  // OptionSet: .turns, .context, .cache
}
```

**Context window inference** — `inferredWindow(peakContextTokens:) -> UInt64`:
default `200_000`; if `peakContextTokens > 200_000`, return `1_000_000`
(the 1M beta). Mirrors the claudeinsights "infer 1M window from peak" rule
rather than hardcoding per model.

### 2. Thresholds & warnings

`SessionWarnings: OptionSet` with `.turns`, `.context`, `.cache`. Computed in
`snapshot` from persisted thresholds (see `AppSettings`, §6), defaults:

| Warning | Condition | Default | Notification? |
|---|---|---|---|
| `.turns`   | `turns > turnWarnCount`          | 150   | no (in-app only) |
| `.context` | `contextPct > contextWarnPct`    | 0.80  | yes |
| `.cache`   | `cacheCreateCostUSD > cacheWarnUSD` | 2.00 | yes |

### 3. Dedup boundary

`Aggregator.apply` becomes `@discardableResult func apply(_:) -> Bool`,
returning `true` when the event was newly counted (not a dupe). Existing
callers ignore the result (source-compatible). `AppState` feeds the tracker
only on `true`:

```
let applied = await aggregator.apply(ev)
if applied { await tracker.apply(ev) }
```

Applied at all three ingestion sites: `start()` backfill, `refresh()`
backfill, and `handle(change:)`. This keeps one dedup source and never
double-counts turns.

### 4. `AppState` wiring

- Own a `SessionTracker` alongside the `Aggregator`; forward `setPricing`.
- New published state:
  - `@Published var activeSessions: [SessionStat] = []`
  - `@Published var hasActiveWarning: Bool = false`
- In `publishSnapshot()`: after the aggregator snapshot, call
  `tracker.snapshot(now:)`, assign `activeSessions`, set `hasActiveWarning =
  activeSessions.contains { !$0.warnings.isEmpty }`, then run notification
  dispatch (§6).
- `refresh()` clears tracker state (add `tracker.reset()`), matching how it
  resets the aggregator.

### 5. UI

**`ActiveSessionsSection`** replaces `LiveTailSection` in `PopoverView`
(same slot at the bottom of the scroll area). Compact 2-line rows echoing
`ByProjectTable`:

```
Active sessions
claudecounter · opus                    $4.21
  ctx 82% ▓▓▓▓░  5m $0.12  143t  1h20m  ⚠

2026-05-19-aws-summit · sonnet          $0.88
  ctx 34% ▓▓░░░  5m $0.05   28t  12m
```

- Line 1: short project · model · total session cost.
- Line 2: context % (with a thin proportional bar), last-5m cost, turns,
  wall-clock age, and warning glyphs (SF Symbols) with `.help()` tooltips —
  e.g. context = `exclamationmark.triangle`, cache = `flame`, turns =
  `clock.badge.exclamationmark`. Warned rows tinted.
- Empty state: "No active sessions."
- `LiveEvent` / `LiveEventBuffer` and the `state.live` plumbing are removed
  (the live tail is fully replaced, not hidden). Cache format is unaffected.

**`MenuBarLabel`**: wrap the existing `HStack` in a rounded red capsule
(`Capsule().fill(.red)`, white foreground) when `state.hasActiveWarning`,
else render as today. Animated with the existing `.animation` idiom.

### 6. Notifications (`Notifications.swift`, new)

- `UNUserNotificationCenter`. Request authorization once on launch
  (`applicationDidFinishLaunching`). If denied / not-determined-and-denied,
  posting is a silent no-op — in-app warnings and the red capsule still work.
- Fires for `.context` and `.cache` only (per product decision; `.turns`
  is in-app only).
- **Debounce**: `AppState` holds `notified: Set<String>` keyed
  `"<sessionID>|context"` / `"<sessionID>|cache"`. On each snapshot, for every
  active session and each notifying condition currently set, post a
  notification only if the key is absent, then insert it. Remove keys for
  sessions no longer active (so a fresh flare-up after the session goes idle
  and returns can re-notify). Guarantees one notification per session per
  condition per active streak — no per-turn storm.
- The **crossing computation** is factored into a pure function
  `newlyTriggered(active:, alreadyNotified:) -> (toPost: [Notification],
  nextNotified: Set<String>)` so it is unit-testable without the notification
  center.
- ⚙ menu gains a "Session alerts" toggle bound to
  `settings.notificationsEnabled`; when off, dispatch is skipped entirely.

### 7. `Settings` additions

`AppSettings` gains (each with a default and a `UserDefaults` fallback path,
matching the existing `dockIconEnabled` pattern):

- `notificationsEnabled: Bool = true`
- `turnWarnCount: Int = 150`
- `contextWarnPct: Double = 0.80`
- `cacheWarnUSD: Double = 2.00`
- `activeWindowMinutes: Int = 15`

`UserDefaultsSettingsStore` reads/writes each under the existing
`ClaudeCounterBar.AppSettings.*` namespace, using `object(forKey:)` so a
missing key falls through to the default (never coerced to zero/false). Only
the "Session alerts" toggle is surfaced in the ⚙ menu for v1; the numeric
thresholds are persisted and tunable via `defaults write` (a future settings
pane can bind them).

## Testing

`SessionTrackerTests`:

- Turn counting: N main + M sub events → `turns == N`, cost includes all.
- Context = latest **main** turn's `input+cacheRead+cacheCreate`, selected by
  timestamp even when a later-*applied* subagent event has a bigger context
  and an earlier timestamp.
- Subagent turns never change `contextTokens` or `turns`, but do add cost.
- 5-min cost excludes turns older than 5 min (injected clock).
- `cacheCreateCostUSD` equals the cache-creation component only.
- `inferredWindow`: peak ≤ 200k → 200k; peak > 200k → 1M; `contextPct`
  clamped to ≤ 1.
- `isActive` filter and 6h prune honor the injected `now`.
- Warning thresholds flip exactly at the configured boundaries.

`NotificationsTests`: `newlyTriggered` posts once per (session, condition),
suppresses on repeat, and re-arms after a session leaves the active set.

`AppStateTests`: `hasActiveWarning` is true iff some active session warns;
tracker is fed only on non-dupe applies (no double counting).

Existing aggregator/reader/cache tests must stay green (the `apply` return
value is additive).

## Out of scope

- Go TUI changes.
- Cache-format / `CacheFile` changes.
- A full settings window (only the notification toggle is added to the menu).
- Historical / inactive session browsing — this panel is live sessions only.
