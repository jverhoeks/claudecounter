# Codex usage — design (Phase C)

**Date:** 2026-08-16
**Status:** shipped — Codex ingestion, pricing-table costing, the
`codex-auto-review` → `gpt-5.6-luna` alias, and cross-language parity are all
in place in both apps.
**Scope:** Codex ingestion. Completes the multi-vendor work begun in
`docs/superpowers/specs/2026-08-10-multi-vendor-usage-design.md`, whose Phase A
(sources and grouping) and Phase B (Grok) have shipped.
**Supersedes:** that spec's *Deferred to the Codex spec* section, in two places
marked **Correction** below.

## Problem

Codex spend is invisible. The plan-utilisation gauges already read
`~/.codex/sessions` for a percentage, but no dollars or tokens reach the
per-model table or the charts. On the local corpus that is **$842 of unreported
spend** across 1.39 billion tokens.

## The central difference from Grok

**Codex is *priced*, not *costed*.** It reports tokens; the dollars come from the
LiteLLM pricing table, exactly as Claude's do. Phase B's costed-cell machinery
(`cellVal.CostedUSD`, `CellValue.costedUSD`) is **not used here** — a Codex cell
is an ordinary priced cell. The instinct after Phase B will be to reach for the
costed path; don't.

## Data reality

Established empirically against the local corpus on 2026-08-16: 74 session files
under `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, 69 of which carry usage.

### Correction 1 — the dedupe key does not exist, and is not needed

The previous spec proposed summing `last_token_usage` deltas with "dedupe by
`eventId`". **There is no `eventId`.** A live `token_count` line is exactly
`{timestamp, type, payload}`, with no identifier at any level. Summing
`last_token_usage` also overshoots the vendor's own cumulative figure by **0.86%**
corpus-wide (1,396,689,075 vs 1,384,715,579), which is what the previous spec
noticed and tried to correct with dedupe.

**Use deltas of `total_token_usage` instead.** `total_token_usage` is cumulative
per session and was verified **monotonically non-decreasing in 69 of 69 files,
with zero resets** — including across a `context_compacted` event. Therefore:

- The telescoping sum of deltas equals the session's final total **exactly**, by
  construction. No drift, no correction factor.
- A duplicated `token_count` line yields a delta of **zero**. The dedupe problem
  disappears rather than being solved, which is why the missing `eventId` stops
  mattering.

This is strictly better than the superseded approach and is the reason Phase C
was unblocked.

### Correction 2 — `codex-auto-review` is priceable

The previous spec stated `codex-auto-review` "will have no pricing entry and
lands in `agg`'s existing `Unknown` counter". It has no LiteLLM entry under that
name, but it is not an unknown model: **Codex auto-review runs on GPT-5.6 Luna**
(confirmed by the project owner, 2026-08-16). LiteLLM carries `gpt-5.6-luna` at
$0.20/Mtok input and $1.20/Mtok output, matching the owner's figures exactly.

`codex-auto-review` is therefore **aliased to `gpt-5.6-luna` for pricing only**.
The alias exists so rates keep coming from LiteLLM rather than being hardcoded;
the model name displayed to the user stays `codex-auto-review`.

Consequence: **100% of Codex tokens are priceable.** Codex needs no
coverage/partial-figure mechanism — that machinery stays Grok's.

### Model resolution

The model in effect at a `token_count` event is the most recent preceding
`event_msg → thread_settings_applied → thread_settings.model`. `turn_context`
carries no model field (re-verified; unchanged from the previous spec), and
neither does `session_meta`.

**25 of 74 sessions never emit `thread_settings_applied` at all** — an older CLI
version — carrying 267M tokens (19% of the corpus). For those, resolve the model
from `session_meta.payload.parent_thread_id`:

| `parent_thread_id` | model |
|---|---|
| absent | `gpt-5.6-sol` |
| present | `codex-auto-review` |

This is not a guess. Across all 49 sessions that *do* declare a model, the
correlation is exact with **zero exceptions**: 25 files with no parent declared
`gpt-5.6-sol`, 24 files with a parent declared `codex-auto-review`. The rule is
applied only as a fallback, never overriding a declared model.

The two models are a moving target — a future Codex release will use different
ones. The fallback must therefore be **data, not hardcoded logic**: a small
`{hasParent: modelName}` mapping that can be corrected in one place. If a future
corpus breaks the correlation, the fallback is what changes, not the reader.

### Subagent attribution

`parent_thread_id` is the subagent marker: present means this session was spawned
by another. Codex therefore gets the same main/subagent split Claude has, keyed
on that field rather than on a path convention.

### Tokens

`total_token_usage` fields are `input_tokens`, `cached_input_tokens`,
`output_tokens`, `reasoning_output_tokens`, `total_tokens`. Verified on live
records: `total_tokens == input_tokens + output_tokens`, so `cached_input_tokens`
is a **subset of** `input_tokens` and `reasoning_output_tokens` a **subset of**
`output_tokens` — the same containment Grok has.

Mapping onto `TokenCounts`, computed **per delta**, not on cumulative values:

| ours | theirs |
|---|---|
| `In` | `input_tokens − cached_input_tokens` (saturating at 0) |
| `CacheRead` | `cached_input_tokens` |
| `Out` | `output_tokens` |
| `CacheCreate` | 0 — Codex reports no cache-creation figure |

`reasoning_output_tokens` is never added on top.

### Day attribution

A delta spans the interval between two `token_count` events and is attributed to
the **local day of the closing event** — the one that reports the new total.
Stated explicitly because a session running across midnight would otherwise be
ambiguous, and silently filing yesterday's tokens under today is the class of
wrong number this project forbids.

### Project attribution

From `session_meta.payload.cwd`, encoded the way Claude encodes its project
directories: every `/` and `.` becomes `-`. This keeps one working directory as
one row in the per-project table regardless of which vendor produced the spend.

Note this differs from Claude and Grok, which both derive the project key from
the transcript's path relative to the source root. Codex's directory layout is
`YYYY/MM/DD/rollout-*.jsonl` — dated, not project-keyed — so the path carries no
project information and the in-file `cwd` is the only source.

## Pricing table widening

`pricing.Fetch`'s LiteLLM parse currently filters to
`litellm_provider == "anthropic"`. It admits `openai` as well.

Verified against the live LiteLLM table (3,040 entries): 26 Anthropic and 145
OpenAI entries survive the existing "has a non-zero input or output cost" filter,
with **no name collisions** between the two sets and **no `/`-containing OpenAI
names**, so the Anthropic prefix-strip needs no OpenAI equivalent. The four
fields the parser already reads all exist on the OpenAI entries we use.

One caveat to carry in a comment: 52 of the 145 OpenAI entries omit
`cache_read_input_token_cost`, which unmarshals to 0 and would price cached reads
free. Neither `gpt-5.6-sol` nor `gpt-5.6-luna` is among them, but a future Codex
model might be, and cached reads dominate Codex volume.

## Error handling

| Condition | Behaviour |
|---|---|
| `~/.codex/sessions` absent | No Codex cells. Not an error. |
| A session with no `token_count` events | Contributes nothing. |
| `total_token_usage` absent on an event | Event skipped; the running previous total is left untouched so the next delta stays correct. |
| A decrease in `total_token_usage` | Treated as a session restart: the new value becomes the running total and contributes nothing. Never emit a negative delta. Not observed in 69 files, but a negative cell would be a wrong number rather than a missing one. |
| No `thread_settings_applied` in the session | Model resolved from `parent_thread_id` per the table above. |
| A model in neither LiteLLM nor the alias map | Recorded with its tokens and no cost, counted in the existing `Unknown` tally — today's behaviour for an unpriced model. |
| Malformed line | Skipped; scanning continues; parse-error counter increments. |

The governing rule is unchanged: **nothing here may break Claude or Grok
counting.** Codex ingestion is additive and every failure degrades to "fewer
cells", never to a wrong number.

## Testing

**Delta arithmetic** — a fixture with several `token_count` events asserting the
telescoping sum equals the final total; a duplicated event asserting it
contributes zero; a decrease asserting no negative delta.

**Model resolution** — a session declaring a model mid-stream; a session
declaring none, with and without `parent_thread_id`; assert a declared model is
never overridden by the fallback.

**The alias** — `codex-auto-review` prices at `gpt-5.6-luna`'s rates while
displaying as `codex-auto-review`; assert the displayed series key is unchanged.

**Pricing widening** — assert both Anthropic and OpenAI models survive the parse,
that the existing Anthropic set is unchanged, and that `gpt-5.6-sol` and
`gpt-5.6-luna` are present with their four rates.

**Cross-language parity** — extend the fixture harness with a Codex case, since a
divergence would make the two apps disagree about what a Codex month costs.

## Out of scope

- Backfilling anything not in the transcripts.
- Codex plan-limit gauges, which already ship and are unaffected.
- Any change to Grok's costed path or its coverage marker.
