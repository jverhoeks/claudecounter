# claudeinsights — design

**Date:** 2026-06-19
**Status:** Design approved, pending implementation plan

## Goal

A separate analysis tool that mines the Claude Code JSONL transcript corpus to surface
**usage, token waste, tool abuse, skill overload, context overload, repetitions/corrections,
and loop patterns** — and turns those into **actionable coaching on how to work better with
Claude** (CLAUDE.md gaps, prompt quality, cost-without-delivery, session hygiene, model
routing).

It reuses the existing transcript parsing rather than re-implementing it, and runs entirely
locally. The only "LLM" used is the user's own `claude -p` CLI (no API token required).

## Non-goals

- Not part of the live counting path (`reader`/`agg`/TUI). It scans on demand, like
  `--report`/`--safety`/`--scorecard`.
- Not a real-time monitor. One-shot scan → report → exit.
- No network calls except indirectly through `claude -p`.

## Architecture

```
tui/cmd/claudeinsights/         NEW binary (main, flag parsing, output rendering)
tui/internal/insights/          NEW package: pure analysis over parsed sessions
tui/internal/insights/judge.go  NEW: Judge interface + claude -p implementation
tui/internal/session/           EXTENDED: capture filtered user/assistant text
tui/internal/pricing/           reused (cost); insights adds its own context-window map
tui/internal/gitstat/           reused (cost-without-delivery)
```

Three layers, each independently testable:

1. **Parse layer** — `session.Parse` (extended). Reads transcripts into a rich model.
2. **Analysis layer** — `internal/insights`. Pure functions: `(parsed sessions) → findings`.
   No I/O, no clock, no network. Table-driven testable.
3. **Judge layer** — `internal/insights/judge.go`. A `Judge` interface; the real impl shells
   to `claude -p`. Analysis layer depends on the interface, tests inject a fake.

### Why extend `session`, not fork a parser

`session.Session` already provides exactly the structural raw material: deduped priced turns
(`Turns`), matched tool calls with errors (`ToolCalls`), permission-mode timeline, prompt
counts, `PeakContext`, and the `Sub` (main-vs-subagent) flag. It already handles streaming
re-serialization dedup (`seenMsg`/`seenTool`). Forking a second parser would duplicate that
and drift. The **only** change to existing code is capturing message **text** under the same
dedup and filtering discipline.

## Session model extension

Add to `session.Session` / its sub-types:

- `Prompt` records for **real user prose only** (see filtering below): `{Time, Text, Mode}`.
- Assistant text per `Turn` (or a parallel `AssistantText []string`), deduped via the
  existing `seenMsg` key so re-serialized blocks aren't double-counted.
- Per-assistant-message **tool-block count** (to detect serial vs batched tool use).

### Real-prose filter (make-or-break — verified against live data)

`type:"user"` is dominated by noise. In a real 45 MB transcript: 5,700 `tool_result` user
lines vs ~440 real prompts, and even `permissionMode`-bearing lines included injected
`<task-notification>` blocks. A line counts as **real user prose** only if **all** hold:

1. `type == "user"`
2. has non-empty `permissionMode` (excludes `tool_result` user lines)
3. not `isMeta`, not `isSidechain`, not `isCompactSummary`
4. content is text (string, or `text` blocks) — not `tool_result`/`image`-only
5. trimmed text does **not** begin with a known injected tag:
   `<task-notification>`, `<command-name>`, `<command-message>`, `<command-args>`,
   `<local-command-stdout>`, `<system-reminder>`, `<user-prompt-submit-hook>`
6. embedded `<system-reminder>…</system-reminder>` spans are stripped before analysis

The tag list lives as a named constant and has a dedicated test fixture covering each case.

### Context-window map

`pricing` has no window field. `insights` keeps a small `map[modelGlob]uint64` with a 200k
default and `opus-4-8[1m]` → 1,000,000 (confirmed via `claude -p` reporting
`contextWindow: 1000000`). Matching is substring/suffix based and falls back to the default.

## Findings — tiered by confidence

### Tier 1 — structural / token (always on, low false-positive)

| Category | Heuristic | Notes |
|---|---|---|
| **Usage** | tokens (in/out/cache-create/cache-read), cost $, #turns, #tool calls, #prompts, duration | per session + per project |
| **Token waste** | failed tool calls (`IsErr`) × est. round-trip; redundant `Read` of same target with no intervening `Edit`; cache churn (cache-create ≫ cache-read); high-context/tiny-output turns | each contributes a $ estimate |
| **Tool abuse** | same `(Name+Target)` ≥ `repeatThreshold`; tool-calls-per-prompt ratio; tool error rate | |
| **Skill overload** | distinct `Skill` invocations/session; skills re-invoked; distinct-tool-surface size | Skill = tool calls named `Skill` |
| **Context overload** | `PeakContext` as % of model window; #turns above `ctxHighPct` (80%) | uses window map |
| **Repetitions / loops (structural)** | repeated tool subsequences (e.g. `[Edit X, Bash test]` ≥ `loopMin`); Read↔Edit ping-pong on same file; same errored command retried | **per stream**: main and each subagent analyzed separately to avoid phantom loops |

### Tier 2 — fuzzy / coaching (opt-in `--llm`, via local `claude -p`)

Runs **only on Tier-1-flagged sessions**, capped at `--llm-max` worst (default 10). Each call
sends a compact, truncated digest (filtered prompts + tool-call sequence) to
`claude -p "<judge prompt>" --output-format=json`, parsing the `result` field as JSON.

- **Corrections** — user-pushback turns ("no", "still broken", "I said…", re-asking).
- **Semantic loops** — repeated intent the structural detector misses.
- **Root-cause + friction score 0–10** per flagged session.
- **Prompt-specificity coach** — rate the first prompt; correlate corpus-wide with
  correction/loop counts; advise.
- **CLAUDE.md / memory candidates** — runs **once per project** (not per session): recurring
  instructions across that project's sessions → suggested config/memory additions.

**Corrections vs loops overlap:** a correction *loop* is counted **once** as a loop, with its
corrections listed as evidence. No double-counting.

All Tier-2 thresholds are named constants; the spec states plainly they are starting points
to tune.

### v1 coaching signals (selected — beyond the table above)

1. **CLAUDE.md/memory candidates** (Tier-2, per project) — highest leverage.
2. **Prompt specificity coach** (Tier-2) — first-prompt quality → outcome.
3. **Cost without delivery** (mostly structural) — high-$ sessions with no git commit and no
   `pr-link` event. Reuses `gitstat`.
4. **Session sprawl + model routing** (structural) — long sessions / `isCompactSummary`
   count → "split sessions / delegate"; opus-on-trivial turns + correction-rate-by-model →
   routing advice.

### Roadmap (explicitly deferred — not v1)

Tool parallelism (serial vs batched), subagent delegation balance, tool latency, queued-message
rate (`queue-operation`), skill/plugin ROI, time-of-day quality, cross-session trend.

## Caching & the digest artifact

Re-parsing 45 MB transcripts and re-paying ~$0.10 per LLM call on every run is wasteful, so
the tool persists two cache levels under `$XDG_CACHE_HOME/claudeinsights/` (fallback
`~/.cache/claudeinsights/`).

### The digest (one artifact, three jobs)

Per session the tool produces a compact JSON **digest**: filtered user prompts + the
tool-call sequence + Tier-1 metrics. This single artifact is:

1. the **cache entry** (so re-runs skip parsing),
2. the **LLM input** (exactly what `claude -p` receives — small, redacted, truncated),
3. a **human/script-readable export** ("easier/faster parsable" intermediate).

### Two cache levels

| Cache | Key | Invalidates when |
|---|---|---|
| Digest + Tier-1 findings | `sessionID + file mtime + size` | the transcript file changes/grows |
| LLM judge result | `digest content hash + judgePromptVersion + model` | digest changes, prompt version bumps, or model changes |

Keying Tier-1 on `mtime+size` is safe because transcripts are effectively append-only; any
change moves the key. The `judgePromptVersion` is a constant bumped whenever the judge prompt
changes, so prompt edits transparently invalidate stale LLM answers without a manual purge.

Flags: `--no-cache` (ignore + don't write), `--refresh` (rebuild all, overwrite). Cache files
are plain JSON so they can be inspected or fed to other tools.

## Output

- **Default (corpus)**: ranked leaderboard tables — worst sessions/projects by waste $,
  corrections, loops, context pressure — plus aggregate totals. Honors `--days` (default 90,
  same window semantics as `--report`/`--safety`).
- **`--session <prefix>`**: per-session drill-down; each category's findings + a timeline of
  detected loops/corrections.
- **`--json`**: full structured findings to stdout.
- **`--csv`**: flat one-row-per-finding (mirrors existing `--csv` pattern).
- **`--llm`** / **`--llm-max N`**: enable Tier 2; cap LLM-judged sessions.

### CLI flags

```
claudeinsights [--root DIR] [--pricing FILE] [--days N]
               [--session PREFIX] [--json] [--csv]
               [--llm] [--llm-max N]
               [--no-cache] [--refresh]
```

`--root`/`--pricing`/`--days` mirror the existing binary's flags and defaults.

## Error handling

- Unparseable lines skipped silently (matches counter tolerance).
- Missing/unreadable transcript or subagent file: skip that file, continue.
- `claude -p` failure (non-zero exit, timeout, non-JSON `result`): that session's Tier-2
  findings are marked unavailable with the error; Tier-1 output is unaffected. Per-call
  timeout (e.g. 60s) so one hung call can't stall the run.
- No git / non-git project: cost-without-delivery degrades to "delivery unknown", not an error.
- Empty corpus / no sessions in window: clear message, exit 0.

## Cost discipline

LLM calls are **not** cheap (~$0.10 each due to system-prompt context). Defaults are
conservative: `--llm` off by default; when on, only flagged sessions, `--llm-max 10`, and the
CLAUDE.md miner runs once per project. The tool prints an estimated/actual LLM cost summary.

## Testing strategy

- **Insights heuristics**: table-driven over synthetic `session.Session` values — no fixtures.
- **Real-prose filter**: fixtures covering tool_result, task-notification, command expansion,
  system-reminder, isMeta/isSidechain, and genuine prose.
- **Per-stream loop detection**: fixture with interleaved main + subagent calls proving no
  phantom loops.
- **Context-window map**: opus-4-8[1m] → 1M, unknown → 200k default.
- **Judge layer**: `Judge` interface mocked; real impl tested behind a build/skip guard.
- **CSV/JSON**: pure writer functions taking `io.Writer`, asserted on output (mirrors
  `writeReportCSV`).
- **Caching**: digest key stable across runs for unchanged files; mtime/size bump invalidates
  Tier-1; `judgePromptVersion` bump invalidates LLM entries; `--no-cache`/`--refresh` honored.
```
