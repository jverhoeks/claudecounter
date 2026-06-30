# claudeinsights Structural Core (Plan 1 of 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working `claudeinsights` binary that scans the transcript corpus and reports structural usage / token-waste / tool-abuse / skill-overload / context-overload / loop findings, both as a ranked corpus leaderboard and a per-session drill-down.

**Architecture:** A new pure `internal/insights` package analyzes already-parsed `session.Session` values (no I/O, no clock, no network) and a new `cmd/claudeinsights` binary walks the corpus, parses sessions in parallel (mirroring `safety.Scan`), and renders text / JSON / CSV. No existing code changes — only new files.

**Tech Stack:** Go 1.25 (toolchain 1.26), stdlib only (`encoding/json`, `encoding/csv`, `flag`, `path/filepath`, `runtime`, `sync`), reusing internal packages `session`, `pricing`, `ui`.

## Global Constraints

- Module path: `github.com/jverhoeks/claudecounter/tui` — all imports use this prefix.
- `go 1.25.0` in `tui/go.mod`; build/test from the `tui/` directory.
- Analysis layer (`internal/insights`) is **pure**: no `os`, no `time.Now`, no network. Callers pass parsed sessions and a clock-derived window in.
- Reuse `session.Session` as-is; do **not** modify the `session` package in this plan (text capture is Plan 3).
- Per-stream loop detection: main (`ToolCall.Sub==false`) and subagent (`Sub==true`) are separate streams — never merge them, to avoid phantom loops.
- Context-window default is 200_000; `opus-4-8[1m]` (and any id containing `[1m]`) is 1_000_000.
- Thresholds live as named fields on `Thresholds` with a `DefaultThresholds()` constructor — no magic numbers inside heuristics.
- Pure writer functions take `io.Writer` (mirror `writeReportCSV`/`writeScorecard`) so they are testable without stdout.
- Run `gofmt`/`go vet ./...` clean; tests via `go test ./...` from `tui/`.

---

### Task 1: Context-window map

**Files:**
- Create: `tui/internal/insights/window.go`
- Test: `tui/internal/insights/window_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `func ContextWindow(model string) uint64` — returns the model's context window in tokens (default 200_000).

- [ ] **Step 1: Write the failing test**

```go
package insights

import "testing"

func TestContextWindow(t *testing.T) {
	cases := []struct {
		model string
		want  uint64
	}{
		{"claude-opus-4-8[1m]", 1_000_000},
		{"claude-sonnet-4-6[1m]", 1_000_000},
		{"claude-opus-4-8", 200_000},
		{"claude-sonnet-4-6", 200_000},
		{"claude-haiku-4-5", 200_000},
		{"", 200_000},
		{"something-unknown", 200_000},
	}
	for _, c := range cases {
		if got := ContextWindow(c.model); got != c.want {
			t.Errorf("ContextWindow(%q) = %d, want %d", c.model, got, c.want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run TestContextWindow -v`
Expected: FAIL — `undefined: ContextWindow`.

- [ ] **Step 3: Write minimal implementation**

```go
// Package insights analyzes parsed Claude Code sessions for structural
// usage, waste, abuse, and loop patterns. It is a pure layer: no I/O, no
// clock, no network — callers pass parsed sessions in and get findings out.
package insights

import "strings"

const defaultWindow uint64 = 200_000

// ContextWindow returns the model's context window in tokens. The pricing
// table carries no window field, so this small map fills the gap. Any model
// id flagged with the 1M variant marker ("[1m]") gets 1,000,000; everything
// else falls back to the 200k default.
func ContextWindow(model string) uint64 {
	if strings.Contains(model, "[1m]") {
		return 1_000_000
	}
	return defaultWindow
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run TestContextWindow -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/window.go tui/internal/insights/window_test.go
git commit -m "feat(insights): context-window map (200k default, 1M for [1m] models)"
```

---

### Task 2: Core types and thresholds

**Files:**
- Create: `tui/internal/insights/insights.go`
- Test: `tui/internal/insights/insights_test.go`

**Interfaces:**
- Consumes: `pricing.Usage` (from `internal/pricing`).
- Produces:
  - `type Category string` with consts `CatWaste, CatAbuse, CatSkill, CatContext, CatLoop`.
  - `type Finding struct { Category Category; Detail string; Count int; USD float64 }`.
  - `type SessionReport struct { ID, Project, Cwd, Model string; Start, End time.Time; Tokens pricing.Usage; USD float64; Prompts, ToolCalls int; PeakContext uint64; CtxPct float64; Findings []Finding; WasteUSD float64; Score float64 }`.
  - `type Thresholds struct { RepeatToolN, LoopMin, ReadDupN int; CtxHighPct float64; HighCtxTokens, TinyOutput uint64 }`.
  - `func DefaultThresholds() Thresholds`.

- [ ] **Step 1: Write the failing test**

```go
package insights

import "testing"

func TestDefaultThresholds(t *testing.T) {
	th := DefaultThresholds()
	if th.RepeatToolN != 3 || th.LoopMin != 3 || th.ReadDupN != 2 {
		t.Errorf("counts: %+v", th)
	}
	if th.CtxHighPct != 80 {
		t.Errorf("CtxHighPct = %v, want 80", th.CtxHighPct)
	}
	if th.HighCtxTokens != 50_000 || th.TinyOutput != 100 {
		t.Errorf("token thresholds: %+v", th)
	}
}

func TestCategoryConsts(t *testing.T) {
	got := []Category{CatWaste, CatAbuse, CatSkill, CatContext, CatLoop}
	want := []string{"waste", "abuse", "skill", "context", "loop"}
	for i := range got {
		if string(got[i]) != want[i] {
			t.Errorf("cat[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run 'TestDefaultThresholds|TestCategoryConsts' -v`
Expected: FAIL — undefined identifiers.

- [ ] **Step 3: Write minimal implementation**

Append to `tui/internal/insights/insights.go`:

```go
package insights

import (
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// Category labels a finding's kind.
type Category string

const (
	CatWaste   Category = "waste"
	CatAbuse   Category = "abuse"
	CatSkill   Category = "skill"
	CatContext Category = "context"
	CatLoop    Category = "loop"
)

// Finding is one structural observation about a session. USD is an estimated
// wasted-cost attribution where meaningful, else 0.
type Finding struct {
	Category Category `json:"category"`
	Detail   string   `json:"detail"`
	Count    int      `json:"count"`
	USD      float64  `json:"usd,omitempty"`
}

// SessionReport is the full structural analysis of one parsed session.
type SessionReport struct {
	ID          string        `json:"id"`
	Project     string        `json:"project"`
	Cwd         string        `json:"cwd"`
	Model       string        `json:"model"`
	Start       time.Time     `json:"start"`
	End         time.Time     `json:"end"`
	Tokens      pricing.Usage `json:"tokens"`
	USD         float64       `json:"usd"`
	Prompts     int           `json:"prompts"`
	ToolCalls   int           `json:"tool_calls"`
	PeakContext uint64        `json:"peak_context"`
	CtxPct      float64       `json:"ctx_pct"`
	Findings    []Finding     `json:"findings"`
	WasteUSD    float64       `json:"waste_usd"`
	Score       float64       `json:"score"`
}

// Thresholds tune the heuristics. All callers should start from
// DefaultThresholds() and override fields as needed.
type Thresholds struct {
	RepeatToolN   int     // same (Name+Target) called >= N => abuse finding
	LoopMin       int     // a tool subsequence repeated >= N times => loop
	ReadDupN      int     // same Read target read >= N times => waste finding
	CtxHighPct    float64 // peak context >= this % of window => overload finding
	HighCtxTokens uint64  // a turn whose input+cache >= this ...
	TinyOutput    uint64  // ... and whose output <= this is a high-ctx/tiny-out waste
}

// DefaultThresholds returns conservative starting values; see the design spec
// — these are tuned-by-experience starting points, not laws.
func DefaultThresholds() Thresholds {
	return Thresholds{
		RepeatToolN:   3,
		LoopMin:       3,
		ReadDupN:      2,
		CtxHighPct:    80,
		HighCtxTokens: 50_000,
		TinyOutput:    100,
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run 'TestDefaultThresholds|TestCategoryConsts' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/insights.go tui/internal/insights/insights_test.go
git commit -m "feat(insights): core finding types and tunable thresholds"
```

---

### Task 3: Waste findings

**Files:**
- Modify: `tui/internal/insights/insights.go`
- Test: `tui/internal/insights/waste_test.go`

**Interfaces:**
- Consumes: `*session.Session`, `pricing.Table`, `Thresholds`, `Finding`.
- Produces: `func wasteFindings(s *session.Session, table pricing.Table, th Thresholds) []Finding` (unexported; exercised via test in same package).

Heuristics (each appends at most one aggregated Finding):
1. **Failed tool calls** — count `ToolCall.IsErr`; USD = session avg cost-per-turn × failedCount.
2. **Redundant reads** — `Read` calls whose `Target` repeats `>= ReadDupN`; Count = sum of extra reads.
3. **High-context / tiny-output turns** — `Turn` with `Input+CacheCreate+CacheRead >= HighCtxTokens` and `Output <= TinyOutput`; USD = sum of those turns' cost.

- [ ] **Step 1: Write the failing test**

```go
package insights

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func priceTable() pricing.Table {
	return pricing.Table{Models: map[string]pricing.ModelPrice{
		"m": {InputPerMTok: 1, OutputPerMTok: 1, CacheCreationPerMTok: 1, CacheReadPerMTok: 1},
	}}
}

func TestWasteFindings(t *testing.T) {
	now := time.Now()
	s := &session.Session{
		ToolCalls: []session.ToolCall{
			{Name: "Bash", IsErr: true},
			{Name: "Read", Target: "/a.go"},
			{Name: "Read", Target: "/a.go"},
			{Name: "Read", Target: "/a.go"},
		},
		Turns: []session.Turn{
			{Time: now, Model: "m", Usage: pricing.Usage{InputTokens: 60_000, OutputTokens: 10}},
		},
	}
	fs := wasteFindings(s, priceTable(), DefaultThresholds())
	got := map[string]Finding{}
	for _, f := range fs {
		got[f.Detail[:4]] = f // crude key by detail prefix
	}
	if len(fs) != 3 {
		t.Fatalf("want 3 waste findings, got %d: %+v", len(fs), fs)
	}
	for _, f := range fs {
		if f.Category != CatWaste {
			t.Errorf("category = %q", f.Category)
		}
	}
}

func TestWasteFindings_None(t *testing.T) {
	s := &session.Session{
		ToolCalls: []session.ToolCall{{Name: "Read", Target: "/a.go"}},
	}
	if fs := wasteFindings(s, priceTable(), DefaultThresholds()); len(fs) != 0 {
		t.Errorf("want 0, got %+v", fs)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run TestWasteFindings -v`
Expected: FAIL — `undefined: wasteFindings`.

- [ ] **Step 3: Write minimal implementation**

Append to `tui/internal/insights/insights.go` (add `"fmt"`, `"github.com/jverhoeks/claudecounter/tui/internal/session"` to imports):

```go
// avgTurnUSD is the session's mean priced cost per counted turn (0 if none).
func avgTurnUSD(s *session.Session, table pricing.Table) float64 {
	if len(s.Turns) == 0 {
		return 0
	}
	var total float64
	for _, t := range s.Turns {
		total += table.Cost(t.Model, t.Usage)
	}
	return total / float64(len(s.Turns))
}

func wasteFindings(s *session.Session, table pricing.Table, th Thresholds) []Finding {
	var out []Finding

	// 1. Failed tool calls.
	failed := 0
	for _, c := range s.ToolCalls {
		if c.IsErr {
			failed++
		}
	}
	if failed > 0 {
		out = append(out, Finding{
			Category: CatWaste,
			Detail:   fmt.Sprintf("%d failed tool call(s) — each burns a round-trip", failed),
			Count:    failed,
			USD:      avgTurnUSD(s, table) * float64(failed),
		})
	}

	// 2. Redundant reads of the same target.
	reads := map[string]int{}
	for _, c := range s.ToolCalls {
		if c.Name == "Read" && c.Target != "" {
			reads[c.Target]++
		}
	}
	extra := 0
	files := 0
	for _, n := range reads {
		if n >= th.ReadDupN {
			extra += n - 1
			files++
		}
	}
	if extra > 0 {
		out = append(out, Finding{
			Category: CatWaste,
			Detail:   fmt.Sprintf("%d redundant Read(s) across %d file(s)", extra, files),
			Count:    extra,
		})
	}

	// 3. High-context / tiny-output turns.
	hc := 0
	var hcUSD float64
	for _, t := range s.Turns {
		ctx := t.Usage.InputTokens + t.Usage.CacheCreationInputTokens + t.Usage.CacheReadInputTokens
		if ctx >= th.HighCtxTokens && t.Usage.OutputTokens <= th.TinyOutput {
			hc++
			hcUSD += table.Cost(t.Model, t.Usage)
		}
	}
	if hc > 0 {
		out = append(out, Finding{
			Category: CatWaste,
			Detail:   fmt.Sprintf("%d turn(s) paid for big context but produced tiny output", hc),
			Count:    hc,
			USD:      hcUSD,
		})
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run TestWasteFindings -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/insights.go tui/internal/insights/waste_test.go
git commit -m "feat(insights): token-waste heuristics (failed tools, redundant reads, high-ctx/tiny-out)"
```

---

### Task 4: Abuse and skill findings

**Files:**
- Modify: `tui/internal/insights/insights.go`
- Test: `tui/internal/insights/abuse_test.go`

**Interfaces:**
- Consumes: `*session.Session`, `Thresholds`.
- Produces:
  - `func abuseFindings(s *session.Session, th Thresholds) []Finding`
  - `func skillFindings(s *session.Session) []Finding`

- [ ] **Step 1: Write the failing test**

```go
package insights

import (
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func TestAbuseFindings_RepeatedCall(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		{Name: "Bash", Target: "go test"},
		{Name: "Bash", Target: "go test"},
		{Name: "Bash", Target: "go test"},
	}}
	fs := abuseFindings(s, DefaultThresholds())
	if len(fs) != 1 || fs[0].Category != CatAbuse || fs[0].Count != 3 {
		t.Fatalf("want one abuse finding count=3, got %+v", fs)
	}
}

func TestAbuseFindings_BelowThreshold(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		{Name: "Bash", Target: "go test"},
		{Name: "Bash", Target: "go test"},
	}}
	if fs := abuseFindings(s, DefaultThresholds()); len(fs) != 0 {
		t.Errorf("want 0, got %+v", fs)
	}
}

func TestSkillFindings(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		{Name: "Skill", Target: "brainstorming"},
		{Name: "Skill", Target: "brainstorming"},
		{Name: "Skill", Target: "writing-plans"},
		{Name: "Skill", Target: "tdd"},
		{Name: "Skill", Target: "debugging"},
	}}
	fs := skillFindings(s)
	if len(fs) != 1 || fs[0].Category != CatSkill {
		t.Fatalf("want one skill finding, got %+v", fs)
	}
	if fs[0].Count != 4 { // 4 distinct skills
		t.Errorf("distinct skills Count = %d, want 4", fs[0].Count)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run 'TestAbuseFindings|TestSkillFindings' -v`
Expected: FAIL — undefined functions.

- [ ] **Step 3: Write minimal implementation**

Append to `tui/internal/insights/insights.go` (add `"sort"` to imports):

```go
const skillOverloadDistinct = 4 // > this many distinct skills in one session is a smell

func abuseFindings(s *session.Session, th Thresholds) []Finding {
	type key struct{ name, target string }
	counts := map[key]int{}
	for _, c := range s.ToolCalls {
		counts[key{c.Name, c.Target}]++
	}
	var out []Finding
	// Stable order: emit worst (highest count) first.
	type kc struct {
		k key
		n int
	}
	var rows []kc
	for k, n := range counts {
		if n >= th.RepeatToolN && k.target != "" {
			rows = append(rows, kc{k, n})
		}
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].n != rows[j].n {
			return rows[i].n > rows[j].n
		}
		return rows[i].k.name+rows[i].k.target < rows[j].k.name+rows[j].k.target
	})
	for _, r := range rows {
		out = append(out, Finding{
			Category: CatAbuse,
			Detail:   fmt.Sprintf("%s %q called %d×", r.k.name, trunc(r.k.target, 60), r.n),
			Count:    r.n,
		})
	}
	return out
}

func skillFindings(s *session.Session) []Finding {
	distinct := map[string]struct{}{}
	for _, c := range s.ToolCalls {
		if c.Name == "Skill" && c.Target != "" {
			distinct[c.Target] = struct{}{}
		}
	}
	if len(distinct) <= skillOverloadDistinct {
		return nil
	}
	return []Finding{{
		Category: CatSkill,
		Detail:   fmt.Sprintf("%d distinct skills invoked in one session", len(distinct)),
		Count:    len(distinct),
	}}
}

// trunc shortens s to n runes with an ellipsis.
func trunc(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run 'TestAbuseFindings|TestSkillFindings' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/insights.go tui/internal/insights/abuse_test.go
git commit -m "feat(insights): tool-abuse (repeated calls) and skill-overload findings"
```

---

### Task 5: Per-stream loop detection

**Files:**
- Create: `tui/internal/insights/loops.go`
- Test: `tui/internal/insights/loops_test.go`

**Interfaces:**
- Consumes: `*session.Session`, `Thresholds`, `Finding`, `CatLoop`.
- Produces: `func loopFindings(s *session.Session, th Thresholds) []Finding` — detects, **per stream** (main vs subagent), a contiguous tool subsequence of window size 1..4 that repeats `>= LoopMin` times back-to-back.

- [ ] **Step 1: Write the failing test**

```go
package insights

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func tc(name, target string, sub bool) session.ToolCall {
	return session.ToolCall{Name: name, Target: target, Sub: sub}
}

func TestLoopFindings_PingPong(t *testing.T) {
	// Edit/Bash repeated 3× on the main stream.
	s := &session.Session{ToolCalls: []session.ToolCall{
		tc("Edit", "/m.go", false), tc("Bash", "go test", false),
		tc("Edit", "/m.go", false), tc("Bash", "go test", false),
		tc("Edit", "/m.go", false), tc("Bash", "go test", false),
	}}
	fs := loopFindings(s, DefaultThresholds())
	if len(fs) != 1 || fs[0].Category != CatLoop {
		t.Fatalf("want one loop finding, got %+v", fs)
	}
	if fs[0].Count != 3 {
		t.Errorf("repeat Count = %d, want 3", fs[0].Count)
	}
	if !strings.Contains(fs[0].Detail, "Edit") {
		t.Errorf("detail missing cycle: %q", fs[0].Detail)
	}
}

func TestLoopFindings_StreamsNotMerged(t *testing.T) {
	// Same single call alternating main/sub must NOT look like a loop.
	s := &session.Session{ToolCalls: []session.ToolCall{
		tc("Read", "/a", false), tc("Read", "/a", true),
		tc("Read", "/a", false), tc("Read", "/a", true),
		tc("Read", "/a", false), tc("Read", "/a", true),
	}}
	// Each stream alone IS 3 repeats of [Read /a] — that's a real per-stream
	// loop. Assert we get exactly two (one per stream), proving we split.
	fs := loopFindings(s, DefaultThresholds())
	if len(fs) != 2 {
		t.Fatalf("want 2 per-stream loops, got %d: %+v", len(fs), fs)
	}
}

func TestLoopFindings_None(t *testing.T) {
	s := &session.Session{ToolCalls: []session.ToolCall{
		tc("Read", "/a", false), tc("Edit", "/b", false), tc("Bash", "x", false),
	}}
	if fs := loopFindings(s, DefaultThresholds()); len(fs) != 0 {
		t.Errorf("want 0, got %+v", fs)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run TestLoopFindings -v`
Expected: FAIL — `undefined: loopFindings`.

- [ ] **Step 3: Write minimal implementation**

```go
package insights

import "fmt"

const maxLoopWindow = 4

// loopFindings splits tool calls into the main and subagent streams and reports
// the strongest back-to-back repeated cycle in each (window size 1..4 repeated
// >= LoopMin times). Streams are analyzed independently so interleaved main +
// subagent traffic never forms a phantom loop.
func loopFindings(s *session.Session, th Thresholds) []Finding {
	var main, sub []string
	for _, c := range s.ToolCalls {
		tok := c.Name + ":" + c.Target
		if c.Sub {
			sub = append(sub, tok)
		} else {
			main = append(main, tok)
		}
	}
	var out []Finding
	if f, ok := bestLoop(main, th.LoopMin, "main"); ok {
		out = append(out, f)
	}
	if f, ok := bestLoop(sub, th.LoopMin, "subagent"); ok {
		out = append(out, f)
	}
	return out
}

// bestLoop scans seq for the longest-running contiguous repetition of any
// window of size 1..maxLoopWindow and returns a Finding if the run repeats at
// least loopMin times. "Longest-running" is scored by total covered length so
// a 3× two-call cycle (covers 6) beats a 3× one-call cycle (covers 3).
func bestLoop(seq []string, loopMin int, stream string) (Finding, bool) {
	bestReps, bestCover, bestW, bestAt := 0, 0, 0, 0
	for w := 1; w <= maxLoopWindow; w++ {
		for i := 0; i+w <= len(seq); i++ {
			reps := 1
			for j := i + w; j+w <= len(seq); j += w {
				if !windowEqual(seq, i, j, w) {
					break
				}
				reps++
			}
			if reps >= loopMin && reps*w > bestCover {
				bestReps, bestCover, bestW, bestAt = reps, reps*w, w, i
			}
		}
	}
	if bestReps < loopMin {
		return Finding{}, false
	}
	cycle := seq[bestAt : bestAt+bestW]
	return Finding{
		Category: CatLoop,
		Detail:   fmt.Sprintf("%s stream: cycle [%s] repeated %d×", stream, joinCycle(cycle), bestReps),
		Count:    bestReps,
	}, true
}

func windowEqual(seq []string, a, b, w int) bool {
	for k := 0; k < w; k++ {
		if seq[a+k] != seq[b+k] {
			return false
		}
	}
	return true
}

func joinCycle(cycle []string) string {
	out := ""
	for i, c := range cycle {
		if i > 0 {
			out += " → "
		}
		// token is "Name:Target"; show Name plus a short target tail.
		name, target := c, ""
		for k := 0; k < len(c); k++ {
			if c[k] == ':' {
				name, target = c[:k], c[k+1:]
				break
			}
		}
		if target != "" {
			out += name + " " + trunc(target, 24)
		} else {
			out += name
		}
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run TestLoopFindings -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/loops.go tui/internal/insights/loops_test.go
git commit -m "feat(insights): per-stream back-to-back loop detection"
```

---

### Task 6: AnalyzeSession (assemble per-session report)

**Files:**
- Modify: `tui/internal/insights/insights.go`
- Test: `tui/internal/insights/insights_test.go`

**Interfaces:**
- Consumes: `*session.Session`, `pricing.Table`, `Thresholds`, and all `*Findings` helpers + `ContextWindow`.
- Produces: `func AnalyzeSession(s *session.Session, table pricing.Table, th Thresholds) SessionReport`.

Behavior: fills usage fields, computes dominant model (most turns), `USD` (sum priced turns), `CtxPct = 100*PeakContext/window`, a context-overload Finding when `CtxPct >= CtxHighPct`, aggregates all findings, sets `WasteUSD` = sum of finding USD, and `Score = WasteUSD + len(Findings)` (ranking key; refined in Plan 3).

- [ ] **Step 1: Write the failing test**

```go
func TestAnalyzeSession(t *testing.T) {
	s := &session.Session{
		ID: "s1", Cwd: "/tmp/proj",
		Prompts: 2,
		ToolCalls: []session.ToolCall{
			{Name: "Bash", Target: "go test", IsErr: true},
			{Name: "Bash", Target: "go test"},
			{Name: "Bash", Target: "go test"},
		},
		Turns: []session.Turn{
			{Model: "m", Usage: pricing.Usage{InputTokens: 100, OutputTokens: 50}},
			{Model: "m", Usage: pricing.Usage{InputTokens: 100, OutputTokens: 50}},
		},
		Tokens:      pricing.Usage{InputTokens: 200, OutputTokens: 100},
		PeakContext: 180_000, // 90% of 200k default
	}
	r := AnalyzeSession(s, priceTable(), DefaultThresholds())
	if r.ID != "s1" || r.Model != "m" || r.ToolCalls != 3 || r.Prompts != 2 {
		t.Errorf("scalars wrong: %+v", r)
	}
	if r.CtxPct < 89 || r.CtxPct > 91 {
		t.Errorf("CtxPct = %v, want ~90", r.CtxPct)
	}
	// Expect findings across abuse (repeated Bash), waste (failed call), context (90%).
	cats := map[Category]bool{}
	for _, f := range r.Findings {
		cats[f.Category] = true
	}
	for _, want := range []Category{CatAbuse, CatWaste, CatContext} {
		if !cats[want] {
			t.Errorf("missing %q finding in %+v", want, r.Findings)
		}
	}
	if r.Score <= 0 {
		t.Errorf("Score = %v, want > 0", r.Score)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run TestAnalyzeSession -v`
Expected: FAIL — `undefined: AnalyzeSession`.

- [ ] **Step 3: Write minimal implementation**

Append to `tui/internal/insights/insights.go`:

```go
// dominantModel returns the model with the most turns (empty if none).
func dominantModel(s *session.Session) string {
	counts := map[string]int{}
	for _, t := range s.Turns {
		counts[t.Model]++
	}
	best, bestN := "", 0
	for m, n := range counts {
		if n > bestN || (n == bestN && m < best) {
			best, bestN = m, n
		}
	}
	return best
}

// AnalyzeSession runs every structural heuristic over one parsed session and
// returns a single report. Pure: no I/O, no clock.
func AnalyzeSession(s *session.Session, table pricing.Table, th Thresholds) SessionReport {
	model := dominantModel(s)
	var usd float64
	for _, t := range s.Turns {
		usd += table.Cost(t.Model, t.Usage)
	}

	r := SessionReport{
		ID:          s.ID,
		Cwd:         s.Cwd,
		Model:       model,
		Start:       s.Start,
		End:         s.End,
		Tokens:      s.Tokens,
		USD:         usd,
		Prompts:     s.Prompts,
		ToolCalls:   len(s.ToolCalls),
		PeakContext: s.PeakContext,
	}

	if win := ContextWindow(model); win > 0 {
		r.CtxPct = 100 * float64(s.PeakContext) / float64(win)
	}

	r.Findings = append(r.Findings, wasteFindings(s, table, th)...)
	r.Findings = append(r.Findings, abuseFindings(s, th)...)
	r.Findings = append(r.Findings, skillFindings(s)...)
	r.Findings = append(r.Findings, loopFindings(s, th)...)
	if r.CtxPct >= th.CtxHighPct {
		r.Findings = append(r.Findings, Finding{
			Category: CatContext,
			Detail:   fmt.Sprintf("peak context %.0f%% of %s window", r.CtxPct, model),
			Count:    1,
		})
	}

	for _, f := range r.Findings {
		r.WasteUSD += f.USD
	}
	r.Score = r.WasteUSD + float64(len(r.Findings))
	return r
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run TestAnalyzeSession -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/insights.go tui/internal/insights/insights_test.go
git commit -m "feat(insights): AnalyzeSession assembles per-session structural report"
```

---

### Task 7: AnalyzeCorpus (ranking + project aggregation)

**Files:**
- Create: `tui/internal/insights/corpus.go`
- Test: `tui/internal/insights/corpus_test.go`

**Interfaces:**
- Consumes: `[]SessionReport`.
- Produces:
  - `type ProjectAgg struct { Project string; Sessions int; USD, WasteUSD float64; Findings int }`
  - `type CorpusReport struct { Sessions []SessionReport; Projects []ProjectAgg; TotalUSD, TotalWasteUSD float64 }`
  - `func BuildCorpus(reports []SessionReport) CorpusReport` — sorts `Sessions` worst-first (by `Score` desc, then `USD` desc, then `ID`), aggregates per `Project`, sums totals. Projects sorted by `WasteUSD` desc.

> Note: `SessionReport.Project` is set by the scanner (Task 8), not `AnalyzeSession`. `BuildCorpus` groups on whatever `Project` is present ("" allowed).

- [ ] **Step 1: Write the failing test**

```go
package insights

import "testing"

func TestBuildCorpus(t *testing.T) {
	reports := []SessionReport{
		{ID: "a", Project: "p1", USD: 1, WasteUSD: 0.5, Score: 2, Findings: []Finding{{}, {}}},
		{ID: "b", Project: "p1", USD: 3, WasteUSD: 2, Score: 5, Findings: []Finding{{}}},
		{ID: "c", Project: "p2", USD: 0.2, WasteUSD: 0, Score: 0},
	}
	c := BuildCorpus(reports)
	if c.Sessions[0].ID != "b" {
		t.Errorf("worst-first failed: %s", c.Sessions[0].ID)
	}
	if len(c.Projects) != 2 || c.Projects[0].Project != "p1" {
		t.Errorf("projects: %+v", c.Projects)
	}
	if c.Projects[0].Sessions != 2 || c.Projects[0].WasteUSD != 2.5 {
		t.Errorf("p1 agg: %+v", c.Projects[0])
	}
	if c.TotalUSD != 4.2 || c.TotalWasteUSD != 2.5 {
		t.Errorf("totals: %v %v", c.TotalUSD, c.TotalWasteUSD)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run TestBuildCorpus -v`
Expected: FAIL — `undefined: BuildCorpus`.

- [ ] **Step 3: Write minimal implementation**

```go
package insights

import "sort"

// ProjectAgg rolls one project's sessions into a single row.
type ProjectAgg struct {
	Project  string  `json:"project"`
	Sessions int     `json:"sessions"`
	USD      float64 `json:"usd"`
	WasteUSD float64 `json:"waste_usd"`
	Findings int     `json:"findings"`
}

// CorpusReport is the ranked, aggregated view across all analyzed sessions.
type CorpusReport struct {
	Sessions      []SessionReport `json:"sessions"`
	Projects      []ProjectAgg    `json:"projects"`
	TotalUSD      float64         `json:"total_usd"`
	TotalWasteUSD float64         `json:"total_waste_usd"`
}

// BuildCorpus ranks sessions worst-first and aggregates per project. Pure.
func BuildCorpus(reports []SessionReport) CorpusReport {
	sorted := make([]SessionReport, len(reports))
	copy(sorted, reports)
	sort.Slice(sorted, func(i, j int) bool {
		if sorted[i].Score != sorted[j].Score {
			return sorted[i].Score > sorted[j].Score
		}
		if sorted[i].USD != sorted[j].USD {
			return sorted[i].USD > sorted[j].USD
		}
		return sorted[i].ID < sorted[j].ID
	})

	byProj := map[string]*ProjectAgg{}
	var c CorpusReport
	for _, r := range reports {
		c.TotalUSD += r.USD
		c.TotalWasteUSD += r.WasteUSD
		p := byProj[r.Project]
		if p == nil {
			p = &ProjectAgg{Project: r.Project}
			byProj[r.Project] = p
		}
		p.Sessions++
		p.USD += r.USD
		p.WasteUSD += r.WasteUSD
		p.Findings += len(r.Findings)
	}
	for _, p := range byProj {
		c.Projects = append(c.Projects, *p)
	}
	sort.Slice(c.Projects, func(i, j int) bool {
		if c.Projects[i].WasteUSD != c.Projects[j].WasteUSD {
			return c.Projects[i].WasteUSD > c.Projects[j].WasteUSD
		}
		return c.Projects[i].Project < c.Projects[j].Project
	})
	c.Sessions = sorted
	return c
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run TestBuildCorpus -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/corpus.go tui/internal/insights/corpus_test.go
git commit -m "feat(insights): corpus ranking and per-project aggregation"
```

---

### Task 8: Corpus scanner (walk + parse in parallel)

**Files:**
- Create: `tui/internal/insights/scan.go`
- Test: `tui/internal/insights/scan_test.go`

**Interfaces:**
- Consumes: `session.Parse`, `pricing.Table`, `Thresholds`, `AnalyzeSession`, `projectUnder` (re-implemented locally — same logic as `safety.projectUnder`).
- Produces: `func Scan(root string, table pricing.Table, th Thresholds, notBefore time.Time) ([]SessionReport, error)` — walks `root/*/*.jsonl` (skipping `/subagents/` files, which `session.Parse` folds in itself), parses each main transcript whose mtime ≥ notBefore, analyzes it, sets `Project`, and returns reports. Parallel worker pool mirrors `safety.Scan`.

- [ ] **Step 1: Write the failing test**

```go
package insights

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const scanFixture = `{"type":"user","timestamp":"2026-06-01T10:00:00Z","sessionId":"s1","cwd":"/tmp/proj","permissionMode":"default","message":{"role":"user","content":"do X"}}
{"type":"assistant","timestamp":"2026-06-01T10:00:05Z","requestId":"r1","message":{"id":"m1","model":"claude-opus-4-8[1m]","usage":{"input_tokens":100,"output_tokens":5},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"go test"}}]}}
`

func TestScan(t *testing.T) {
	root := t.TempDir()
	proj := filepath.Join(root, "-tmp-proj")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, "s1.jsonl"), []byte(scanFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	reports, err := Scan(root, priceTable(), DefaultThresholds(), time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if len(reports) != 1 {
		t.Fatalf("want 1 report, got %d", len(reports))
	}
	if reports[0].Project != "-tmp-proj" {
		t.Errorf("Project = %q", reports[0].Project)
	}
	if reports[0].Model != "claude-opus-4-8[1m]" {
		t.Errorf("Model = %q", reports[0].Model)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/insights/ -run TestScan -v`
Expected: FAIL — `undefined: Scan`.

- [ ] **Step 3: Write minimal implementation**

```go
package insights

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

// Scan walks root for main session transcripts modified at/after notBefore,
// parses + analyzes each in parallel, and returns one SessionReport per
// session. Subagent files (under /subagents/) are skipped here because
// session.Parse folds them into their main transcript.
func Scan(root string, table pricing.Table, th Thresholds, notBefore time.Time) ([]SessionReport, error) {
	paths := make(chan string, 256)
	walkErr := make(chan error, 1)
	go func() {
		walkErr <- filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return nil
			}
			if filepath.Ext(d.Name()) != ".jsonl" {
				return nil
			}
			if strings.Contains(filepath.ToSlash(path), "/subagents/") {
				return nil
			}
			info, err := d.Info()
			if err != nil || info.ModTime().Before(notBefore) {
				return nil
			}
			paths <- path
			return nil
		})
		close(paths)
	}()

	workers := runtime.NumCPU()
	if workers < 2 {
		workers = 2
	}
	if workers > 8 {
		workers = 8
	}
	var mu sync.Mutex
	var out []SessionReport
	var wg sync.WaitGroup
	wg.Add(workers)
	for i := 0; i < workers; i++ {
		go func() {
			defer wg.Done()
			for p := range paths {
				s, err := session.Parse(p)
				if err != nil {
					continue
				}
				r := AnalyzeSession(s, table, th)
				r.Project = projectUnder(root, p)
				mu.Lock()
				out = append(out, r)
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	return out, <-walkErr
}

// projectUnder returns the path segment directly under root (the encoded
// project key). Same logic as safety.projectUnder, duplicated to keep the
// insights package self-contained.
func projectUnder(root, path string) string {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return ""
	}
	rel = filepath.ToSlash(rel)
	if i := strings.IndexByte(rel, '/'); i >= 0 {
		return rel[:i]
	}
	return ""
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/insights/ -run TestScan -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/insights/scan.go tui/internal/insights/scan_test.go
git commit -m "feat(insights): parallel corpus scanner"
```

---

### Task 9: Text renderers (corpus leaderboard + per-session)

**Files:**
- Create: `tui/cmd/claudeinsights/render.go`
- Test: `tui/cmd/claudeinsights/render_test.go`

**Interfaces:**
- Consumes: `insights.CorpusReport`, `insights.SessionReport`, `ui.FormatUSD`, `ui.FormatTokShort`.
- Produces:
  - `func writeCorpus(w io.Writer, c insights.CorpusReport, topN int)`
  - `func writeSession(w io.Writer, r insights.SessionReport)`

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

func TestWriteCorpus(t *testing.T) {
	c := insights.CorpusReport{
		Sessions: []insights.SessionReport{
			{ID: "abc123def", Project: "-tmp-proj", USD: 2, WasteUSD: 1, Score: 4,
				Findings: []insights.Finding{{Category: insights.CatWaste, Detail: "x"}}},
		},
		Projects:      []insights.ProjectAgg{{Project: "-tmp-proj", Sessions: 1, USD: 2, WasteUSD: 1}},
		TotalUSD:      2,
		TotalWasteUSD: 1,
	}
	var b strings.Builder
	writeCorpus(&b, c, 10)
	out := b.String()
	if !strings.Contains(out, "abc123") || !strings.Contains(out, "proj") {
		t.Errorf("missing session/project: %s", out)
	}
}

func TestWriteSession(t *testing.T) {
	r := insights.SessionReport{
		ID: "s1", Cwd: "/tmp/proj", Prompts: 2, ToolCalls: 5, CtxPct: 90,
		Findings: []insights.Finding{
			{Category: insights.CatLoop, Detail: "main stream: cycle [Edit] repeated 3×", Count: 3},
		},
	}
	var b strings.Builder
	writeSession(&b, r)
	out := b.String()
	if !strings.Contains(out, "s1") || !strings.Contains(out, "cycle") {
		t.Errorf("missing content: %s", out)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./cmd/claudeinsights/ -run 'TestWriteCorpus|TestWriteSession' -v`
Expected: FAIL — undefined functions (and package may not compile yet; that's fine, it's the failing state).

- [ ] **Step 3: Write minimal implementation**

```go
package main

import (
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
)

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

func shortProj(encoded string) string {
	if encoded == "" {
		return "(unknown)"
	}
	parts := strings.Split(strings.TrimPrefix(encoded, "-"), "-")
	if len(parts) <= 4 {
		return encoded
	}
	return strings.Join(parts[4:], "-")
}

// writeCorpus renders the ranked leaderboard. Pure (takes io.Writer).
func writeCorpus(w io.Writer, c insights.CorpusReport, topN int) {
	fmt.Fprintf(w, "Corpus  %s spent · %s estimated waste · %d sessions\n",
		ui.FormatUSD(c.TotalUSD), ui.FormatUSD(c.TotalWasteUSD), len(c.Sessions))
	fmt.Fprintln(w, strings.Repeat("─", 72))
	fmt.Fprintf(w, "Worst sessions (top %d):\n", topN)
	fmt.Fprintf(w, "  %-8s %-26s %9s %9s %8s %s\n", "session", "project", "$", "waste$", "findings", "top finding")
	for i, s := range c.Sessions {
		if i >= topN {
			break
		}
		top := ""
		if len(s.Findings) > 0 {
			top = string(s.Findings[0].Category) + ": " + s.Findings[0].Detail
		}
		fmt.Fprintf(w, "  %-8s %-26s %9s %9s %8d %s\n",
			shortID(s.ID), trimRunes(shortProj(s.Project), 26),
			ui.FormatUSD(s.USD), ui.FormatUSD(s.WasteUSD), len(s.Findings), trimRunes(top, 40))
	}
	fmt.Fprintln(w, strings.Repeat("─", 72))
	fmt.Fprintln(w, "By project (most waste first):")
	for _, p := range c.Projects {
		fmt.Fprintf(w, "  %-30s %9s · waste %9s · %d sessions · %d findings\n",
			trimRunes(shortProj(p.Project), 30), ui.FormatUSD(p.USD), ui.FormatUSD(p.WasteUSD), p.Sessions, p.Findings)
	}
}

// writeSession renders one session's drill-down. Pure.
func writeSession(w io.Writer, r insights.SessionReport) {
	fmt.Fprintf(w, "Session %s — %s\n", r.ID, filepath.Base(r.Cwd))
	fmt.Fprintf(w, "  %d prompts · %d tool calls · %s · waste %s · peak ctx %.0f%%\n",
		r.Prompts, r.ToolCalls, ui.FormatUSD(r.USD), ui.FormatUSD(r.WasteUSD), r.CtxPct)
	fmt.Fprintf(w, "  tokens: in %s · out %s · cache-w %s · cache-r %s\n",
		ui.FormatTokShort(r.Tokens.InputTokens), ui.FormatTokShort(r.Tokens.OutputTokens),
		ui.FormatTokShort(r.Tokens.CacheCreationInputTokens), ui.FormatTokShort(r.Tokens.CacheReadInputTokens))
	if len(r.Findings) == 0 {
		fmt.Fprintln(w, "\n  no structural findings 🎉")
		return
	}
	fmt.Fprintln(w, "\nFindings:")
	for _, f := range r.Findings {
		usd := ""
		if f.USD > 0 {
			usd = " (" + ui.FormatUSD(f.USD) + ")"
		}
		fmt.Fprintf(w, "  [%-7s] %s%s\n", f.Category, f.Detail, usd)
	}
}

func trimRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n-1]) + "…"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./cmd/claudeinsights/ -run 'TestWriteCorpus|TestWriteSession' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/cmd/claudeinsights/render.go tui/cmd/claudeinsights/render_test.go
git commit -m "feat(claudeinsights): text renderers for corpus and session"
```

---

### Task 10: JSON and CSV renderers

**Files:**
- Create: `tui/cmd/claudeinsights/export.go`
- Test: `tui/cmd/claudeinsights/export_test.go`

**Interfaces:**
- Consumes: `insights.CorpusReport`.
- Produces:
  - `func writeJSON(w io.Writer, c insights.CorpusReport) error`
  - `func writeCSV(w io.Writer, c insights.CorpusReport) error` — one row per finding: `session,project,usd,waste_usd,category,detail,count,finding_usd`.

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

func sampleCorpus() insights.CorpusReport {
	return insights.CorpusReport{
		Sessions: []insights.SessionReport{
			{ID: "s1", Project: "p", USD: 2, WasteUSD: 1,
				Findings: []insights.Finding{
					{Category: insights.CatWaste, Detail: "failed", Count: 2, USD: 1},
				}},
		},
		TotalUSD: 2, TotalWasteUSD: 1,
	}
}

func TestWriteJSON(t *testing.T) {
	var b strings.Builder
	if err := writeJSON(&b, sampleCorpus()); err != nil {
		t.Fatal(err)
	}
	var back insights.CorpusReport
	if err := json.Unmarshal([]byte(b.String()), &back); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if back.TotalUSD != 2 || len(back.Sessions) != 1 {
		t.Errorf("roundtrip: %+v", back)
	}
}

func TestWriteCSV(t *testing.T) {
	var b strings.Builder
	if err := writeCSV(&b, sampleCorpus()); err != nil {
		t.Fatal(err)
	}
	out := b.String()
	if !strings.Contains(out, "session,project,usd") {
		t.Errorf("missing header: %s", out)
	}
	if !strings.Contains(out, "s1,p,") || !strings.Contains(out, "waste,failed") {
		t.Errorf("missing row: %s", out)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./cmd/claudeinsights/ -run 'TestWriteJSON|TestWriteCSV' -v`
Expected: FAIL — undefined functions.

- [ ] **Step 3: Write minimal implementation**

```go
package main

import (
	"encoding/csv"
	"encoding/json"
	"io"
	"strconv"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
)

func writeJSON(w io.Writer, c insights.CorpusReport) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(c)
}

func writeCSV(w io.Writer, c insights.CorpusReport) error {
	cw := csv.NewWriter(w)
	if err := cw.Write([]string{
		"session", "project", "usd", "waste_usd", "category", "detail", "count", "finding_usd",
	}); err != nil {
		return err
	}
	for _, s := range c.Sessions {
		if len(s.Findings) == 0 {
			if err := cw.Write([]string{
				s.ID, s.Project, f2(s.USD), f2(s.WasteUSD), "", "", "", "",
			}); err != nil {
				return err
			}
			continue
		}
		for _, fi := range s.Findings {
			if err := cw.Write([]string{
				s.ID, s.Project, f2(s.USD), f2(s.WasteUSD),
				string(fi.Category), fi.Detail, strconv.Itoa(fi.Count), f2(fi.USD),
			}); err != nil {
				return err
			}
		}
	}
	cw.Flush()
	return cw.Error()
}

func f2(v float64) string { return strconv.FormatFloat(v, 'f', 4, 64) }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./cmd/claudeinsights/ -run 'TestWriteJSON|TestWriteCSV' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tui/cmd/claudeinsights/export.go tui/cmd/claudeinsights/export_test.go
git commit -m "feat(claudeinsights): JSON and CSV exporters"
```

---

### Task 11: main.go (flags, wiring, dispatch)

**Files:**
- Create: `tui/cmd/claudeinsights/main.go`
- Test: covered by `go build` + a manual smoke run (no unit test for `main`; the pure pieces are already tested).

**Interfaces:**
- Consumes: `insights.Scan`, `insights.AnalyzeSession`, `insights.BuildCorpus`, `insights.DefaultThresholds`, `session.Find`, `session.Parse`, `pricing.Load`/`Defaults`, the renderers/exporters.
- Produces: the `claudeinsights` binary.

> Reuse the existing binary's pricing/root/cutoff conventions. To avoid importing
> `package main` from the other binary, copy the four small helpers verbatim:
> `defaultPricingPath`, `defaultRoot`, `firstOfMonth`, `scanCutoff` (they are
> ~25 lines total and already duplicated-pattern across the codebase).

- [ ] **Step 1: Write main.go**

```go
package main

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/insights"
	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
	"github.com/jverhoeks/claudecounter/tui/internal/session"
)

func defaultPricingPath() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "claudecounter", "pricing.toml")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "claudecounter", "pricing.toml")
}

func defaultRoot() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".claude", "projects")
}

func firstOfMonth(t time.Time) time.Time {
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, t.Location())
}

// scanCutoff: earlier of (start of month) and (now-35d) — same as the counter.
func scanCutoff(now time.Time) time.Time {
	fom := firstOfMonth(now)
	rolling := now.AddDate(0, 0, -35)
	if rolling.Before(fom) {
		return rolling
	}
	return fom
}

func loadPricing(path string) pricing.Table {
	if t, err := pricing.Load(path); err == nil && len(t.Models) > 0 {
		return t
	} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
		log.Printf("pricing: %s unreadable (%v); using defaults", path, err)
	}
	return pricing.Defaults()
}

func main() {
	root := flag.String("root", defaultRoot(), "claude projects root")
	pricingPath := flag.String("pricing", defaultPricingPath(), "path to pricing.toml")
	days := flag.Int("days", 90, "analysis window in days")
	sessionFlag := flag.String("session", "", "drill into one session (id prefix; default: corpus mode)")
	jsonFlag := flag.Bool("json", false, "emit JSON")
	csvFlag := flag.Bool("csv", false, "emit CSV (one row per finding)")
	topN := flag.Int("top", 15, "how many worst sessions to list in corpus mode")
	flag.Parse()

	if _, err := os.Stat(*root); err != nil {
		log.Fatalf("claude projects root not found: %s (%v)", *root, err)
	}
	table := loadPricing(*pricingPath)
	th := insights.DefaultThresholds()

	// Per-session drill-down.
	if *sessionFlag != "" {
		path, err := session.Find(*root, *sessionFlag)
		if err != nil {
			log.Fatalf("session: %v", err)
		}
		s, err := session.Parse(path)
		if err != nil {
			log.Fatalf("parse %s: %v", path, err)
		}
		r := insights.AnalyzeSession(s, table, th)
		r.Project = filepath.Base(filepath.Dir(path))
		if *jsonFlag {
			_ = writeJSON(os.Stdout, insights.CorpusReport{Sessions: []insights.SessionReport{r}})
			return
		}
		writeSession(os.Stdout, r)
		return
	}

	// Corpus mode.
	notBefore := scanCutoff(time.Now().Local())
	if *days > 0 {
		if w := time.Now().Local().AddDate(0, 0, -*days); w.Before(notBefore) {
			notBefore = w
		}
	}
	fmt.Fprintf(os.Stderr, "scanning %s (last %d days) …\n", *root, *days)
	reports, err := insights.Scan(*root, table, th, notBefore)
	if err != nil {
		log.Fatalf("scan: %v", err)
	}
	c := insights.BuildCorpus(reports)
	switch {
	case *jsonFlag:
		_ = writeJSON(os.Stdout, c)
	case *csvFlag:
		_ = writeCSV(os.Stdout, c)
	default:
		writeCorpus(os.Stdout, c, *topN)
	}
}
```

- [ ] **Step 2: Build the binary**

Run: `cd tui && go build ./cmd/claudeinsights/`
Expected: builds with no errors.

- [ ] **Step 3: Run full package tests + vet**

Run: `cd tui && go vet ./... && go test ./...`
Expected: all PASS.

- [ ] **Step 4: Smoke test against the real corpus**

Run: `cd tui && go run ./cmd/claudeinsights/ --days 30 | head -30`
Expected: prints a corpus leaderboard (spent/waste totals, worst sessions, by-project). Then:
Run: `cd tui && go run ./cmd/claudeinsights/ --session "" --json | head -5` is invalid (empty prefix = corpus); instead pick a real id, e.g.
`go run ./cmd/claudeinsights/ --json --days 7 | head -40` and confirm valid JSON.

- [ ] **Step 5: Commit**

```bash
git add tui/cmd/claudeinsights/main.go
git commit -m "feat(claudeinsights): CLI entrypoint with corpus + per-session modes"
```

---

### Task 12: Makefile + README wiring

**Files:**
- Modify: `Makefile`
- Modify: `README.md`

**Interfaces:** none (build/docs only).

- [ ] **Step 1: Add a build target**

Find the existing `build`/binary targets in `Makefile` and add a parallel `claudeinsights` build line following the same pattern (same `GOFLAGS`, output dir). Example addition (adapt to the file's existing style):

```make
build-insights:
	cd tui && go build -o ../claudeinsights ./cmd/claudeinsights
```

If the main `build` target builds `claudecounter`, add `claudeinsights` alongside it so `make build` produces both.

- [ ] **Step 2: Document the tool in README**

Add a short section under the existing CLI docs:

```markdown
### claudeinsights

Analyzes your transcript corpus for usage, token waste, tool abuse, skill
overload, context overload, and loop patterns.

    claudeinsights                 # ranked corpus leaderboard (last 90 days)
    claudeinsights --days 30       # narrower window
    claudeinsights --session 1a2b  # drill into one session
    claudeinsights --json|--csv    # machine-readable output

Tier-2 LLM coaching (corrections, CLAUDE.md candidates, prompt advice) lands in
a later release and uses your local `claude -p` CLI — no API token required.
```

- [ ] **Step 3: Verify build**

Run: `make build` (or `make build-insights`)
Expected: produces the `claudeinsights` binary; `./claudeinsights --days 7 | head` runs.

- [ ] **Step 4: Commit**

```bash
git add Makefile README.md
git commit -m "build,docs: wire up claudeinsights binary"
```

---

## Self-Review

**Spec coverage (Plan 1 = structural Tier-1 only):**
- Usage → Task 6 (`AnalyzeSession` usage fields) + renderers. ✓
- Token waste → Task 3. ✓
- Tool abuse → Task 4. ✓
- Skill overload → Task 4. ✓
- Context overload → Task 1 (window) + Task 6 (CtxPct finding). ✓
- Repetitions/loops (structural) → Task 5 (per-stream). ✓
- Corpus + per-session output, `--days`/`--session`/`--json`/`--csv` → Tasks 7–11. ✓
- **Deferred to Plan 2:** digest + caching. **Deferred to Plan 3:** message-text capture, Tier-2 LLM judge, corrections, CLAUDE.md miner, prompt-specificity coach, cost-without-delivery, model routing. These require `session` text extension and the `Judge` interface — out of scope here by design (kept each plan independently shippable).

**Placeholder scan:** every code step contains complete, compilable Go; commands have expected output. No TBD/TODO. ✓

**Type consistency:** `SessionReport`, `Finding`, `Thresholds`, `CorpusReport`, `ProjectAgg` field names are identical across Tasks 2/6/7/9/10. Helper names (`wasteFindings`, `abuseFindings`, `skillFindings`, `loopFindings`, `AnalyzeSession`, `BuildCorpus`, `Scan`, `ContextWindow`, `trunc`, `trimRunes`, `f2`) are defined once and referenced consistently. ✓

## Follow-on plans (not in this plan)

- **Plan 2 — Caching & digest:** per-session JSON digest (cache entry + LLM input + export); two-level cache (`mtime+size` for Tier-1, `digest hash+promptVersion+model` for LLM); `--no-cache`/`--refresh`.
- **Plan 3 — LLM judge & coaching:** extend `session` to capture filtered user/assistant text (noise filter from the spec); `Judge` interface + `claude -p` impl; corrections, semantic loops, friction score, prompt-specificity coach, per-project CLAUDE.md/memory candidates, cost-without-delivery (reuse `gitstat`/`pr-link`), model routing; `--llm`/`--llm-max`.
