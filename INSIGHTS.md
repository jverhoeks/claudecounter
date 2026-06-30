# 🔎 claudeinsights

A local analyzer for your Claude Code transcript corpus. It scans the same
`~/.claude/projects/**/*.jsonl` files the counter reads and turns them into
**actionable insight**: where tokens and money leak, where sessions thrash, and
— with the opt-in LLM tier — concrete coaching on how to work better, plus
ready-to-apply `CLAUDE.md` updates.

Everything runs on your machine. The optional LLM pass uses your local
`claude -p` CLI, so **no API token is required**.

---

## Build & run

```bash
make build-insights        # → ./claudeinsights   (or `make build` for both binaries)

./claudeinsights                       # ranked corpus leaderboard, last 90 days
./claudeinsights --days 30             # narrower window
./claudeinsights --session 1a2b        # drill into one session (id prefix)
```

By default it reads `~/.claude/projects` and prices with
`~/.config/claudecounter/pricing.toml` (falling back to built-in defaults).

---

## How it works

`claudeinsights` reuses `claudecounter`'s transcript parser (`internal/session`),
which folds each main session and its Task-tool subagents into one model: deduped
priced turns, matched tool calls (with errors), the permission-mode timeline,
peak context, and — for this tool — the *real* user prompts (machine/injected
turns filtered out). Analysis lives in a pure `internal/insights` package; the
CLI only renders and does I/O.

Findings are **tiered by confidence**:

- **Structural tier** — cheap, deterministic, always on. Low false-positive.
- **Coaching tier** (`--llm`) — uses `claude -p` to read prompts and judge
  friction, corrections, recurring instructions, and produce advice.

---

## Structural tier (always on)

| Category | What it flags |
|----------|---------------|
| **waste** | failed tool calls (each burns a round-trip); the same file `Read` repeatedly with no edit between; turns that injected lots of *new* context but produced tiny output |
| **abuse** | the same `(tool, target)` called many times; the worst offenders are listed, the rest rolled up |
| **skill** | too many distinct `Skill` invocations in one session |
| **context** | peak context as a % of the model's window (200k, or 1M for `[1m]`/observed-large models) |
| **loop** | a tool subsequence repeated back-to-back, **per stream** (main vs subagent kept separate) |
| **sprawl** | very long sessions (many prompts / many hours) → split or delegate |
| **routing** | a light session that ran on Opus → a cheaper model or Fast mode may suffice |
| **delivery** | a high-$ session with **no commit and no PR** (checked via git for expensive sessions) |

**Waste $ counts only new tokens** (input + cache-creation) — cache *reads* are
the cheap, intended way to continue a long session and are never counted as waste.

### Output modes

```bash
./claudeinsights                       # corpus leaderboard (worst sessions + per-project rollup)
./claudeinsights --top 25              # show more worst-sessions rows
./claudeinsights --session 1a2b        # one session's findings
./claudeinsights --json                # full structured findings
./claudeinsights --csv                 # one row per finding
./claudeinsights --session 1a2b --digest   # the compact JSON digest (LLM input / export)
```

Example:

```
Corpus  $12,352 spent · $272 estimated waste · 847 sessions
Worst sessions (top 15):
  session  project              $       waste$   findings  top finding
  43b9d8b8 data-platform   $880.38    $57.53        13     waste: 8 failed tool call(s) …
```

---

## Coaching tier (`--llm`, uses local `claude -p`)

Opt-in. Runs only on the worst flagged sessions (capped by `--llm-max`, default
10) and **caches every reply**, so you don't re-pay on the next run. Budget
~$0.10 per session.

```bash
./claudeinsights --llm                 # coach the worst flagged sessions
./claudeinsights --llm --llm-max 5     # cap how many sessions get judged
./claudeinsights --session 1a2b --llm  # coach one specific session
```

It produces three things:

1. **Per-session judgment** — a friction score (0–10), first-prompt clarity,
   the actual user **corrections** (quoted), unproductive **loops**, the root
   cause, and concrete advice.
2. **`══ Top actions ══`** — all the advice rolled up into a deduped, ranked
   "what to change in how you work" list, tagged with how many sessions each
   pattern appeared in.
3. **CLAUDE.md / memory candidates** — recurring instructions you keep repeating
   across a project's sessions (mined from *all* the project's prompts, not just
   the flagged ones), so they can move into config.

---

## Apply to CLAUDE.md (`--apply`)

Turn the mined candidates into real changes. `--apply` uses `claude -p` to
**merge** them into each flagged project's `<cwd>/CLAUDE.md`, preserving your
existing content and only appending a deduped `## Insights (auto-suggested)`
section.

**Dry-run by default** — it prints a unified diff and writes nothing. Add
`--write` to apply, atomically (temp file + rename), only to directories that
still exist.

```bash
./claudeinsights --llm --apply          # show the merge diffs (writes nothing)
./claudeinsights --llm --apply --write  # actually write the merged CLAUDE.md files
```

`--apply` implies `--llm` (it needs the candidates). Always review the dry-run
diff before `--write` — the merge trusts the model to not drop existing content,
and the diff is your safeguard.

---

## Caching

Results are cached under `$XDG_CACHE_HOME/claudeinsights/` (fallback
`~/.cache/claudeinsights/`), so warm re-runs are ~25× faster:

- **Structural** reports are keyed by `sessionID + file mtime + size` — a changed
  transcript invalidates automatically.
- **LLM** replies (judgments, mining, actions) are keyed by a digest hash plus a
  prompt-version, so editing a prompt invalidates stale answers.

```bash
./claudeinsights --no-cache            # ignore + don't write the cache
./claudeinsights --refresh             # recompute and overwrite cache entries
```

---

## All flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--root` | `~/.claude/projects` | transcript corpus root |
| `--pricing` | `~/.config/claudecounter/pricing.toml` | price table |
| `--days` | `90` | analysis window (last N days) |
| `--session` | — | drill into one session (id prefix; empty = corpus mode) |
| `--top` | `15` | worst-session rows in corpus mode |
| `--json` / `--csv` | off | machine-readable output |
| `--digest` | off | with `--session`: print the compact JSON digest |
| `--llm` | off | run the `claude -p` coaching pass |
| `--llm-max` | `10` | cap sessions sent to the judge |
| `--apply` | off | merge candidates into project `CLAUDE.md` (implies `--llm`) |
| `--write` | off | with `--apply`: actually write (default is dry-run) |
| `--no-cache` / `--refresh` | off | cache controls |

---

## Known limitations

- **Loop detection is back-to-back only.** Interleaved loops (with drift between
  repeats) surface as repeated-call *abuse* rather than *loop*.
- **Context % is clamped at 100%.** A few usage lines aggregate internal model
  iterations, so the per-line token sum can exceed any real window; the raw peak
  token count is still in the JSON output.
- **The CLAUDE.md merge trusts the model.** It's prompted to only add/dedupe and
  preserve existing content; the dry-run diff is the safeguard — review before
  `--write`.
- **LLM calls aren't free** (~$0.10 each) and `claude -p` can take 1–3 minutes
  per call for large prompts. Results are cached to avoid re-paying.
