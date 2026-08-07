# Usage limits & utilisation gauges — design

**Date:** 2026-08-07
**Status:** approved, ready for planning
**Scope:** Spec 1 of 2. Spec 2 (deferred) is the Codex USD ingestion path.

## Problem

`claudecounter` reports what you *spent* but never what you have *left*. There is
no configured ceiling, so a number like `Month $5,676.51` carries no signal about
whether that is fine or alarming. Separately, the Codex and Grok CLIs both run
against plan limits that can hard-stop work, and nothing surfaces those either.

This spec adds two kinds of number:

1. **Budget** — a user-configured USD limit per day and per week, with a stacked
   bar showing spend against it.
2. **Plan** — vendor-reported utilisation percentages, read from the vendors' own
   local logs. Not configured, not in USD, windows defined by the vendor.

They are **displayed together, grouped by window duration**, because that is how
the question gets asked — "how close am I to a wall in the next few hours?"
spans both kinds. They are **never arithmetically combined**: a budget percentage
and a plan percentage are different measurements over different windows, and the
detail column beside each bar is what keeps them distinguishable.

## Data reality

Established empirically against local logs on 2026-08-07. This table is the
constraint the whole design follows from:

| Vendor | USD / billable tokens | Vendor-reported % |
|---|---|---|
| Claude | yes — already computed by `agg` + `pricing` | **no** — absent from local transcripts |
| Codex  | yes — `last_token_usage` deltas (Spec 2) | yes — **5h** and **weekly** |
| Grok   | **no** | yes — **weekly only** |

### Claude

Existing path, unchanged: `~/.claude/projects/**/*.jsonl` → `reader` → `agg`.

Claude does **not** log its own rate-limit utilisation locally. Scanning the 60
most recent transcripts for `five_hour`, `used_percent`, `resets_at`,
`rate_limit*` and `usage_limit*` as real JSON keys (with `tool_result` content
stripped) produced no genuine hits — every apparent match was vendor JSON or
source text quoted inside a tool result.

The only known source is the private endpoint
`https://claude.ai/api/organizations/{orgId}/usage`, which returns
`five_hour.utilization` and `five_hour.resets_at`. It authenticates with a
browser session cookie.

**Explicitly out of scope.** Reading it would mean shipping code that handles a
long-lived credential granting full account access, against an undocumented
endpoint that can change without notice. Claude therefore has a budget gauge and
no plan gauge. If this is revisited, it is its own spec with its own security
review.

### Codex — `~/.codex/sessions/**/*.jsonl`

Payloads of `type: "token_count"` carry a `rate_limits` object:

```json
{"limit_id": "codex", "plan_type": "plus",
 "primary":   {"used_percent": 92.0,  "window_minutes": 300,   "resets_at": 1783868452},
 "secondary": {"used_percent": 30.0,  "window_minutes": 10080, "resets_at": 1784376231}}
```

Two windows exist: **300 minutes (5h)** and **10080 minutes (7d)**.

**The slot names are not stable across CLI versions.** Measured across the 40
most recent session files: `(primary, 10080)` 6980 events, `(primary, 300)` 283,
`(secondary, 10080)` 283. Older sessions put 5h in `primary` and weekly in
`secondary`; newer ones put weekly in `primary` and omit the 5h window.
`limit_id` was seen as both `"codex"` and `"premium"`.

> **Reader rule: key on `window_minutes`. Never on the slot name or `limit_id`.**

Blocks are frequently `null`; skip those.

### Grok — `~/.grok/logs/unified.jsonl`

Lines with `msg: "billing: fetched credits config"`:

```json
{"ts": "2026-08-07T18:31:51.535Z", "msg": "billing: fetched credits config",
 "ctx": {"config": {"creditUsagePercent": 14.0,
                    "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
                                      "start": "2026-07-31T20:00:10.825033+00:00",
                                      "end":   "2026-08-07T20:00:10.825033+00:00"},
                    "onDemandCap": {"val": 0}, "onDemandUsed": {"val": 0},
                    "prepaidBalance": {"val": 0}},
         "subscriptionTier": "SuperGrok"}}
```

All 105 billing events observed were `USAGE_PERIOD_TYPE_WEEKLY`. There is no
daily or 5h period. The period is vendor-anchored — Thursday 20:00 UTC to
Thursday 20:00 UTC — and does not align with an ISO week.

Grok's session transcripts (`sessions/**/updates.jsonl`) carry only
`_meta.totalTokens`, which is **cumulative context per prompt**: within one
`promptId` it climbs 1069 → 5474 → … → 110042. It is context size, not billable
tokens, and there is no input/output/cache split. **Grok gets no USD figure in
this spec or any other until xAI logs real token accounting.** Summing that field
overcounts by roughly an order of magnitude; taking a per-prompt max is a
different unit entirely.

## Window semantics

The binary must have exactly one definition of "today" and "this week".

**Budget gauge** reuses what already exists:

- Day — local calendar day, per `agg.dayOf` (`tui/internal/agg/agg.go:83`).
- Week — ISO week, per `report.go:74` (`lt.ISOWeek()`).

**Plan gauges** use the vendor's window verbatim and are labelled with it. Three
of the four windows are rolling or vendor-anchored, and **none align with the ISO
week**. They are not normalised and not reconciled — a Codex 7d-rolling figure
legitimately differs from the ISO-week USD figure, and the UI must make that
obvious rather than invite the reader to treat it as a bug.

Labels are distinct by construction: `daily $`, `weekly $`, `codex 5h`,
`codex 7d`, `grok wk`.

## Configuration

One TOML file, read by both apps, so they cannot disagree:

```toml
# ~/.config/claudecounter/limits.toml
[limits]
daily    = 50.0   # USD, 0 or absent = unset
weekly   = 250.0  # USD, 0 or absent = unset
warn_pct = 80     # amber threshold, applies to both windows
```

`warn_pct` is deliberately a single threshold for both windows. Per-window
thresholds are trivial to add later and are not needed now.

Plan gauges take no configuration — they are discovered from the vendor logs or
absent.

## Components

### `tui/internal/limits` (new)

Pure evaluation over an existing snapshot. No I/O on the hot path.

```go
type Config struct{ Daily, Weekly float64; WarnPct int }

type Window int // Day | Week
type State  int // Unset | OK | Warn | Over

type Status struct {
    Window             Window  // Day | Week
    SpentUSD, LimitUSD float64
    Pct                float64
    State              State
    ResetsAt           time.Time
}

func Load(path string) (Config, error)
func Evaluate(daily []agg.DailyTotal, cfg Config, now time.Time) []Status
```

`Evaluate` is a pure function of its arguments — no clock, no filesystem — which
makes the window-boundary cases directly table-testable.

### `tui/internal/planlimits` (new)

One scanner per vendor, each returning the same shape:

```go
type Gauge struct {
    Vendor    string    // "codex" | "grok"
    WindowLbl string    // "5h" | "7d" | "wk"
    Pct       float64
    ResetsAt  time.Time
    Observed  time.Time // when the vendor wrote this figure
    Stale     bool      // ResetsAt is in the past
    Plan      string    // "plus" | "SuperGrok" | ""
}

func ScanCodex(root string, now time.Time) ([]Gauge, error)
func ScanGrok(path string, now time.Time) ([]Gauge, error)
```

**Both gauges are point-in-time snapshots, not time series.** Each scanner takes
the single most recent observation — Codex: newest `token_count` carrying a
non-null block, per `window_minutes`, across all session files; Grok: newest
`billing:` line in `unified.jsonl` — and never aggregates across events.

**Staleness is mandatory, not decorative.** If `ResetsAt` has passed, the window
has rolled over and the percentage describes a period that has ended. Such a
gauge renders dimmed with its age, never as a current value. Silently showing
last week's 100% is the specific failure this guards against.

A vendor directory that is absent, unreadable, or contains no usable observation
yields no gauges and no error surface — these are optional inputs.

Scanning is on demand, off the live counting path, following the precedent set by
`report` and `safety`.

**Scan cost is a real constraint, not a detail.** The local corpus is large — 67
Codex session files, individual Grok transcripts over 100 MB, and a 3 MB
`unified.jsonl`. Because both scanners want only the *newest* observation:

- Walk candidate files newest-first by mtime and stop as soon as every window has
  an observation newer than its own `resets_at`.
- Read `unified.jsonl` tail-first and stop at the first `billing:` line.
- Skip any file whose mtime predates the oldest window still being sought.
- Never parse Grok's `sessions/**/updates.jsonl` at all — it holds no billing
  data, and it is where all the size is.

### Renderer — `tui/internal/ui/charts.go`

Rows are grouped by **window duration**, not by gauge type. A reader comparing
"how close am I to a wall right now" wants the short windows together, regardless
of whether the number came from a configured budget or from a vendor.

```go
type Segment struct {
    Label string
    USD   float64
    Style lipgloss.Style
}

// A Row is one rendered line. Exactly one of Budget / Plan is set;
// NotApplicable renders the dimmed "n/a" placeholder.
type Row struct {
    Vendor        string
    WindowLbl     string // "daily" | "5h" | "wk" | "7d"
    Budget        *limits.Status
    Segments      []Segment          // stacked fill, budget rows only
    Plan          *planlimits.Gauge
    NotApplicable string             // reason, e.g. "weekly only"
}

func BuildRows(band Band, st []limits.Status, gs []planlimits.Gauge) []Row
func renderGaugeGroup(title string, rows []Row) string
```

Two orderings are load-bearing and both are specified, because they can disagree:

- **Display order** is fixed per group — `claude`, `codex`, `grok` — regardless of
  value. `BuildRows` synthesises the dimmed `n/a` row when a vendor has no
  observation in that band, so the row set is stable and a vendor never silently
  vanishes between refreshes.
- **Glyph escalation order** is by descending `Pct` across **non-stale** rows in
  both groups; the worst one drives the menu bar colour.

Display order is deterministic and part of the cross-language parity contract;
escalation order is value-dependent. Conflating them is how the menu bar ends up
contradicting the popover.

Two groups: **short window** and **weekly**.

**A group title is a rough duration band, not a shared window definition.** The
weekly group holds three genuinely different weeks — ISO Mon–Sun, Codex's 7-day
rolling, and Grok's Thursday-20:00-UTC billing period — and the short group holds
a local calendar day beside a 5-hour rolling window. Each row's own window is
authoritative, so `WindowLbl` is **always rendered, including on budget rows**:
`claude daily` must read as an explicitly calendar-day row sitting next to
`codex 5h`. Without that, the grouping invites exactly the "these numbers
disagree, it's a bug" reading this design is trying to prevent.

```
── short window ────────────────────
 claude daily  ███████░░░  78%  $39/$50
 codex  5h     █████████░  92%  ↻ 2h14m
 grok   —      n/a (weekly only)
── weekly ──────────────────────────
 claude wk     █████░░░░░  52%  $130/$250
 codex  7d     ██████████ 100% ⚠
 grok   wk     █░░░░░░░░░  14%  ↻ Thu
```

Every row displays a percentage, so the bars are visually comparable — but the
percentages have **two different meanings**, and the detail column is what
distinguishes them. A budget row shows `$spent/$limit`; a plan row shows its
reset time. This is deliberate: it lets a reader scan the bars for urgency while
keeping the provenance of each number legible.

Grok has no short window (all observed billing periods were weekly), so its
short-window row is a dimmed `n/a` placeholder rather than an omission. Showing
the gap explicitly is better than a silently missing row that reads as "no usage".

**Stacking and Spec 2.** `Segments` is stacked from the start. In Spec 1 the
budget rows carry a single Claude segment and are labelled `claude`. When Spec 2
adds Codex USD it becomes a second segment in those same rows, which relabel to
`spend` — the renderer does not change, only its input does. This is the whole
reason the stacking work happens now rather than later.

### Surfaces

**TUI** — gauge block at the top of the minimal and split views;
`claudecounter --limits` for one-shot/scripted use.

**macapp** — `Limits.swift` and `PlanLimits.swift` in `ClaudeCounterCore`,
mirroring the Go logic and reading the same `~/.config/claudecounter/limits.toml`
and the same vendor logs. The popover shows the identical two groups — short
window, then weekly — with the same rows, the same `n/a` placeholder, and the same
`$spent/$limit` vs reset-time detail column. SwiftUI `ProgressView`-style bars
replace the block characters; the information and its order do not change.

The menu bar glyph escalates on the **worst row in either group**, budget or plan:
amber at `warn_pct`, red at 100%. This reuses the warning-glyph machinery from
`38219a5` / `1eb8c10`. Stale rows never drive the glyph — an expired window must
not paint the menu bar red.

macapp lands in the same spec as the TUI rather than a follow-up, because the
cross-language parity test below is only meaningful if both sides exist.

## Error handling

| Condition | Behaviour |
|---|---|
| Config file missing | Limits unconfigured; budget gauge hidden. **Not** a zero limit. |
| Config malformed | Logged once; treated as unset. Never crashes the counting path. |
| `daily`/`weekly` ≤ 0 | That window is unset; the other still applies. |
| Vendor dir/log absent | Vendor's rows omitted entirely. Not an error. |
| Vendor log unparseable | Skip the line, keep scanning. Partial data beats none. |
| `ResetsAt` in the past | Row renders dimmed and labelled stale; never drives the menu bar glyph. |
| Vendor has no such window | Dimmed `n/a` row with the reason (Grok short window). |
| Both budget limits unset | Budget rows omitted; plan rows still render. The gauge is useful without any config. |

The governing rule: **nothing here may break cost counting.** Limits and plan
gauges are strictly additive; every failure degrades to "gauge not shown".

## Testing

**`limits.Evaluate`** — table tests on the boundaries: exactly at limit, one cent
over, limit unset, both unset, `warn_pct` crossing, and ISO-week rollover across a
calendar-year boundary (where ISO week and calendar year disagree).

**`planlimits`** — fixture files checked into `testdata/`, covering: the old Codex
layout (5h in `primary`, weekly in `secondary`), the new layout (weekly in
`primary`, no 5h), `null` blocks interleaved with real ones, mixed `limit_id`
values, a Grok billing line, and an expired-period Grok line that must come back
`Stale: true`. The old/new Codex layouts are the regression guard on the
key-by-`window_minutes` rule.

**Renderer** — golden strings covering: both groups fully populated, over-100%,
the Grok `n/a` placeholder, a stale row, budget rows absent (no config), and
plan rows absent (no vendors installed).

**Cross-language parity** — shared fixture inputs must yield identical `Pct`,
`State`, `Stale` and **row order** in Go and Swift. Row order is part of the
contract, not a rendering detail: the two apps disagreeing about which row is
worst would make the menu bar glyph contradict the popover. This is the test that
stops the two apps drifting, and it is the one that must not be skipped.

## Deferred to Spec 2

- Codex USD: summing `last_token_usage` deltas. Note that summing overshoots the
  session's own `total_token_usage` by 0.3–0.7% (repeated events), so dedupe by
  `eventId` is required.
- Codex model resolution for pricing, via
  `event_msg → thread_settings_applied → thread_settings.model` (e.g.
  `gpt-5.6-sol`); `turn_context` carries no model field.
- A Codex pricing table alongside the existing LiteLLM Claude table.
- Adding the Codex segment to the stacked budget bar.

## Out of scope

- Org-wide/enterprise usage across seats. This is local-machine usage only.
- Any use of the claude.ai session-cookie endpoint (see *Claude*, above).
- Grok USD, at any level of approximation.
- Token-denominated limits. Limits are USD.
- Enforcement. These gauges inform; they never block or throttle.
