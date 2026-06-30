# claudeinsights Text + Digest + Cache (Plan 2 of 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** Capture real user-prompt text (noise-filtered), emit a per-session JSON **digest** that doubles as the LLM input and a cache entry, add a two-level on-disk cache so re-runs skip parsing, and add two cheap structural coaching findings (session sprawl, model routing).

**Architecture:** Extend `session.Session` with a filtered `UserPrompts` slice (no behavior change to existing parsing). New `insights.Digest` builder produces a compact redacted artifact. New `insights/cache.go` persists digests + reports under `$XDG_CACHE_HOME/claudeinsights/`, keyed by `sessionID + mtime + size`. Structural coaching findings extend `AnalyzeSession`.

**Tech Stack:** Go stdlib (`encoding/json`, `crypto/sha256`, `os`, `path/filepath`). Reuses `session`, `pricing`, `insights`.

## Global Constraints

- Module `github.com/jverhoeks/claudecounter/tui`; build/test from `tui/`.
- Modifying `session` is allowed but additive only — existing tests must stay green.
- Real-prose filter (verified against live data): `type==user` AND `permissionMode!=""` AND not `isMeta`/`isSidechain`/`isCompactSummary` AND content is text AND text does not start with an injected tag (`<task-notification>`, `<command-name>`, `<command-message>`, `<command-args>`, `<local-command-stdout>`, `<system-reminder>`, `<user-prompt-submit-hook>`); embedded `<system-reminder>…</system-reminder>` spans stripped.
- Cache is best-effort: any cache read/write error degrades to a fresh compute, never a crash.
- Pure functions take `io.Writer`/values; I/O isolated to `cache.go`.

---

### Task 1: Capture filtered user-prompt text in `session`

**Files:**
- Modify: `tui/internal/session/session.go`
- Test: `tui/internal/session/session_test.go` (add cases)

**Produces:**
- `type Prompt struct { Time time.Time; Mode string; Text string }`
- `Session.UserPrompts []Prompt`
- unexported `promptText(content json.RawMessage) (string, bool)` and `isInjectedTag(s string) bool`, `stripSystemReminders(s string) string`

**Steps:**
- [ ] Add `IsMeta`, `IsSidechain`, `IsCompactSummary bool` json tags to `rawLine` (`isMeta`/`isSidechain`/`isCompactSummary`).
- [ ] Add `Prompt`/`UserPrompts` to the `Session` struct.
- [ ] In `apply`, in the existing `r.Type=="user" && r.PermissionMode!="" && !sub` block, additionally: skip if any of the three flags set; extract text via `promptText`; if it passes `!isInjectedTag` after `stripSystemReminders` + trim, append `Prompt{r.Timestamp, r.PermissionMode, text}`.
- [ ] `promptText`: if content first non-space byte is `"` → unmarshal as string; if `[` → unmarshal `[]rawBlock`, join `text` blocks; return ok=false otherwise.
- [ ] Test: the existing fixture's "please do X" / "now dangerously" become `UserPrompts` (2); a `<task-notification>`-prefixed PM line and an `isMeta` PM line are excluded; an embedded `<system-reminder>` is stripped from an otherwise-real prompt.
- [ ] Run `go test ./internal/session/` — green. Commit.

---

### Task 2: Digest builder

**Files:**
- Create: `tui/internal/insights/digest.go`, `digest_test.go`

**Produces:**
- `type DigestTool struct { Name, Target string; Err bool; Sub bool }`
- `type Digest struct { ID, Project, Cwd, Model string; Start, End time.Time; Prompts []string; Tools []DigestTool; Metrics SessionReport }` (Metrics = the Tier-1 report sans the heavy slices; embed the existing `SessionReport`).
- `func BuildDigest(s *session.Session, r SessionReport, maxPrompts, maxTools, maxRunes int) Digest` — truncates prompt count/length and tool count to bound LLM input size; records counts dropped.

**Steps:**
- [ ] Test: a session with 3 prompts + 5 tools, `maxPrompts=2, maxTools=3` → digest has 2 prompts, 3 tools, each prompt ≤ maxRunes; truncation noted (e.g. a trailing "…(+1 more)" sentinel prompt or a `DroppedPrompts int` field — use fields, assert counts).
- [ ] Implement with `trunc` reuse. Commit.

---

### Task 3: Two-level cache (digest + report)

**Files:**
- Create: `tui/internal/insights/cache.go`, `cache_test.go`

**Produces:**
- `type Cache struct { dir string; enabled bool }`
- `func OpenCache(enabled bool) *Cache` (resolves `$XDG_CACHE_HOME/claudeinsights` or `~/.cache/claudeinsights`; `enabled=false` → no-op cache)
- `func (c *Cache) Key(path string, mtime time.Time, size int64) string` (sha256 of `id|mtime|size`)
- `func (c *Cache) GetReport(key string) (SessionReport, bool)` / `func (c *Cache) PutReport(key string, r SessionReport)`
- Errors swallowed; `--refresh` handled by caller passing `enabled` + skipping `Get`.

**Steps:**
- [ ] Test (use `t.TempDir()` as dir via an unexported constructor `newCacheAt(dir, true)`): Put then Get round-trips a `SessionReport`; Get on miss → false; disabled cache → always miss, never writes.
- [ ] Wire `Scan` to consult the cache: compute key from the file's `os.Stat`, `GetReport` → use it; else `Parse`+`Analyze`+`PutReport`. Add `refresh bool` + `*Cache` params to `Scan` (update Plan 1 callers/tests).
- [ ] Test `Scan` twice on the same fixture: second run returns identical reports; touching the file (rewrite, new mtime) invalidates.
- [ ] Commit.

---

### Task 4: Structural coaching findings (sprawl, model routing)

**Files:**
- Modify: `tui/internal/insights/insights.go`
- Test: `tui/internal/insights/coaching_test.go`

**Produces:** new `Category` consts `CatSprawl="sprawl"`, `CatRouting="routing"`; helpers `sprawlFindings`, `routingFindings`; wired into `AnalyzeSession`. New thresholds: `SprawlPrompts int` (default 60), `SprawlHours float64` (default 4), `RoutingMaxTokens uint64` (default 20_000), `RoutingMaxTools int` (default 5).

**Heuristics:**
- **Sprawl**: `Prompts >= SprawlPrompts` OR `End-Start >= SprawlHours` → "long session — consider splitting / delegating to subagents".
- **Routing**: dominant model contains `opus` AND total tokens (in+out, exclude cache) `< RoutingMaxTokens` AND `ToolCalls <= RoutingMaxTools` → "light session ran on Opus — Sonnet/Haiku/Fast mode may suffice".

**Steps:**
- [ ] Tests: a 70-prompt session → sprawl; a 5h session → sprawl; a tiny opus session → routing; a big opus session → no routing.
- [ ] Implement + wire into `AnalyzeSession`; add thresholds to `DefaultThresholds`. Commit.

---

### Task 5: CLI wiring (`--no-cache`, `--refresh`, `--digest`)

**Files:**
- Modify: `tui/cmd/claudeinsights/main.go`
- Modify: `tui/cmd/claudeinsights/export.go` (+ test)

**Produces:** flags `--no-cache`, `--refresh`; `--digest` (with `--session`) prints the session's `Digest` as JSON via new `writeDigest(w, Digest) error`.

**Steps:**
- [ ] Add flags; `OpenCache(!*noCache)`; pass cache+refresh into `Scan`.
- [ ] `--session --digest` builds and prints the digest JSON.
- [ ] Test `writeDigest` round-trips JSON. `go build`, `go vet ./...`, `go test ./...`. Smoke: run twice, confirm second run faster (cache hit). Commit.

## Self-Review
- Text capture (spec noise filter) → Task 1. Digest (cache/LLM/export) → Task 2. Two-level cache → Task 3. Structural coaching (sprawl, routing) → Task 4. CLI → Task 5.
- Deferred to Plan 3: LLM judge, corrections, CLAUDE.md miner, prompt coach, cost-without-delivery, LLM-result cache.
