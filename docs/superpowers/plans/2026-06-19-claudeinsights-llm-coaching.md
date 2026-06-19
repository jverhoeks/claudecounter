# claudeinsights LLM Judge + Coaching (Plan 3 of 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** Add an opt-in Tier-2 coaching pass powered by the user's local `claude -p` CLI: per-session friction/corrections judgment, per-project CLAUDE.md/memory candidates, and a structural cost-without-delivery finding. Results are cached so re-runs don't re-pay.

**Architecture:** A `Judge` interface abstracts the LLM; `CLIJudge` shells to `claude -p --output-format=json` (prompt on stdin, reads `.result` + `.total_cost_usd`). The analysis layer builds prompts from the Plan-2 `Digest`, parses JSON replies, and caches them keyed by `digest hash + promptVersion + model`. The CLI runs the judge only on Tier-1-flagged top-N sessions (capped by `--llm-max`) and the miner once per project.

**Tech Stack:** Go stdlib (`os/exec`, `context`, `crypto/sha256`, `encoding/json`). Reuses `insights`, `session`, `gitstat`.

## Global Constraints

- Module `github.com/jverhoeks/claudecounter/tui`; build/test from `tui/`.
- LLM is opt-in (`--llm`); default run makes zero `claude -p` calls.
- Every LLM failure (non-zero exit, timeout, non-JSON) degrades that session's Tier-2 result to "unavailable" with the error; Tier-1 output is unaffected.
- Per-call timeout 60s; calls run sequentially (avoid rate-limit/hammering); print progress + total LLM cost.
- LLM cache invalidates on `judgePromptVersion` bump; `--no-cache`/`--refresh` honored.
- The analysis layer never calls `exec` directly — only through the injected `Judge` (tests use a fake).

---

### Task 1: Judge interface + CLIJudge

**Files:** Create `tui/internal/insights/judge.go`, `judge_test.go`.

**Produces:**
- `type Judge interface { Ask(ctx context.Context, prompt string) (text string, costUSD float64, err error) }`
- `type CLIJudge struct { Bin string; Timeout time.Duration }` + `func NewCLIJudge() *CLIJudge` (Bin="claude", Timeout=60s)
- `CLIJudge.Ask`: runs `<bin> -p --output-format=json` with `prompt` on stdin; parses the wrapper `{result, total_cost_usd, is_error}`; returns `result` text + cost; error if `is_error` or exit≠0.
- unexported `parseCLIResult(stdout []byte) (text string, cost float64, err error)`.

**Steps:**
- [ ] Test `parseCLIResult` on a captured wrapper JSON (`{"result":"hi","total_cost_usd":0.1,"is_error":false}`) → ("hi",0.1,nil); and `is_error:true` → error.
- [ ] Implement; `Ask` uses `exec.CommandContext`, `cmd.Stdin = strings.NewReader(prompt)`. Commit.

---

### Task 2: extractJSON helper (tolerant reply parsing)

**Files:** Add to `judge.go`; test in `judge_test.go`.

**Produces:** `func extractJSON(s string) ([]byte, bool)` — returns the first balanced `{…}` span (LLMs sometimes wrap JSON in prose/```json fences).

**Steps:**
- [ ] Test: bare JSON, fenced ```json block, JSON with leading prose → all extract the object; non-JSON → false.
- [ ] Implement (scan for first `{`, track brace depth honoring strings). Commit.

---

### Task 3: Per-session judgment

**Files:** Create `tui/internal/insights/judge_session.go`, `judge_session_test.go`.

**Produces:**
- `const judgePromptVersion = 1`
- `type Correction struct { Quote, Issue string }`
- `type Judgment struct { Friction int; PromptSpecificity int; Corrections []Correction; Loops []string; RootCause, Advice string; Available bool; Err string; CostUSD float64 }`
- `func sessionJudgePrompt(d Digest) string`
- `func JudgeSession(ctx, j Judge, d Digest) Judgment` — builds prompt, calls `j.Ask`, `extractJSON`, unmarshals; on any error returns `{Available:false, Err:…}`.

**Steps:**
- [ ] Test with a fake Judge returning a canned JSON → populated Judgment, Available=true. Fake returning prose-wrapped JSON → still parses. Fake returning error → Available=false, Err set.
- [ ] Implement. Prompt instructs: return ONLY JSON with fields friction(0-10), prompt_specificity(0-10), corrections[{quote,issue}], loops[], root_cause, advice. Commit.

---

### Task 4: Per-project CLAUDE.md/memory miner

**Files:** Create `tui/internal/insights/miner.go`, `miner_test.go`.

**Produces:**
- `type MemoryCandidate struct { Suggestion, Evidence string }`
- `type ProjectMined struct { Project string; Candidates []MemoryCandidate; Available bool; Err string; CostUSD float64 }`
- `func minePrompt(project string, prompts []string) string`
- `func MineProject(ctx, j Judge, project string, digests []Digest) ProjectMined` — collects up to N first-prompts across the project's sessions, asks the judge for recurring instructions that belong in CLAUDE.md/memory.

**Steps:**
- [ ] Test with a fake Judge → populated candidates; error → Available=false.
- [ ] Implement (cap prompts e.g. 60 to bound size). Commit.

---

### Task 5: LLM result cache

**Files:** Modify `tui/internal/insights/cache.go`; test in `cache_test.go`.

**Produces:**
- `func DigestHash(d Digest) string` (sha256 of canonical JSON)
- `func (c *Cache) llmKey(hash, kind, model string, version int) string`
- `GetJudgment/PutJudgment(hash, model)` and `GetMined/PutMined(project, hash, ...)` — keyed including `judgePromptVersion` so prompt edits invalidate.

**Steps:**
- [ ] Test: Put/Get round-trips a Judgment; different version → miss. Commit.

---

### Task 6: Cost-without-delivery (structural)

**Files:** Modify `tui/internal/session/session.go` (capture `HasPRLink` from `type:"pr-link"` events); create `tui/internal/insights/delivery.go`, `delivery_test.go`.

**Produces:**
- `Session.HasPRLink bool`
- `type DeliveryFn func(cwd string, start, end time.Time) (commits int, ok bool)` (real impl wraps `gitstat`)
- `func deliveryFinding(s *session.Session, usd float64, deliver DeliveryFn, minUSD float64) []Finding` — if `usd >= minUSD` and `!HasPRLink` and `commits==0` (or repo unknown) → `CatRouting`?-no, new `CatDelivery="delivery"` finding "high-cost session with no commit/PR".

**Steps:**
- [ ] Add `CatDelivery`. Session test: a `pr-link` line sets `HasPRLink`.
- [ ] delivery_test with a fake DeliveryFn: expensive+no-delivery → finding; cheap → none; has PR → none.
- [ ] Wire into corpus path in CLI (Task 7), not AnalyzeSession (needs git I/O). Commit.

---

### Task 7: CLI wiring (`--llm`, `--llm-max`)

**Files:** Modify `tui/cmd/claudeinsights/main.go`, `render.go` (+ test).

**Produces:** flags `--llm`, `--llm-max N` (default 10); after corpus build, run judge on top-N flagged sessions (cache-checked), miner once per project of those sessions; render an LLM coaching section + total LLM cost. `writeLLM(w, []Judgment, []ProjectMined, costUSD)`.

**Steps:**
- [ ] Add flags; orchestrate sequentially with progress to stderr; honor cache + `--llm-max`.
- [ ] Cost-without-delivery: run `deliveryFinding` over corpus using a `gitstat`-backed `DeliveryFn`, append to reports before render.
- [ ] `writeLLM` render test (pure). `go build`, `go vet ./...`, `go test ./...`. Commit.
- [ ] Manual smoke: `claudeinsights --session <id> --llm` on one real session (≈$0.10) — confirm corrections/advice; second run hits cache (no cost).

## Self-Review
- Judge + CLI impl → T1/T2. Session judgment (corrections, friction, prompt coach) → T3. CLAUDE.md miner → T4. LLM cache → T5. Cost-without-delivery → T6. CLI + render → T7.
- All four selected v1 coaching signals now delivered: sprawl+routing (Plan 2), CLAUDE.md candidates + prompt coach (T3/T4), cost-without-delivery (T6).
