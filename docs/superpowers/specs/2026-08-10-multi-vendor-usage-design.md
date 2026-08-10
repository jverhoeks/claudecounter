# Multi-vendor per-model usage — design

**Date:** 2026-08-10
**Status:** approved, ready for planning
**Scope:** configurable sources, Grok ingestion, and the grouping control. Codex
ingestion is deferred to a follow-up spec.

> **Size warning.** This is larger than the usage-limits work that preceded it. It
> adds two dimensions to the aggregation key (touching both languages and the
> macapp's persisted cache), a new ingestion path, a new aggregator capability
> (vendor-supplied cost), a config file with a GUI editor, and a four-mode grouping
> control on two surfaces. It is a candidate for decomposition — the natural seam
> is *configurable sources + the source dimension* first, then *Grok ingestion +
> grouping*. Decide before planning, not during.
**Supersedes a claim in:** `docs/superpowers/specs/2026-08-07-usage-limits-design.md`
(see *Correction* below).

## Problem

`claudecounter` reports per-model spend for Claude only, from a single hardcoded
root. Three gaps follow from that:

1. Codex and Grok usage is invisible in the monthly per-model breakdown and the
   daily/monthly charts, even though both vendors record it locally.
2. There is no way to look at one model, or to collapse a whole vendor into one
   series — the breakdown is always per-model, always Claude.
3. A user with more than one Claude subscription (a work seat and a personal plan,
   each with its own config tree) has no way to monitor both, let alone tell them
   apart.

## Correction to the previous spec

The 2026-08-07 spec states, and the shipped `README.md` repeats, that Grok
transcripts "log cumulative context size, not billable tokens" and that Grok can
therefore never carry a dollar figure. **That is wrong.**

It was concluded from `sessions/**/updates.jsonl` `_meta.totalTokens`, which is
indeed a cumulative per-prompt context total. But the same file emits
`sessionUpdate: "turn_completed"` events carrying a full `usage` object that was
never inspected:

```json
{"inputTokens": 941852, "outputTokens": 8543, "totalTokens": 950395,
 "cachedReadTokens": 869376, "reasoningTokens": 4610, "modelCalls": 15,
 "apiDurationMs": 134296, "costUsdTicks": 4620228000,
 "modelUsage": {"grok-4.5-build": { … same shape … }}, "numTurns": 15}
```

Grok therefore has the **best** data of the three vendors: a full token breakdown,
a per-model split, and a cost it reports directly rather than one we compute.

`README.md` must be corrected as part of this work. The correction is factual and
should not wait for the implementation.

## Data reality

Established empirically on 2026-08-10 against the local corpus.

| Vendor | Billable tokens | Per-model split | Cost |
|---|---|---|---|
| Claude | yes (existing path) | yes | computed from the LiteLLM table |
| Codex | yes — `last_token_usage` deltas | yes — `thread_settings_applied.model` | needs the LiteLLM parser widened past Anthropic |
| Grok | yes — `turn_completed.usage` | yes — the `modelUsage` map | **reported directly** — no pricing table |

### Grok — the four probes

**Records are per-prompt, not cumulative.** In the session with the most usage
events: 23 events, 23 distinct `prompt_id`s, `totalTokens` non-monotonic. They sum.
This is the opposite of `_meta.totalTokens` and is what makes aggregation valid.

**Coverage is recent and partial.** `usage` is present on 161 of 454
`turn_completed` events overall (35%), but that splits sharply by time:

| month | turns | with usage | |
|---|---|---|---|
| 2026-07 | 348 | 70 | 20% |
| 2026-08 | 98 | 90 | **92%** |

xAI added the field recently. Presence does not correlate with `stop_reason` —
`end_turn` appears both with usage (146) and without (249) — so the split is a CLI
version boundary, not a semantic one. **Current data is trustworthy; historical
months undercount.** This drives the *Partial-coverage reporting* section below.

**`costUsdTicks` is nano-dollars.** Confirmed by elimination against the billing
period: the 85 prompts inside `2026-08-07 .. 2026-08-14` sum to 926,427,196,000
ticks — **$926.43** at 1e-9, versus $926,427 at 1e-6. Only the nano reading is
physically possible for one week of usage.

**Subagents do not double-count.** Grok subagent files (`subagents/`,
`subagent-*`) carry 1 usage event across 8 files, against 160 across 89
main-session files. The parent's `modelUsage` is where the accounting lands, so
scanning every file is safe. Contrast Claude, where `agg` deliberately splits
`MainUSD`/`SubUSD`.

## Components

### Configurable sources

Today the roots are hardcoded: `~/.claude/projects` for Claude, and the vendor
paths for the plan gauges. A user may run more than one Claude subscription — a
work seat and a personal plan — each with its own config tree (`CLAUDE_CONFIG_DIR`
gives each account a separate one). The same applies to other vendors.

**Transcript content cannot distinguish accounts.** Probing the 40 most recent
Claude transcripts, the only account-shaped field in the JSONL is
`userType: "external"`, with a single value across 1079 records. Real identity
lives in `~/.claude.json` → `oauthAccount.accountUuid` / `emailAddress`, which is
machine-global and reflects whoever is logged in *now* — switch accounts and past
transcripts become unattributable. **The root path is therefore the only
discriminator available**, which is what this design uses.

Sources are declared in `~/.config/claudecounter/sources.toml`, a sibling of the
existing `limits.toml`:

```toml
[[source]]
vendor = "claude"
label  = "work"
root   = "~/.claude/projects"

[[source]]
vendor = "claude"
label  = "personal"
root   = "~/.claude-personal/projects"

[[source]]
vendor = "grok"
label  = "personal"
root   = "~/.grok/sessions"
```

`vendor` selects the reader; `label` is the user's name for that subscription or
install. **When the file is absent, the current hardcoded roots are used as an
implicit source list** with labels defaulting to the vendor name — so a user who
never opts in sees no change whatsoever. A configured `root` that does not exist
contributes nothing and is not an error, matching how absent vendors already
behave.

The macapp gets a GUI editor for this list, so a user need not hand-edit TOML. It
writes the same file the TUI reads, following the precedent set by `limits.toml`
being shared between the two surfaces.

### Vendor and source as first-class dimensions

`reader.Event` gains `Vendor string` and `Source string`. Both are set from **which
configured root the event's file came from**, not inferred from the model name.
Inference was considered and rejected: it is guessing from a string the vendor
controls, and it already fails on real data — Codex emits `codex-auto-review`,
which no prefix rule classifies.

`agg`'s cell key becomes `(day, project, source, vendor, model, isSub)`. The
per-model maps in `Totals` key on a `SeriesKey{Source, Vendor, Model}` rather than
a bare model string.

Vendor is stored alongside source rather than resolved from it at snapshot time.
The redundancy is deliberate: a label removed from the config would otherwise leave
its cached cells (the macapp persists totals between runs) with no way to determine
their vendor.

This is the widest change in the spec: it touches `Totals`, every consumer of
`Day`/`Month`, the macapp's persisted cache, and its `usdByModel`, `tokensByModel`
and `hourlyUSDByModel` maps — in both languages.

### Grok ingestion

Source: `~/.grok/sessions/**/updates.jsonl`. Read events where
`params.update.sessionUpdate == "turn_completed"` **and** `usage` is present.

- **Dedupe on `prompt_id`** — verified unique per usage record.
- **Day attribution** from the top-level `timestamp` (Unix seconds), local day, matching `agg.dayOf`.
- **Tokens** map onto the existing `TokenCounts`: `inputTokens`, `outputTokens`, `cachedReadTokens`, `reasoningTokens`.
- **Per-model** — one cell per key of `modelUsage`, not one cell per turn. The top-level totals are the sum across `modelUsage` and must **not** be added on top of it.
- **Never read** `sessions/**` for anything else. `_meta.totalTokens` is cumulative context and is not usage.

### Authoritative cost — a new aggregator capability

`agg.Snapshot` currently derives USD from tokens via the pricing table for every
cell. Grok cells carry an authoritative USD (`costUsdTicks / 1e9`) that must be
used **as given**.

This is a change to the aggregator's contract, not a detail. A cell is either
*priced* (tokens + a pricing lookup, as today) or *costed* (a USD the vendor
supplied). `Snapshot` sums each accordingly. A consequence worth stating: Grok
figures are immune to pricing-table drift, and a Grok model missing from LiteLLM is
not an `Unknown` — there is nothing to look up.

### The grouping control

One cycle key with four modes, plus drill-in to a single series:

| mode | monthly table shows |
|---|---|
| `model` (default) | `claude-opus-4-7`, `grok-4.5-build`, … |
| `vendor` | `claude`, `grok` — this is the "all Claude usage" view |
| `source` | `work`, `personal` — one series per configured subscription |
| `total` | one series |

The same mode drives the monthly per-model table and the daily/monthly charts, in
both apps. `vendor` mode is not a special case built for Claude; it collapses every
vendor identically, and `source` collapses every subscription identically.

`source` mode is what makes multiple Claude subscriptions worth configuring
separately — merging them would leave a user unable to tell work spend from
personal. With only one source configured (the default), the mode still works and
simply shows a single series; it need not be hidden.

### Partial-coverage reporting

A monthly Grok total computed over July would be roughly one fifth of the truth and
would look exactly as authoritative as a correct one. That is the failure mode this
project has repeatedly guarded against, so it is designed for rather than left
implicit.

Per day, count `turn_completed` events **without** `usage` alongside those with it.
When a Grok figure's coverage falls below a threshold, mark it partial in the UI
rather than presenting it as complete. A user looking at July must be able to see
that the number is a floor, not a total.

### Drop the `n/a` placeholder rows

The limits gauges render a dimmed `n/a` row for a vendor that reports nothing in a
duration band. Codex stopped emitting its 5-hour window in August (29 session files
carried `window_minutes: 300` in July; 0 in August), and Grok never had one — so
the short band is now one real row and two placeholders.

Remove the `n/a` rows: a vendor with nothing in a band is simply not listed. **The
bands stay.** The reader keys on `window_minutes`, so a returning Codex 5h row
reappears on its own.

## Error handling

| Condition | Behaviour |
|---|---|
| `sources.toml` absent | Hardcoded roots used as an implicit source list. Current behaviour exactly. |
| `sources.toml` malformed | Logged once and treated as absent, so a typo cannot silently stop counting. Matches `limits.toml`'s missing-vs-malformed rule. |
| A configured `root` does not exist | Contributes nothing. Not an error. |
| Two sources share a `label` | Rejected at load — the label is a series identity and duplicates would silently merge two subscriptions. |
| A configured `root` nests inside another | Rejected at load. Overlapping roots would double-count every event in the overlap. |
| `~/.grok/sessions` absent | No Grok cells. Not an error. |
| A `turn_completed` without `usage` | Counted toward the coverage denominator; contributes no cost. |
| Malformed line | Skipped; scanning continues. |
| `costUsdTicks` absent or zero on a record that has tokens | Cell is recorded with zero cost and flagged, not silently dropped — a missing cost is a coverage problem, not a free turn. |
| A model in `modelUsage` that is unknown to us | Recorded as-is. There is no pricing lookup to fail. |

The governing rule is unchanged from the previous spec: **nothing here may break
cost counting.** Grok ingestion is additive and every failure degrades to "fewer
cells", never to a wrong Claude number.

## Testing

**Grok reader** — fixtures covering: a `turn_completed` with `usage`; one without;
a multi-model `modelUsage`; a duplicate `prompt_id`; a malformed line; and a
subagent file. Assert that top-level totals are never added on top of `modelUsage`.

**Authoritative cost** — a table test proving a costed cell ignores the pricing
table entirely, and that priced and costed cells sum correctly in one snapshot.

**Coverage** — a fixture whose usage-bearing fraction is known, asserting the
reported coverage matches and that the partial marking fires at the threshold.

**Sources** — loading with the file absent yields the implicit default list;
duplicate labels and nested roots are rejected; a configured-but-missing root is
silently empty. Plus a two-Claude-source fixture proving the same model under two
labels stays two series in `source` mode and merges in `vendor` mode.

**Grouping** — `model`/`vendor`/`source`/`total` over a fixture with two vendors,
two sources and three models, asserting each mode sums its members exactly and that
drill-in selects the right series.

**Cross-language parity** — extend the existing fixture harness to cover grouping,
since a divergence there would make the two apps disagree about what a vendor total
is. Note the existing fixture pins the budget engines only; this adds a second,
separate fixture rather than overloading it.

## Deferred to the Codex spec

- Summing `last_token_usage` deltas with dedupe by `eventId` (summing overshoots the session's own `total_token_usage` by 0.3–0.7% without it).
- Model resolution via `event_msg → thread_settings_applied → thread_settings.model`; `turn_context` carries no model field.
- Widening `pricing.Fetch`'s LiteLLM parse past Anthropic. LiteLLM's source already carries OpenAI models, so this is a filter change, not a new data source.
- `codex-auto-review` will have no pricing entry and lands in `agg`'s existing `Unknown` counter.

## Out of scope

- Codex ingestion (above).
- Backfilling Grok history that predates the `usage` field. It is not recoverable.
- Any use of the claude.ai session-cookie endpoint. Unchanged from the previous spec.
- Grok plan-limit gauges, which already ship and are unaffected.
