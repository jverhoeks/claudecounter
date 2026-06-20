# claudeinsights apply + action list (Plan 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use `- [ ]`.

**Goal:** Synthesize per-session advice into one ranked action list, and merge mined CLAUDE.md
candidates into each flagged project's `<cwd>/CLAUDE.md` (dry-run diff by default, `--write` to apply).

**Architecture:** New `insights/apply.go` (LLM via injected `Judge`): `SynthesizeActions` and
`MergeClaudeMd`, plus a pure `unifiedDiff`. CLI gains `--apply`/`--write`; orchestration in
`cmd/claudeinsights/llm.go` reads files, prints diffs, and writes atomically on `--write`.

**Tech Stack:** Go stdlib (`os`, `path/filepath`, `context`, `encoding/json`). Reuses `insights`, `session`.

## Global Constraints

- Module `github.com/jverhoeks/claudecounter/tui`; build/test from `tui/`.
- LLM only via the injected `Judge` (tests use the existing `fakeJudge`).
- `--write` is the ONLY file-mutating path; default is dry-run diff. Atomic writes (temp + rename).
- Only write to `<cwd>` dirs that exist; never delete existing CLAUDE.md content (prompt-enforced + diff-visible).
- Reuse `extractJSON`; new prompts bump nothing unless judgePromptVersion changes.

---

### Task 1: SynthesizeActions

**Files:** Create `tui/internal/insights/apply.go`; test in new `tui/internal/insights/apply_test.go`.

**Produces:**
- `type ActionItem struct { Action string `json:"action"`; Why string `json:"why"`; Sessions int `json:"sessions"` }`
- `type ActionList struct { Items []ActionItem `json:"items"`; Available bool `json:"available"`; Err string `json:"err,omitempty"`; CostUSD float64 `json:"cost_usd"` }`
- `func actionsPrompt(js []Judgment) string`
- `func SynthesizeActions(ctx context.Context, j Judge, js []Judgment) ActionList`

**Behavior:** gather advice/corrections/loops from `Available` judgments into the prompt; ask for
JSON `{"actions":[{"action","why","sessions"}]}`; parse via `extractJSON`. No available judgments
→ `{Available:true, Items:nil}` (nothing to do, not an error). LLM/parse error → `{Available:false, Err}`.

- [ ] **Step 1: failing test** — fake judge returns `{"actions":[{"action":"verify build before done","why":"compile errors reached user","sessions":3}]}` → `Available`, 1 item, fields set; error judge → `Available:false`; empty judgments → `Available:true`, 0 items, judge not called.
- [ ] **Step 2: run** `go test ./internal/insights/ -run TestSynthesizeActions` → FAIL (undefined).
- [ ] **Step 3: implement** per spec.
- [ ] **Step 4: run** → PASS.
- [ ] **Step 5: commit** `feat(insights): synthesize ranked action list from judgments`.

---

### Task 2: MergeClaudeMd

**Files:** Modify `tui/internal/insights/apply.go`; test in `apply_test.go`.

**Produces:**
- `func mergePrompt(existing string, cands []MemoryCandidate) string`
- `func MergeClaudeMd(ctx context.Context, j Judge, existing string, cands []MemoryCandidate) (string, float64, error)` — returns merged text + cost.

**Behavior:** prompt includes existing file + candidates; instructs: preserve all existing content
verbatim, append a "## Insights (auto-suggested)" section deduping candidates already present,
return ONLY the complete file text (no fences/commentary). If the reply is fenced, strip a leading
/trailing ```` ``` ```` fence. No candidates → return existing unchanged, cost 0, nil.

- [ ] **Step 1: failing test** — fake judge returns merged text → returned verbatim (fence stripped); no candidates → existing returned, judge not called; judge error → error propagated.
- [ ] **Step 2–4:** TDD to green.
- [ ] **Step 5: commit** `feat(insights): LLM merge of candidates into CLAUDE.md`.

---

### Task 3: unifiedDiff (pure preview)

**Files:** Modify `tui/internal/insights/apply.go`; test in `apply_test.go`.

**Produces:** `func unifiedDiff(oldText, newText, path string) string` — a minimal line-based diff
(header with path; lines prefixed ` `, `-`, `+`). A simple LCS or "common prefix/suffix + middle"
diff is fine; it's for human preview, not patching.

- [ ] **Step 1: failing test** — adding two lines to a file shows `+` lines and the path header; identical inputs → header + no `+`/`-` lines.
- [ ] **Step 2–4:** implement (common-prefix/suffix trim, then mark remaining old as `-`, new as `+`). PASS.
- [ ] **Step 5: commit** `feat(insights): unified diff preview for CLAUDE.md merges`.

---

### Task 4: Apply orchestration + render (CLI)

**Files:** Modify `tui/cmd/claudeinsights/llm.go`, `main.go`; test new `apply_test.go` in cmd.

**Produces (cmd):**
- `func writeActions(w io.Writer, a insights.ActionList)` — renders `══ Top actions ══` (or a one-line note if unavailable/empty).
- `type applyResult struct { Project, Path, Diff string; Wrote, Skipped bool; Note string }`
- `func applyClaudeMd(root string, c insights.CorpusReport, projects map[string]struct{}, byProjectCands map[string][]insights.MemoryCandidate, j insights.Judge, doWrite bool) []applyResult` — for each project: resolve cwd from `c.Sessions` (first matching non-empty `Cwd`); skip if `!isDir(cwd)`; read existing CLAUDE.md; `MergeClaudeMd`; build diff; if `doWrite` and changed, atomic write; return results.
- `func writeApply(w io.Writer, results []applyResult, doWrite bool)` — prints each project's diff or "wrote"/"skipped" note.
- helper `atomicWrite(path, content string) error` (temp in same dir + `os.Rename`); `isDir(p string) bool`.

**Wiring in `runLLM`:** after judgments+mining, call `SynthesizeActions` (cache by judged session-id
hash) and `writeActions`. Thread `byProject` candidates out so `--apply` can use them. Return the
collected `[]insights.MemoryCandidate` per project from runLLM (or accept the apply step inside runLLM).

**Wiring in `main.go`:** add `--apply`, `--write` flags. `--apply` forces `*llm=true`. After
`runLLM`, if `--apply`, run `applyClaudeMd(... doWrite=*write)` and `writeApply`. `--write` without
`--apply` → log a warning, ignore.

- [ ] **Step 1: failing tests** (cmd `apply_test.go`):
  - `writeActions` renders items + "seen in N".
  - `unifiedDiff`/apply: with a fake judge returning `existing+"\n## Insights\n- x\n"`, a `t.TempDir()` project dir containing a CLAUDE.md: dry-run (`doWrite=false`) leaves the file byte-identical and returns a non-empty Diff; `doWrite=true` writes the merged content; a project whose cwd doesn't exist yields `Skipped` with a note.
- [ ] **Step 2: run** → FAIL (undefined).
- [ ] **Step 3: implement** orchestration + renderers + atomic write.
- [ ] **Step 4: run** `go build ./... && go vet ./... && go test ./...` → all PASS.
- [ ] **Step 5: smoke** (manual): `claudeinsights --session <id> --llm --apply` shows a diff and writes nothing; `--apply --write` writes `<cwd>/CLAUDE.md`. Verify with `git diff` in that repo, then revert.
- [ ] **Step 6: commit** `feat(claudeinsights): --apply/--write CLAUDE.md merge + action list`.

---

### Task 5: README

**Files:** Modify `README.md`.

- [ ] Document `--apply` (dry-run) and `--write` under the coaching section; note dry-run-by-default safety. Commit `docs: document claudeinsights --apply/--write`.

## Self-Review
- Action list → T1 + T4 render/wiring. CLAUDE.md merge → T2 + T4 orchestration. Diff preview → T3.
  Safety (dry-run default, atomic, existing-dir-only) → T4. Docs → T5.
- Reuses `Judge`, `extractJSON`, `MemoryCandidate`, `fakeJudge`. No new external deps.
