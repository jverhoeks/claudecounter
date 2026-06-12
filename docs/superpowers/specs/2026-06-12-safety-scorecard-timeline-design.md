# Safety report, session scorecard & timeline — design

**Date:** 2026-06-12
**Status:** approved (brainstormed interactively)

## Goal

Bring the deterministic subset of arx-ce's reports to claudecounter:

1. **Safety/mode report** (aggregate) — which permission modes sessions ran
   under, % of turns in `bypassPermissions` ("dangerous mode"), a
   container-likely heuristic, and entrypoint (cli/sdk).
2. **Session scorecard** (per session, stats only) — tool calls made/failed,
   per-tool counts, duplicate file reads, tokens by category + USD, peak
   context size, duration.
3. **Timeline** (per session) — chronological one-line-per-event audit log:
   tool calls with ok/err, cost per assistant turn, permission-mode changes.

Explicitly **out of scope**: LLM-judged metrics (prompt clarity,
suggestions), arx's ping/compliance mechanism, macapp port, per-session
browser in the TUI.

## Data source facts (verified against real transcripts)

- Every `user` event carries `permissionMode` (`default`, `acceptEdits`,
  `plan`, `auto`, `dontAsk`, `bypassPermissions`).
- `assistant` events carry `message.content[]` with `tool_use` blocks
  (id, name, input); the matching `tool_result` arrives in a later `user`
  event's `message.content[]` with `tool_use_id` + `is_error`.
- `entrypoint` (`cli`, `sdk-py`, …), `cwd`, `gitBranch`, `isSidechain`,
  timestamps and `message.usage` are present as the counter already knows.
- There is **no** explicit docker/container field → heuristic only.

## Architecture

Follows the precedent set by the ROI report (view 4): the live,
ccusage-calibrated counting path (`reader`/`agg`) is **untouched**. All new
parsing lives in new packages; reports are computed lazily on demand.

```
internal/session   Parse ONE session jsonl → rich Session model
                   (turns, tool calls w/ matched results, mode timeline,
                   deduped tokens, entrypoint, cwd). Shared foundation.
internal/safety    Lightweight wide scan (3 fields/line) over the corpus →
                   per-project mode aggregation + container heuristic.
                   Pure Build() + I/O Gather(), mirroring internal/report.
cmd/claudecounter  --safety [--csv] [--days N]   aggregate safety report
                   --scorecard [--session ID]    per-session scorecard
                   --timeline  [--session ID]    per-session audit log
internal/ui        view 5 (ModeSafety): lazy gather + spinner + viewport,
                   key 5, [/] window cycling — same UX as view 4.
```

`--session` accepts a session-id prefix; defaults to the most recently
modified session jsonl. Scorecard/timeline also fold in the session's
`subagents/agent-*.jsonl` files (marked `(sub)`), consistent with the
counter's recursive scan.

## Dedupe rules

Token sums reuse the counter's `messageId:requestId` first-seen rule.
Tool calls dedupe by `tool_use` block id (streaming re-serialisation
duplicates content blocks the same way it duplicates usage).

## Container ("docker?") heuristic

No hard signal exists, so the report says `likely` / `no`, never asserts —
same "guide, not measurement" framing as the ROI docs. A session is
container-**likely** when its `cwd` is not under the host's home dir
parent (e.g. `/Users` on macOS), with classic container roots
(`/workspace`, `/app`, `/root`, `/srv`, `/home` on a darwin host)
strengthening the signal. Pure function with injected home path for tests.
Note: container sessions only appear at all when `~/.claude` is
volume-mounted to the host.

## Safety report shape

Per project (encoded project key, basename-shortened for display), over the
window (`--days 30|90|180`, default 90; TUI `[`/`]`):

```
⚠ 94 turns (3.1%) ran with permissions bypassed, in 4 projects · 1 likely container
project                turns  sess  default accept  plan  auto dontAsk BYPASS  container? entry
data-platform-demo       812    14      60%     2%    1%   28%      0%     9%  no         cli
sandbox-experiment       140     2       0%     0%    0%    0%      0%   100%  likely     cli
```

CSV columns: `project,turns,sessions,default,accept_edits,plan,auto,
dont_ask,bypass,bypass_pct,container_likely,entrypoints`.

## Scorecard shape

```
Session 14a8997f…  data-platform · 2h41m · cli · modes: auto → bypassPermissions(!)
Execution  142 tool calls · 9 failed (6.3%) · Bash 71 · Edit 31 · Read 28 …
Waste      11 Read targets read 2+× (top: foo.go ×4, bar.go ×3)
Tokens     in 41k · out 96k · cache-w 2.1M · cache-r 18.4M · $23.41
Context    peak ≈ 164k tok (input+cache, single request)
```

No % of context limit (limit varies by model); peak shown raw.

## Timeline shape (`--timeline`)

```
10:21:09  Bash      go test ./...                          ok    
10:21:14  Edit      tui/internal/ui/view_report.go         ok    (sub)
10:22:02  mode      auto → bypassPermissions               ⚠
10:22:40  assistant claude-opus-4-7                        +$0.41
```

One line per: tool call (name + truncated target + ok/err), permission-mode
change, assistant turn cost. Chronological, merged across main + subagent
files.

## Testing

- `internal/session`: fixture jsonl (handcrafted, covering tool_use/result
  matching, is_error, string-vs-array content, dup blocks, mode changes,
  subagent merge) → unit tests on Parse.
- `internal/safety`: pure Build tests + container-heuristic table tests.
- CLI: golden-ish output tests in cmd/claudecounter mirroring
  report_cli_test.go.
- TUI: model test for key 5 / lazy load, mirroring existing view tests.
