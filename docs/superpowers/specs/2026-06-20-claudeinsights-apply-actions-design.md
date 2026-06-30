# claudeinsights apply + action list — design

**Date:** 2026-06-20
**Status:** Approved, pending plan

## Goal

Turn the Tier-2 coaching *insight* into *change*:

1. **Consolidated action list** — synthesize all per-session advice into one deduped,
   ranked "what to change in how you work" list.
2. **Apply to CLAUDE.md** — merge the mined CLAUDE.md/memory candidates into each flagged
   project's `<cwd>/CLAUDE.md`, dry-run (diff) by default, `--write` to apply.

Extends the existing `claudeinsights` binary and `internal/insights` package. Uses the local
`claude -p` judge already built in Plan 3.

## Non-goals

- No edits to anything but `<cwd>/CLAUDE.md` (not settings.json, not hooks, not global memory).
- No network beyond `claude -p`.
- Not a general CLAUDE.md editor — only adds/dedupes the mined candidates.

## Enabler

`SessionReport.Cwd` already holds the real working directory for each session, so a project's
file is `<cwd>/CLAUDE.md`. No project-key decoding; writes only target directories that exist.

## Feature 1 — consolidated action list

After `--llm` judgments run, one extra `claude -p` call rolls up every session's `advice`,
`corrections`, and `loops` into a ranked list. Each item: a concrete action + how many
sessions it was seen in + impact. Rendered as `══ Top actions ══`; cached.

- `insights.ActionItem{ Action, Why string; Sessions int }`
- `insights.ActionList{ Items []ActionItem; Available bool; Err string; CostUSD float64 }`
- `func SynthesizeActions(ctx, j Judge, []Judgment) ActionList` — builds a prompt from the
  available judgments, asks for JSON `{actions:[{action, why, sessions}]}`, parses tolerantly
  (reuses `extractJSON`). Empty/unavailable on no judgments or LLM failure.

Runs automatically as part of `--llm`. Cache key: hash of the judgments' session IDs +
`judgePromptVersion`.

## Feature 2 — apply to CLAUDE.md

`--apply` (implies the LLM mining pass). For each flagged project (one entry per distinct
project among judged sessions):

1. Resolve `cwd` from the project's session reports (first non-empty `Cwd`).
2. If `cwd` doesn't exist as a dir → skip with a printed note.
3. Read existing `<cwd>/CLAUDE.md` (empty string if absent).
4. `MergeClaudeMd(ctx, j, existing, candidates)` → full merged file text. The prompt instructs:
   preserve all existing content verbatim, only append/dedupe the new candidates, return the
   complete file, no commentary.
5. **Dry-run (default):** print a unified diff (`existing` vs `merged`) with the target path.
6. **`--write`:** write `merged` atomically (temp file in the same dir + `os.Rename`); print
   "wrote <path>". Never write if `merged` is empty or equals existing.

- `func MergeClaudeMd(ctx, j Judge, existing string, cands []MemoryCandidate) (string, error)`
- `func unifiedDiff(old, new, path string) string` — minimal line diff for preview (pure).

## CLI

```
claudeinsights --llm                 # now also prints ══ Top actions ══
claudeinsights --llm --apply         # + per-project CLAUDE.md merge DIFFS (writes nothing)
claudeinsights --llm --apply --write # actually write the merged CLAUDE.md files
```

`--apply` without `--llm` implies `--llm` (it needs candidates). `--write` without `--apply`
is a no-op with a warning.

## Error handling

- Missing/!dir `cwd` → skip project, note it.
- `claude -p` failure on merge → skip that project, keep going; Tier-1 + other projects intact.
- Atomic write failure → report, don't leave a partial file (temp + rename).
- Merge result empty or unchanged → skip write, say so.
- Action synthesis failure → omit the section with a one-line note; never blocks the run.

## Safety

- `--write` is the only thing that mutates files; dry-run diff is the default so the user always
  previews first. Authorization is the explicit flag.
- Merge prompt forbids deleting existing content; the diff makes any violation visible before
  `--write`.
- Writes confined to existing `<cwd>` dirs; atomic.

## Testing

- `SynthesizeActions` / `MergeClaudeMd`: fake `Judge` (canned + prose-wrapped + error replies).
- `unifiedDiff`: pure, asserts added/removed lines.
- Apply orchestration: fake judge + `t.TempDir()` — dry-run writes nothing; `--write` writes
  expected content; missing dir is skipped; unchanged merge skips write.
