# Grok Usage Ingestion Implementation Plan (Phase B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Grok spend appear in the per-model table, the daily/monthly charts and the hourly chart, alongside Claude, on both surfaces.

**Architecture:** Phase A already shipped the plumbing — `Vendor`/`Source` on the event, `SeriesKey`-keyed totals, and the four grouping modes. Three things are missing and this plan adds them: (1) the aggregator can only *price* a cell from tokens, but Grok reports its own dollars, so a cell becomes either *priced* or *costed*; (2) there is no Grok parser, so `reader` grows a per-vendor parser dispatch; (3) `sources.Defaults()` is Claude-only, so even a working Grok parser would never be pointed at a Grok root — defaults become auto-discovering.

**Tech Stack:** Go 1.x (`tui/`, BurntSushi/toml, fsnotify), Swift 5.9 / SwiftUI (`macapp/`, actor-based aggregator, JSON cache).

**Spec:** `docs/superpowers/specs/2026-08-10-multi-vendor-usage-design.md` — sections *Grok ingestion*, *Authoritative cost*, *Partial-coverage reporting*, *Configurable sources*.

## Global Constraints

- **Nothing here may break Claude cost counting.** Every failure degrades to "fewer cells", never to a wrong Claude number. Every task must leave `make test` green for the existing Claude suites.
- **Both surfaces must agree.** `README.md` promises the TUI and menu bar "produce identical numbers". A change to `tui/internal/agg` lands with its `macapp/Sources/ClaudeCounterCore/Aggregator.swift` mirror in the same plan, and the cross-language parity fixture must cover it.
- **Grok cost is authoritative.** `costUsdTicks / 1e9` is used *as given*. Grok cells never consult the pricing table and a Grok model missing from LiteLLM is **not** an `Unknown`.
- **`costUsdTicks` is nano-dollars.** Divisor is exactly `1e9`. Verified against the live corpus 2026-08-15.
- **Grok token semantics** (verified on live records, 2026-08-15): `totalTokens == inputTokens + outputTokens`, so `cachedReadTokens` is a **subset of** `inputTokens`, and `reasoningTokens` is a **subset of** `outputTokens`. Mapping is therefore `In = inputTokens - cachedReadTokens` (saturating at 0), `CacheRead = cachedReadTokens`, `Out = outputTokens`, `CacheCreate = 0`. Reasoning tokens are never added on top.
- **One cell per key of `modelUsage`**, never the top-level totals on top of it. Top-level totals are used only when `modelUsage` is empty or absent.
- **Dedupe key for a Grok usage record is `prompt_id`.** Because one turn emits one event per model, the existing `MessageID:RequestID` dedupe is reused as `prompt_id` + `model`. Coverage events use `prompt_id` + the sentinel `"coverage"` so they are deduped too.
- **Scan every Grok file, including subagent worktrees.** A parent turn does **not** include its subagents' cost — verified on the live corpus 2026-08-15: parent session `01a005ba` reports $0.901 across 2 model calls for a turn completing 21s after a subagent turn of $1.081 across 16 calls, which an inclusive parent could not do. This supersedes the spec's stale probe (it found 1 usage event across 8 subagent files; there are now many).
- **Dedupe is load-bearing, not defensive.** 187 of 188 distinct `prompt_id`s in the local corpus appear exactly once; the one exception ($1.656) is written into **two session directories** under the same worktree. Without dedupe that turn is billed twice.
- **A zero cost is a coverage problem, not a free turn.** 3 of 189 live usage records carry real tokens with `costUsdTicks: 0`. They are recorded with their tokens and zero cost, and they do **not** count toward the covered numerator.
- Comment density, naming and file layout follow the surrounding code. Both codebases carry long "why" comments on non-obvious decisions; match that.

---

## File Structure

**Go (`tui/`)**

| File | Change | Responsibility |
|---|---|---|
| `internal/reader/reader.go` | Modify | `Event` gains `CostUSD`, `Costed`, `CoverageOnly`, `HasUsage`. `OnChange`/`InitialScan` dispatch to a per-vendor parser. |
| `internal/reader/vendor.go` | Create | The `vendorParser` interface and the Claude implementation extracted from today's inline logic. |
| `internal/reader/grok.go` | Create | The Grok parser: `turn_completed` records, `modelUsage` fan-out, coverage signal, project key from the percent-encoded session dir. |
| `internal/agg/agg.go` | Modify | Cells store `(tokens, costedUSD, pricedTokens)`. `Snapshot` sums costed dollars and prices the rest. Coverage counters + `Totals.Coverage`. |
| `internal/sources/sources.go` | Modify | `Defaults()` auto-discovers `~/.grok/sessions`; `knownVendors` unchanged (already has `grok`). |
| `cmd/claudecounter/main.go` | Modify | `requireDefaultRoots` only fatal for the Claude default. |
| `internal/ui/group_view.go` | Modify | Partial-coverage marker on a vendor's row. |

**Swift (`macapp/`)**

| File | Change | Responsibility |
|---|---|---|
| `Sources/ClaudeCounterCore/Reader.swift` | Modify | `UsageEvent` mirrors the four new Go fields; per-vendor parse dispatch. |
| `Sources/ClaudeCounterCore/GrokReader.swift` | Create | Swift mirror of `internal/reader/grok.go`. |
| `Sources/ClaudeCounterCore/Aggregator.swift` | Modify | `CellValue` replaces bare `TokenCounts`; costed/priced split in `snapshot()`; coverage counters. |
| `Sources/ClaudeCounterCore/Cache.swift` | Modify | Cache **v5**: `CellEntry` gains `usd`/`costed`, `HourEntry` gains `usd`/`costed`, plus a `coverage` array. |
| `Sources/ClaudeCounterCore/Sources.swift` | Modify | `defaults(home:)` auto-discovers, mirroring Go. |
| `Sources/ClaudeCounterBar/PopoverView.swift` | Modify | Partial-coverage marker. |

---

## Task 1: Costed cells in the Go aggregator

The aggregator can only derive USD from tokens. Grok supplies USD directly. This
task makes a cell carry both possibilities and makes `Snapshot` sum them
correctly, **before** any Grok data exists — so it is provable against Claude
data alone and cannot regress a Claude number.

The accumulator deliberately keeps `costedUSD` and `pricedTokens` as *separate*
fields rather than branching on "is this series costed". Mixing never happens in
practice (costedness is vendor-determined and vendor is part of `SeriesKey`), but
the per-project and per-day aggregations key on `Model` alone, where a collision
between a costed and a priced model would silently zero one of them. Summing both
sides is correct unconditionally and needs no homogeneity assumption.

**Files:**
- Modify: `tui/internal/reader/reader.go:18-36` (the `Event` struct)
- Modify: `tui/internal/agg/agg.go:100-118` (`Aggregator` fields), `:157-179` (`Apply`), `:196-330` (`Snapshot`), `:340-400` (`ProjectDaily`)
- Test: `tui/internal/agg/agg_test.go`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `reader.Event.CostUSD float64`, `reader.Event.Costed bool`
  - `agg.cellVal{Tokens TokenCounts; CostedUSD float64; PricedTokens TokenCounts}` (unexported)
  - `agg.Aggregator.cells map[cellKey]cellVal`
  - Unchanged public surface: `Snapshot() Totals`, `Apply(reader.Event)`, `ProjectDaily() []ProjDayCost`

- [ ] **Step 1: Write the failing test**

Add to `tui/internal/agg/agg_test.go`:

```go
// A costed event's dollars are used as given and never touched by the
// pricing table — a Grok model has no LiteLLM entry, so a pricing path
// would silently zero it.
func TestApply_CostedEventIgnoresPricingTable(t *testing.T) {
	table := pricing.Table{Models: map[string]pricing.ModelPrice{
		// Deliberately price the same model name absurdly: if Snapshot
		// ever consults the table for a costed cell, the assertion below
		// fails loudly instead of drifting by cents.
		"grok-4.6-build": {InputPerMTok: 1000, OutputPerMTok: 1000},
	}}
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.Local)
	a := agg.NewWithClock(table, func() time.Time { return now })

	a.Apply(reader.Event{
		Timestamp: now,
		Project:   "-Users-me-proj",
		Vendor:    "grok",
		Source:    "grok/grok",
		Model:     "grok-4.6-build",
		MessageID: "prompt-1",
		RequestID: "grok-4.6-build",
		Usage:     pricing.Usage{InputTokens: 1_000_000, OutputTokens: 1_000_000},
		CostUSD:   0.37,
		Costed:    true,
	})

	got := a.Snapshot()
	key := agg.SeriesKey{Source: "grok/grok", Vendor: "grok", Model: "grok-4.6-build"}
	if math.Abs(got.Month[key].USD-0.37) > 1e-9 {
		t.Fatalf("month USD = %v, want 0.37 (vendor-reported, not priced)", got.Month[key].USD)
	}
	if math.Abs(got.Day[key].USD-0.37) > 1e-9 {
		t.Fatalf("day USD = %v, want 0.37", got.Day[key].USD)
	}
	if math.Abs(got.Daily[len(got.Daily)-1].USD-0.37) > 1e-9 {
		t.Fatalf("today's daily USD = %v, want 0.37", got.Daily[len(got.Daily)-1].USD)
	}
	if got.MonthProj["-Users-me-proj"].USD() != 0.37 {
		t.Fatalf("project USD = %v, want 0.37", got.MonthProj["-Users-me-proj"].USD())
	}
	// A costed model is never "unknown" — there is nothing to look up.
	if got.Unknown != 0 {
		t.Fatalf("Unknown = %d, want 0 for a costed cell", got.Unknown)
	}
}

// Priced and costed cells sum together in one snapshot without either
// path swallowing the other.
func TestSnapshot_PricedAndCostedCellsSum(t *testing.T) {
	table := pricing.Table{Models: map[string]pricing.ModelPrice{
		"claude-opus-4-7": {InputPerMTok: 15, OutputPerMTok: 75},
	}}
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.Local)
	a := agg.NewWithClock(table, func() time.Time { return now })

	a.Apply(reader.Event{
		Timestamp: now, Project: "p", Vendor: "claude", Source: "claude/claude",
		Model: "claude-opus-4-7", MessageID: "m1", RequestID: "r1",
		Usage: pricing.Usage{InputTokens: 1_000_000}, // $15.00
	})
	a.Apply(reader.Event{
		Timestamp: now, Project: "p", Vendor: "grok", Source: "grok/grok",
		Model: "grok-4.6-build", MessageID: "prompt-1", RequestID: "grok-4.6-build",
		Usage: pricing.Usage{InputTokens: 500}, CostUSD: 2.5, Costed: true,
	})

	got := a.Snapshot()
	total := 0.0
	for _, md := range got.Month {
		total += md.USD
	}
	if math.Abs(total-17.5) > 1e-9 {
		t.Fatalf("month total = %v, want 17.5 (15.00 priced + 2.50 costed)", total)
	}
	if math.Abs(got.MonthProj["p"].USD()-17.5) > 1e-9 {
		t.Fatalf("project total = %v, want 17.5", got.MonthProj["p"].USD())
	}
	if math.Abs(got.Daily[len(got.Daily)-1].USD-17.5) > 1e-9 {
		t.Fatalf("daily total = %v, want 17.5", got.Daily[len(got.Daily)-1].USD)
	}
}
```

Add `"math"` to the test file's imports if it is not already there.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/agg/ -run 'Costed|PricedAndCosted' -v`
Expected: FAIL — `unknown field CostUSD in struct literal of type reader.Event`.

- [ ] **Step 3: Add the two fields to `reader.Event`**

In `tui/internal/reader/reader.go`, inside the `Event` struct, after `Source`:

```go
	// CostUSD is a dollar figure the vendor reported for this event.
	// Grok emits costUsdTicks (nano-dollars) per turn and per model; that
	// is authoritative in a way our pricing table can never be, so it is
	// used as given rather than re-derived from Usage.
	CostUSD float64
	// Costed marks CostUSD as authoritative. A costed event's tokens are
	// still recorded (the token charts want them) but never priced, and
	// its model never counts toward the Unknown tally — there is no
	// pricing entry to be missing.
	Costed bool
```

- [ ] **Step 4: Change the cell value type in `agg`**

In `tui/internal/agg/agg.go`, immediately after the `cellKey` declaration, add:

```go
// cellVal is one cell's accumulated contribution. Tokens is everything
// the cell saw and drives the token charts. The dollar side is split in
// two because a cell may hold both kinds of contribution: CostedUSD is
// summed as-is from vendor-reported figures, PricedTokens is the subset
// that must go through the pricing table at snapshot time.
//
// Keeping them separate rather than branching on "is this series costed"
// matters for the per-project and per-day aggregations, which key on
// Model alone — there, a costed and a priced contribution can land in
// one bucket, and summing both sides is correct without assuming they
// never mix.
type cellVal struct {
	Tokens       TokenCounts
	CostedUSD    float64
	PricedTokens TokenCounts
}

func (a cellVal) Add(b cellVal) cellVal {
	return cellVal{
		Tokens:       a.Tokens.Add(b.Tokens),
		CostedUSD:    a.CostedUSD + b.CostedUSD,
		PricedTokens: a.PricedTokens.Add(b.PricedTokens),
	}
}
```

Change the field declaration on `Aggregator` from:

```go
	cells       map[cellKey]TokenCounts
```

to:

```go
	cells       map[cellKey]cellVal
```

and in `NewWithClock`, `cells: map[cellKey]TokenCounts{}` becomes `cells: map[cellKey]cellVal{}`.

- [ ] **Step 5: Update `Apply`**

Replace the unknown-tracking block and the cell write in `Apply` with:

```go
	// A costed event has no pricing lookup to miss, so it can never be
	// "unknown". Only priced events feed the diagnostic.
	if !e.Costed && !a.pricing.Has(e.Model) {
		uid := e.MessageID
		if uid == "" {
			uid = e.Model + ":" + e.Timestamp.String()
		}
		a.unknownMsgs[uid] = struct{}{}
	}

	k := cellKey{
		Day:     dayOf(e.Timestamp),
		Project: e.Project,
		Source:  e.Source,
		Vendor:  e.Vendor,
		Model:   e.Model,
		IsSub:   e.IsSubagent,
	}
	if e.Cwd != "" {
		if _, ok := a.projectCwd[e.Project]; !ok {
			a.projectCwd[e.Project] = e.Cwd
		}
	}
	tok := TokenCounts{
		In:          e.Usage.InputTokens,
		Out:         e.Usage.OutputTokens,
		CacheCreate: e.Usage.CacheCreationInputTokens,
		CacheRead:   e.Usage.CacheReadInputTokens,
	}
	contrib := cellVal{Tokens: tok}
	if e.Costed {
		contrib.CostedUSD = e.CostUSD
	} else {
		contrib.PricedTokens = tok
	}
	a.cells[k] = a.cells[k].Add(contrib)
```

- [ ] **Step 6: Update `Snapshot`**

In `Snapshot`, change the three accumulator maps from `TokenCounts` to `cellVal`
and price only `PricedTokens`.

Replace `modelTok := map[modelKey]TokenCounts{}` with `modelTok := map[modelKey]cellVal{}`,
`projTok := map[projKey]TokenCounts{}` with `projTok := map[projKey]cellVal{}`, and
in the first `for k, t := range a.cells` loop leave the `.Add(t)` calls as they
are — `cellVal.Add` now has the same shape as `TokenCounts.Add`.

Replace the per-series pricing loop with:

```go
	for mk, v := range modelTok {
		usd := v.CostedUSD
		if a.pricing.Has(mk.Key.Model) {
			usd += a.pricing.Cost(mk.Key.Model, v.PricedTokens.ToUsage())
		}
		md := ModelDay{USD: usd, Tokens: v.Tokens}
		switch mk.Scope {
		case "day":
			out.Day[mk.Key] = md
		case "month":
			out.Month[mk.Key] = md
		}
	}
```

Replace `pmTok := map[pmk]TokenCounts{}` with `pmTok := map[pmk]cellVal{}` (the
loop body is unchanged), and the per-project pricing loop with:

```go
	for k, v := range pmTok {
		usd := v.CostedUSD
		if a.pricing.Has(k.Model) {
			usd += a.pricing.Cost(k.Model, v.PricedTokens.ToUsage())
		}
		var bucket map[string]ProjectDay
		switch k.Scope {
		case "day":
			bucket = out.DayProj
		case "month":
			bucket = out.MonthProj
		}
		pd := bucket[k.Project]
		if k.IsSub {
			pd.Sub = pd.Sub.Add(v.Tokens)
			pd.SubUSD += usd
		} else {
			pd.Main = pd.Main.Add(v.Tokens)
			pd.MainUSD += usd
		}
		bucket[k.Project] = pd
	}
```

Replace `byDM := map[dmKey]TokenCounts{}` with `byDM := map[dmKey]cellVal{}` (loop
body unchanged) and the daily cost loop with:

```go
	// Cost counts vendor-reported dollars plus priced models, so the
	// dollar sparkline matches the rest of the UI; tokens count ALL
	// models so the token chart reflects raw activity even when an
	// unpriced model is in use.
	dayCost := map[civilDay]float64{}
	dayTokens := map[civilDay]uint64{}
	for k, v := range byDM {
		dayCost[k.Day] += v.CostedUSD
		if a.pricing.Has(k.Model) {
			dayCost[k.Day] += a.pricing.Cost(k.Model, v.PricedTokens.ToUsage())
		}
		t := v.Tokens
		dayTokens[k.Day] += t.In + t.Out + t.CacheCreate + t.CacheRead
	}
```

- [ ] **Step 7: Update `ProjectDaily`**

Replace `byPDM := map[pdmKey]TokenCounts{}` with `byPDM := map[pdmKey]cellVal{}`
(the fill loop body is unchanged), and the pricing loop with:

```go
	m := map[key]*acc{}
	for pk, v := range byPDM {
		kk := key{pk.proj, pk.day}
		e := m[kk]
		if e == nil {
			e = &acc{}
			m[kk] = e
		}
		e.usd += v.CostedUSD
		if a.pricing.Has(pk.model) {
			e.usd += a.pricing.Cost(pk.model, v.PricedTokens.ToUsage())
		}
		e.tok = e.tok.Add(v.Tokens)
	}
```

- [ ] **Step 8: Run the tests**

Run: `cd tui && go test ./internal/agg/ -v`
Expected: PASS, including every pre-existing Claude test.

Run: `cd tui && go test ./...`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add tui/internal/agg/agg.go tui/internal/agg/agg_test.go tui/internal/reader/reader.go
git commit -m "feat(agg): a cell is either priced or costed

Grok reports its own dollars. Snapshot now sums vendor-reported USD
alongside table-priced tokens instead of deriving every cell from the
pricing table. No Grok data exists yet; this is provable against Claude
cells alone."
```

---

## Task 2: Auto-discovering source defaults (Go)

Without this, a perfect Grok parser is never pointed at a Grok root: the user has
no `sources.toml`, so `Load` returns `Defaults(home)`, which is Claude-only. The
`planlimits` package already finds `~/.grok` with zero configuration; this brings
the source list to the same standard.

The care point is `requireDefaultRoots` (`cmd/claudecounter/main.go:182`): it makes
a **missing default root fatal**, deliberately, so a first-run user never sees a
confident silent `$0.00`. That contract is about Claude. An absent `~/.grok` is the
ordinary state for most users and must not exit the process.

**Files:**
- Modify: `tui/internal/sources/sources.go:68-77` (`Defaults`)
- Modify: `tui/cmd/claudecounter/main.go:182-187` (`requireDefaultRoots`)
- Test: `tui/internal/sources/sources_test.go`, `tui/cmd/claudecounter/root_reachability_test.go`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `sources.Defaults(home string) []Source` — now returns 1 or 2 entries; the Claude entry is **always first**, and callers that need the "must exist" root rely on that ordering via `Source.Vendor == "claude"`.

- [ ] **Step 1: Write the failing test**

Add to `tui/internal/sources/sources_test.go`:

```go
// A Grok install is picked up without any configuration, matching how
// planlimits already discovers ~/.grok with zero config. The Claude
// entry stays first so callers can rely on the ordering.
func TestDefaults_DiscoversGrokWhenPresent(t *testing.T) {
	home := t.TempDir()
	mustMkdirAll(t, filepath.Join(home, ".claude", "projects"))
	mustMkdirAll(t, filepath.Join(home, ".grok", "sessions"))

	got := sources.Defaults(home)
	if len(got) != 2 {
		t.Fatalf("got %d sources, want 2: %+v", len(got), got)
	}
	if got[0].Vendor != "claude" {
		t.Fatalf("got[0].Vendor = %q, want claude first", got[0].Vendor)
	}
	want := sources.Source{
		Vendor: "grok", Label: "grok",
		Root: filepath.Join(home, ".grok", "sessions"),
	}
	if got[1] != want {
		t.Fatalf("got[1] = %+v, want %+v", got[1], want)
	}
}

// No ~/.grok means no Grok source and, critically, no change whatsoever
// for the existing Claude-only user.
func TestDefaults_OmitsGrokWhenAbsent(t *testing.T) {
	home := t.TempDir()
	mustMkdirAll(t, filepath.Join(home, ".claude", "projects"))

	got := sources.Defaults(home)
	if len(got) != 1 || got[0].Vendor != "claude" {
		t.Fatalf("got %+v, want exactly the Claude default", got)
	}
}

// The Claude default root is still required to exist — that contract
// predates sources.toml and guards against a confident silent $0.00.
// An auto-discovered vendor is not: it is only ever added when its
// directory exists, and a race that removes it must not kill the process.
func TestDefaults_ClaudeRootStillRequiredButGrokIsNot(t *testing.T) {
	home := t.TempDir()
	// No .claude at all.
	mustMkdirAll(t, filepath.Join(home, ".grok", "sessions"))
	got := sources.Defaults(home)
	if len(got) != 2 || got[0].Vendor != "claude" {
		t.Fatalf("got %+v, want the Claude default present even when absent on disk", got)
	}
}

// A discovered root nested inside the Claude root is dropped. Load()
// rejects that arrangement outright; a list we assemble ourselves must
// not be able to produce it, or every event in the overlap counts twice.
// Reachable via a CLAUDE_CONFIG_DIR pointing under ~/.grok.
func TestDefaults_DropsAnOverlappingDiscoveredRoot(t *testing.T) {
	home := t.TempDir()
	// Make the Claude root an ancestor of where Grok would be found.
	claudeRoot := filepath.Join(home, ".claude", "projects")
	mustMkdirAll(t, claudeRoot)
	mustMkdirAll(t, filepath.Join(home, ".grok", "sessions"))

	got := sources.DefaultsWithClaudeRoot(home, home)
	if len(got) != 1 || got[0].Vendor != "claude" {
		t.Fatalf("got %+v, want only the Claude entry when the discovered root nests inside it", got)
	}
}

func mustMkdirAll(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(p, 0o755); err != nil {
		t.Fatal(err)
	}
}
```

If `mustMkdirAll` already exists in the file, drop the duplicate definition.

`DefaultsWithClaudeRoot(home, claudeRoot string)` is a small test seam:
`Defaults(home)` becomes
`DefaultsWithClaudeRoot(home, filepath.Join(home, ".claude", "projects"))` and
the seam takes the Claude root as a parameter. Without it the overlap branch is
unreachable from a test, since the two real default paths are siblings. Export
it — nothing in `cmd/` needs it, but a plainly-named seam beats an unexercised
branch that only fires on a machine nobody tests on.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/sources/ -run Defaults -v`
Expected: FAIL — `got 1 sources, want 2`.

- [ ] **Step 3: Implement auto-discovery**

Replace `Defaults` in `tui/internal/sources/sources.go`:

```go
// Defaults is the implicit source list used when no config file exists.
//
// The Claude entry is unconditional and always first: it is the original
// hardcoded behaviour, and callers (requireDefaultRoots) still treat a
// missing Claude root as fatal so a first-run user never gets a
// confident silent $0.00.
//
// Other vendors are auto-discovered — added only when their root
// actually exists on this machine. That mirrors how planlimits already
// finds ~/.grok with zero configuration, and it keeps the promise that a
// user who never opts in sees no change: no ~/.grok, no Grok source, no
// difference. Because such an entry is only ever added when the
// directory is there, it is never subject to the must-exist rule.
//
// A discovered root that overlaps one already in the list is dropped
// rather than returned. Load() rejects nested roots outright because a
// user wrote them; this list is assembled by us, so the same hazard —
// every event in the overlap counted twice — is silently avoided instead
// of turned into an error the user cannot act on. It is reachable: a
// CLAUDE_CONFIG_DIR pointing under ~/.grok, or the reverse, nests the
// two.
func Defaults(home string) []Source {
	return DefaultsWithClaudeRoot(home, filepath.Join(home, ".claude", "projects"))
}

// DefaultsWithClaudeRoot is Defaults with the Claude root injected. It
// exists so the overlap branch below is reachable from a test: the two
// real default paths are siblings, so nothing else can exercise it.
func DefaultsWithClaudeRoot(home, claudeRoot string) []Source {
	out := []Source{{
		Vendor: "claude",
		Label:  "claude",
		Root:   claudeRoot,
	}}
	for _, d := range discoverable {
		root := filepath.Join(home, filepath.Join(d.segments...))
		fi, err := os.Stat(root)
		if err != nil || !fi.IsDir() {
			continue
		}
		cand := Source{Vendor: d.vendor, Label: d.vendor, Root: root}
		if checkOverlap(append(append([]Source{}, out...), cand)) != nil {
			continue
		}
		out = append(out, cand)
	}
	return out
}

// discoverable lists the non-Claude vendors Defaults probes for, in the
// order they are appended. Adding a vendor here is all it takes for a
// zero-config install to be counted, provided a reader exists for it.
var discoverable = []struct {
	vendor   string
	segments []string
}{
	{vendor: "grok", segments: []string{".grok", "sessions"}},
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && go test ./internal/sources/ -v`
Expected: PASS.

- [ ] **Step 5: Write the failing test for the fatality rule**

Add to `tui/cmd/claudecounter/root_reachability_test.go`:

```go
// requireDefaultRoots guards the Claude default only. An auto-discovered
// vendor root is added by Defaults only when it exists, so treating its
// disappearance as fatal would kill the process over a directory the
// user never configured.
func TestRequireDefaultRoots_OnlyClaudeIsFatal(t *testing.T) {
	srcs := []sources.Source{
		{Vendor: "claude", Label: "claude", Root: t.TempDir()},
		{Vendor: "grok", Label: "grok", Root: filepath.Join(t.TempDir(), "gone")},
	}
	// Must not call log.Fatalf. If it does, the test binary exits and
	// this line is never reached.
	requireDefaultRoots(srcs)
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd tui && go test ./cmd/claudecounter/ -run OnlyClaudeIsFatal -v`
Expected: FAIL — the process exits with `claude projects root not found`.

- [ ] **Step 7: Scope the fatality to Claude**

In `tui/cmd/claudecounter/main.go`, replace the body of `requireDefaultRoots`:

```go
func requireDefaultRoots(srcs []sources.Source) {
	for _, s := range srcs {
		// Only the Claude default is unconditional. Every other entry in
		// the implicit list was auto-discovered — Defaults added it only
		// because its directory existed — so a stat failure here means a
		// race or an unmount, not a misconfiguration, and must not take
		// the process down.
		if s.Vendor != "claude" {
			continue
		}
		requireRoot(s.Root)
	}
}
```

Extend the doc comment above it with a sentence noting the Claude-only scope.

- [ ] **Step 8: Run the tests**

Run: `cd tui && go test ./cmd/claudecounter/ ./internal/sources/ -v`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add tui/internal/sources/sources.go tui/internal/sources/sources_test.go \
        tui/cmd/claudecounter/main.go tui/cmd/claudecounter/root_reachability_test.go
git commit -m "feat(sources): auto-discover a Grok install in the default list

planlimits already finds ~/.grok with zero config; the source list now
does too. The Claude default stays unconditional and stays fatal when
missing — an auto-discovered root is only ever added when it exists, so
it is not subject to that rule."
```

---

## Task 3: The Grok parser

A per-vendor parser dispatch, plus the Grok implementation. Extracting the Claude
logic behind an interface first keeps the two vendors' quirks (which files to
walk, how to derive a project key, how many events a line yields) in one place
each rather than as a growing chain of `if vendor == …` inside `OnChange`.

**Files:**
- Create: `tui/internal/reader/vendor.go`
- Create: `tui/internal/reader/grok.go`
- Create: `tui/internal/reader/testdata/grok_updates.jsonl`
- Test: `tui/internal/reader/grok_test.go`

**Interfaces:**
- Consumes: `reader.Event` with `CostUSD`/`Costed` from Task 1.
- Produces:
  - `reader.Event.CoverageOnly bool`, `reader.Event.HasUsage bool`
  - `type vendorParser interface { Walkable(name string) bool; Parse(line []byte, slashPath string) ([]Event, error); Project(slashPath string) string; IsSubagent(slashPath string) bool }`
  - `func parserFor(vendor string) vendorParser`
  - `claudeParser{}`, `grokParser{}`
  - `func grokProjectKey(slashPath string) string`

- [ ] **Step 1: Create the fixture**

Create `tui/internal/reader/testdata/grok_updates.jsonl` with exactly these six
lines (each on one line — wrapped here for readability only):

```
{"timestamp":1786806973,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","prompt_id":"p1","stop_reason":"end_turn","usage":{"inputTokens":210887,"outputTokens":5833,"totalTokens":216720,"cachedReadTokens":158592,"reasoningTokens":2916,"modelCalls":9,"costUsdTicks":372102800,"modelUsage":{"grok-4.6-build":{"inputTokens":210887,"outputTokens":5833,"totalTokens":216720,"cachedReadTokens":158592,"reasoningTokens":2916,"costUsdTicks":372102800}},"numTurns":9}}}}
{"timestamp":1786806999,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","prompt_id":"p2","stop_reason":"end_turn"}}}
{"timestamp":1786807100,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","prompt_id":"p3","usage":{"inputTokens":300,"outputTokens":100,"totalTokens":400,"cachedReadTokens":100,"costUsdTicks":3000000000,"modelUsage":{"grok-4.6-build":{"inputTokens":200,"outputTokens":60,"cachedReadTokens":60,"costUsdTicks":2000000000},"grok-4.6-fast":{"inputTokens":100,"outputTokens":40,"cachedReadTokens":40,"costUsdTicks":1000000000}}}}}}
{"timestamp":1786807200,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"inputTokens":210887,"outputTokens":5833,"cachedReadTokens":158592,"costUsdTicks":372102800,"modelUsage":{"grok-4.6-build":{"inputTokens":210887,"outputTokens":5833,"cachedReadTokens":158592,"costUsdTicks":372102800}}}}}}
{"timestamp":1786807300,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","text":"hello"}}}
{"timestamp":1786807400,"method":"_x.ai/session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"turn_completed","prompt_id":"p4","usage":{"inputTokens":500,"outputTokens":50,"cachedReadTokens":100,"costUsdTicks":0,"modelUsage":{"grok-4.6-build":{"inputTokens":500,"outputTokens":50,"cachedReadTokens":100,"costUsdTicks":0}}}}}}
{not json
```

Line 1 is a normal single-model turn. Line 2 is a `turn_completed` with **no**
usage (coverage denominator only). Line 3 is a multi-model turn. Line 4 repeats
`prompt_id` `p1` (duplicate). Line 5 is a non-`turn_completed` update. Line 6 is
a turn with real tokens but `costUsdTicks: 0` — 3 of the 189 usage records in the
live corpus look like this, and per the spec such a record is kept with zero cost
rather than dropped, while **not** counting as covered. Line 7 is malformed.

On line 4: the duplicate is not hypothetical. Across the whole local corpus 187
of 188 distinct `prompt_id`s appear exactly once, and the one exception
(`01a00604-fd0c-…`, $1.656) appears in **two different session directories**
under the same worktree. Without `prompt_id` dedupe that turn is billed twice.
The fixture keeps the duplicate in one file for parser-level testing; Task 4 adds
the cross-directory case, which is the shape that actually occurs.

- [ ] **Step 2: Write the failing test**

Create `tui/internal/reader/grok_test.go`:

```go
package reader

import (
	"bufio"
	"math"
	"os"
	"testing"
)

const grokPath = "/Users/me/.grok/sessions/%2FUsers%2Fme%2Fsrc%2Fproj/01a0-sess/updates.jsonl"

func parseGrokFixture(t *testing.T) (events []Event, parseErrs int) {
	t.Helper()
	f, err := os.Open("testdata/grok_updates.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	p := grokParser{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		evs, err := p.Parse(sc.Bytes(), grokPath)
		if err != nil {
			parseErrs++
			continue
		}
		events = append(events, evs...)
	}
	return events, parseErrs
}

func TestGrokParser_EmitsOneEventPerModelPlusOneCoverageEvent(t *testing.T) {
	events, parseErrs := parseGrokFixture(t)
	if parseErrs != 1 {
		t.Fatalf("parse errors = %d, want 1 (the malformed line)", parseErrs)
	}

	var usage, coverage []Event
	for _, e := range events {
		if e.CoverageOnly {
			coverage = append(coverage, e)
		} else {
			usage = append(usage, e)
		}
	}
	// 5 turn_completed records (p1, p2, p3, p1-dup, p4) each yield
	// exactly one coverage event; the non-turn_completed and malformed
	// lines yield none.
	if len(coverage) != 5 {
		t.Fatalf("coverage events = %d, want 5", len(coverage))
	}
	withUsage := 0
	for _, e := range coverage {
		if e.HasUsage {
			withUsage++
		}
		// Every coverage event must be dedupe-addressable, or a re-scan
		// silently inflates the tally.
		if e.MessageID == "" || e.RequestID != "coverage" {
			t.Fatalf("coverage event has dedupe key %q:%q, want <prompt_id>:coverage",
				e.MessageID, e.RequestID)
		}
	}
	// p1, p3 and p1-dup carry a usable cost. p2 has no usage at all and
	// p4's costUsdTicks is 0 — neither counts as covered.
	if withUsage != 3 {
		t.Fatalf("coverage events with usable cost = %d, want 3", withUsage)
	}
	// p1 -> 1 model, p3 -> 2 models, p1-dup -> 1 model, p4 -> 1 model.
	// Dedupe is the aggregator's job (MessageID:RequestID), not the
	// parser's.
	if len(usage) != 5 {
		t.Fatalf("usage events = %d, want 5", len(usage))
	}
}

// A record whose cost is zero but whose tokens are real is kept, not
// dropped: a missing cost is a coverage problem, not a free turn.
func TestGrokParser_ZeroCostRecordIsKeptWithItsTokens(t *testing.T) {
	events, _ := parseGrokFixture(t)
	var found bool
	for _, e := range events {
		if e.CoverageOnly || e.MessageID != "p4" {
			continue
		}
		found = true
		if e.CostUSD != 0 {
			t.Fatalf("CostUSD = %v, want 0", e.CostUSD)
		}
		if !e.Costed {
			t.Fatal("Costed = false; a zero-cost Grok cell is still costed, not priced")
		}
		if e.Usage.OutputTokens != 50 {
			t.Fatalf("output = %d, want 50 — the tokens must survive", e.Usage.OutputTokens)
		}
	}
	if !found {
		t.Fatal("the zero-cost record produced no usage event")
	}
}

func TestGrokParser_TokenAndCostMapping(t *testing.T) {
	events, _ := parseGrokFixture(t)
	var first Event
	for _, e := range events {
		if !e.CoverageOnly && e.MessageID == "p1" {
			first = e
			break
		}
	}
	if first.Model != "grok-4.6-build" {
		t.Fatalf("model = %q, want grok-4.6-build", first.Model)
	}
	// inputTokens INCLUDES cachedReadTokens (totalTokens == input+output
	// on the live records), so the uncached input is the difference.
	if first.Usage.InputTokens != 210887-158592 {
		t.Fatalf("input = %d, want %d", first.Usage.InputTokens, 210887-158592)
	}
	if first.Usage.CacheReadInputTokens != 158592 {
		t.Fatalf("cacheRead = %d, want 158592", first.Usage.CacheReadInputTokens)
	}
	// reasoningTokens is a subset of outputTokens and must NOT be added.
	if first.Usage.OutputTokens != 5833 {
		t.Fatalf("output = %d, want 5833", first.Usage.OutputTokens)
	}
	if first.Usage.CacheCreationInputTokens != 0 {
		t.Fatalf("cacheCreate = %d, want 0 (Grok reports none)", first.Usage.CacheCreationInputTokens)
	}
	if !first.Costed {
		t.Fatal("Costed = false, want true")
	}
	// costUsdTicks are nano-dollars.
	if math.Abs(first.CostUSD-0.3721028) > 1e-9 {
		t.Fatalf("CostUSD = %v, want 0.3721028", first.CostUSD)
	}
	// The dedupe key is prompt_id + model, so a multi-model turn keeps
	// both of its cells.
	if first.RequestID != "grok-4.6-build" {
		t.Fatalf("RequestID = %q, want the model name", first.RequestID)
	}
}

func TestGrokParser_TopLevelTotalsNeverAddedOnTopOfModelUsage(t *testing.T) {
	events, _ := parseGrokFixture(t)
	total := 0.0
	for _, e := range events {
		if e.CoverageOnly || e.MessageID != "p3" {
			continue
		}
		total += e.CostUSD
	}
	// p3's top-level costUsdTicks is 3e9 ($3.00) and its two models sum
	// to exactly that. Emitting both would report $6.00.
	if math.Abs(total-3.0) > 1e-9 {
		t.Fatalf("p3 total = %v, want 3.00 (modelUsage only)", total)
	}
}

func TestGrokProjectKey_MatchesClaudeEncoding(t *testing.T) {
	// The session directory is the percent-encoded cwd. Decoding it and
	// re-encoding the Claude way keeps one project one row in the
	// per-project table regardless of which vendor produced the spend.
	got := grokProjectKey(grokPath)
	if got != "-Users-me-src-proj" {
		t.Fatalf("project = %q, want -Users-me-src-proj", got)
	}
	// A dot in the path becomes a dash, exactly as Claude encodes it
	// (~/.claude -> -Users-me--claude).
	dotted := "/Users/me/.grok/sessions/%2FUsers%2Fme%2F.config%2Fx/sess/updates.jsonl"
	if got := grokProjectKey(dotted); got != "-Users-me--config-x" {
		t.Fatalf("project = %q, want -Users-me--config-x", got)
	}
}

func TestGrokParser_WalkableOnlyMatchesUpdatesJSONL(t *testing.T) {
	p := grokParser{}
	if !p.Walkable("updates.jsonl") {
		t.Fatal("updates.jsonl must be walkable")
	}
	// _meta.totalTokens lives in other files and is cumulative context,
	// not usage. Reading them would be a large silent overcount.
	for _, name := range []string{"messages.jsonl", "meta.jsonl", "notes.txt"} {
		if p.Walkable(name) {
			t.Fatalf("%s must not be walkable", name)
		}
	}
}

func TestGrokParser_IsSubagent(t *testing.T) {
	p := grokParser{}
	sub := "/Users/me/.grok/sessions/%2FUsers%2Fme%2F.grok%2Fworktrees%2Fx%2Fsubagent-01a0/01a0/updates.jsonl"
	if !p.IsSubagent(sub) {
		t.Fatal("a subagent worktree session must be flagged")
	}
	if p.IsSubagent(grokPath) {
		t.Fatal("a main session must not be flagged")
	}
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd tui && go test ./internal/reader/ -run Grok -v`
Expected: FAIL — `undefined: grokParser`.

- [ ] **Step 4: Add the coverage fields to `reader.Event`**

In `tui/internal/reader/reader.go`, inside the `Event` struct, after `Costed`:

```go
	// CoverageOnly marks a bookkeeping event that carries no usage and
	// must not be counted as spend. Grok's `usage` object is present on
	// only a fraction of historical turns, so a Grok total over an old
	// month is a floor rather than a total. One coverage event per
	// turn_completed lets the aggregator report that fraction instead of
	// presenting an undercount as authoritative.
	CoverageOnly bool
	// HasUsage is meaningful only on a CoverageOnly event: it is the
	// numerator of that fraction.
	HasUsage bool
```

- [ ] **Step 5: Create the vendor dispatch**

Create `tui/internal/reader/vendor.go`:

```go
package reader

import (
	"path/filepath"
	"strings"
)

// vendorParser is everything that differs between one vendor's
// transcripts and another's. Keeping it behind an interface rather than
// a chain of `if vendor == …` inside OnChange keeps each vendor's quirks
// — which files carry usage, how a project key is derived, how many
// events one line yields — in one place.
type vendorParser interface {
	// Walkable reports whether a file base name can carry usage. The
	// initial scan skips everything else, which matters for Grok: its
	// session directories hold other files whose token fields are
	// cumulative context, not usage.
	Walkable(name string) bool
	// Parse turns one line into zero or more events. Zero is normal (a
	// line with nothing we want). An error means the line was not valid
	// JSON and is counted as a parse error, never as spend.
	Parse(line []byte, slashPath string) ([]Event, error)
	// Project returns the canonical project key for a transcript path.
	Project(slashPath string) string
	// IsSubagent reports whether the path belongs to a subagent
	// transcript rather than a main session.
	IsSubagent(slashPath string) bool
}

func parserFor(vendor string) vendorParser {
	switch vendor {
	case "grok":
		return grokParser{}
	default:
		return claudeParser{}
	}
}

// claudeParser is today's behaviour, extracted unchanged.
type claudeParser struct{}

func (claudeParser) Walkable(name string) bool { return filepath.Ext(name) == ".jsonl" }

func (claudeParser) Parse(line []byte, _ string) ([]Event, error) {
	ev, ok, err := parseLine(line)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, nil
	}
	return []Event{ev}, nil
}

func (claudeParser) Project(slashPath string) string { return projectFromPath(slashPath) }

func (claudeParser) IsSubagent(slashPath string) bool {
	return strings.Contains(slashPath, "/subagents/")
}
```

- [ ] **Step 6: Create the Grok parser**

Create `tui/internal/reader/grok.go`:

```go
package reader

import (
	"encoding/json"
	"net/url"
	"strings"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/pricing"
)

// nanoDollarsPerUSD converts Grok's costUsdTicks. Confirmed by
// elimination against a known billing period: only the nano reading is
// physically possible for one week of usage.
const nanoDollarsPerUSD = 1e9

// grokUsage is the token+cost block Grok emits, at both the turn level
// and once per entry of modelUsage.
//
// inputTokens INCLUDES cachedReadTokens and outputTokens INCLUDES
// reasoningTokens — totalTokens equals inputTokens+outputTokens on every
// live record, which leaves no room for either to be additive. Mapping
// them additively would inflate token charts by roughly the cache-hit
// rate, which on real sessions is most of the input.
type grokUsage struct {
	InputTokens      uint64               `json:"inputTokens"`
	OutputTokens     uint64               `json:"outputTokens"`
	CachedReadTokens uint64               `json:"cachedReadTokens"`
	CostUsdTicks     float64              `json:"costUsdTicks"`
	ModelUsage       map[string]grokUsage `json:"modelUsage"`
}

func (u grokUsage) toUsage() pricing.Usage {
	in := u.InputTokens
	if in >= u.CachedReadTokens {
		in -= u.CachedReadTokens
	} else {
		// Defensive: a vendor that changes the semantics under us must
		// not underflow a uint64 into a nonsense figure.
		in = 0
	}
	return pricing.Usage{
		InputTokens:          in,
		OutputTokens:         u.OutputTokens,
		CacheReadInputTokens: u.CachedReadTokens,
		// Grok reports no cache-creation figure.
		CacheCreationInputTokens: 0,
	}
}

type grokLine struct {
	Timestamp int64 `json:"timestamp"`
	Params    *struct {
		SessionID string `json:"sessionId"`
		Update    *struct {
			SessionUpdate string     `json:"sessionUpdate"`
			PromptID      string     `json:"prompt_id"`
			Usage         *grokUsage `json:"usage"`
		} `json:"update"`
	} `json:"params"`
}

type grokParser struct{}

// Walkable restricts the scan to updates.jsonl. Grok writes other files
// under sessions/, and their _meta.totalTokens is a cumulative per-prompt
// context total, not usage — summing it would be a large silent overcount.
func (grokParser) Walkable(name string) bool { return name == "updates.jsonl" }

// Parse emits one coverage event per turn_completed plus one usage event
// per entry of modelUsage.
//
// The top-level usage block is the sum across modelUsage, so it is used
// only when modelUsage is empty — emitting both would double every
// figure. When modelUsage is absent the model is unknown to us, and the
// cell is recorded under the bare vendor name rather than dropped: a
// turn we cannot attribute to a model is still money spent.
func (p grokParser) Parse(line []byte, slashPath string) ([]Event, error) {
	var l grokLine
	if err := json.Unmarshal(line, &l); err != nil {
		return nil, err
	}
	if l.Params == nil || l.Params.Update == nil {
		return nil, nil
	}
	u := l.Params.Update
	if u.SessionUpdate != "turn_completed" {
		return nil, nil
	}

	ts := time.Unix(l.Timestamp, 0)
	base := Event{
		Timestamp: ts,
		SessionID: l.Params.SessionID,
	}

	cov := base
	cov.CoverageOnly = true
	// A turn counts as covered only when it carries a usable cost. Three
	// records in the live corpus have real tokens and costUsdTicks == 0;
	// treating those as covered would let a known-incomplete figure
	// present itself as complete, which is the exact failure this tally
	// exists to catch.
	cov.HasUsage = u.Usage != nil && u.Usage.CostUsdTicks != 0
	// Coverage events carry no MessageID, so they would slip past the
	// aggregator's dedupe and inflate on any re-scan. prompt_id plus a
	// sentinel reuses that machinery verbatim.
	cov.MessageID = u.PromptID
	cov.RequestID = "coverage"
	out := []Event{cov}

	if u.Usage == nil {
		return out, nil
	}

	emit := func(model string, gu grokUsage) {
		ev := base
		ev.Model = model
		// prompt_id is unique per usage record; pairing it with the
		// model keeps a multi-model turn's cells distinct under the
		// aggregator's existing MessageID:RequestID dedupe.
		ev.MessageID = u.PromptID
		ev.RequestID = model
		ev.Usage = gu.toUsage()
		ev.CostUSD = gu.CostUsdTicks / nanoDollarsPerUSD
		ev.Costed = true
		out = append(out, ev)
	}

	if len(u.Usage.ModelUsage) == 0 {
		emit("grok", *u.Usage)
		return out, nil
	}
	for model, mu := range u.Usage.ModelUsage {
		emit(model, mu)
	}
	return out, nil
}

// Project derives the project key from the session directory, which is
// the percent-encoded working directory. Decoding it and re-encoding the
// Claude way (every '/' and '.' becomes '-') keeps one working directory
// one row in the per-project table no matter which vendor produced the
// spend.
func (grokParser) Project(slashPath string) string { return grokProjectKey(slashPath) }

func grokProjectKey(slashPath string) string {
	idx := strings.Index(slashPath, "/sessions/")
	if idx < 0 {
		return ""
	}
	rest := slashPath[idx+len("/sessions/"):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		rest = rest[:i]
	}
	decoded, err := url.PathUnescape(rest)
	if err != nil {
		// Undecodable is still a stable key; better a slightly ugly row
		// than a project's spend vanishing into the empty-key bucket.
		decoded = rest
	}
	return strings.NewReplacer("/", "-", ".", "-").Replace(decoded)
}

// IsSubagent flags Grok's per-subagent worktree sessions, which live in
// a directory named subagent-<that session's own id>.
//
// They are counted, not skipped: a parent turn does NOT include its
// subagents' cost. Established on the live corpus 2026-08-15 — parent
// session 01a005ba reports $0.901 across 2 model calls for a turn
// completing 21s after a subagent turn of $1.081 across 16 calls. An
// inclusive parent could not report fewer calls or fewer dollars than
// the child it supposedly contains. (The spec's original probe, which
// found one usage event across eight subagent files, is stale — there
// are now many.)
//
// The match is on the final path segment rather than anywhere in the
// path, so a user whose own worktree happens to be named "subagent-foo"
// does not get their main-session spend filed under the subagent column.
func (grokParser) IsSubagent(slashPath string) bool {
	idx := strings.Index(slashPath, "/sessions/")
	if idx < 0 {
		return false
	}
	rest := slashPath[idx+len("/sessions/"):]
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		rest = rest[:i]
	}
	decoded, err := url.PathUnescape(rest)
	if err != nil {
		decoded = rest
	}
	last := decoded
	if i := strings.LastIndexByte(decoded, '/'); i >= 0 {
		last = decoded[i+1:]
	}
	return strings.HasPrefix(last, "subagent-")
}
```

- [ ] **Step 7: Run the tests**

Run: `cd tui && go test ./internal/reader/ -v`
Expected: PASS, including every existing Claude reader test.

- [ ] **Step 8: Commit**

```bash
git add tui/internal/reader/vendor.go tui/internal/reader/grok.go \
        tui/internal/reader/grok_test.go tui/internal/reader/testdata/grok_updates.jsonl \
        tui/internal/reader/reader.go
git commit -m "feat(reader): Grok parser behind a per-vendor dispatch

turn_completed records with usage, one cell per modelUsage entry, cost
taken from costUsdTicks as nano-dollars. Top-level totals are the sum
across modelUsage and are used only when that map is empty."
```

---

## Task 4: Wire the Grok parser into scanning and watching

The parser exists but nothing calls it: `OnChange` still inlines `parseLine`, and
`InitialScan` still filters on `.jsonl`. This task routes both through
`parserFor(r.src.Vendor)`.

**Files:**
- Modify: `tui/internal/reader/reader.go:130-205` (`OnChange`), `:245-300` (`InitialScan`)
- Test: `tui/internal/reader/reader_test.go`

**Interfaces:**
- Consumes: `parserFor`, `grokParser`, `claudeParser` from Task 3.
- Produces: no new symbols. `OnChangeSource`/`InitialScanSource` behave per-vendor.

- [ ] **Step 1: Write the failing test**

Add to `tui/internal/reader/reader_test.go`:

```go
// A Grok source scans end-to-end: the reader picks the Grok parser from
// the source's vendor, walks only updates.jsonl, and tags every event
// with the source identity.
func TestInitialScanSource_GrokEndToEnd(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "%2FUsers%2Fme%2Fsrc%2Fproj", "01a0-sess")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	fixture, err := os.ReadFile("testdata/grok_updates.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "updates.jsonl"), fixture, 0o644); err != nil {
		t.Fatal(err)
	}
	// A sibling file that must be ignored: its token fields are
	// cumulative context, not usage.
	if err := os.WriteFile(filepath.Join(dir, "messages.jsonl"), fixture, 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 64)
	r := New(ch)
	src := sources.Source{Vendor: "grok", Label: "grok", Root: root}
	if err := r.InitialScanSource(src, time.Time{}); err != nil {
		t.Fatal(err)
	}
	close(ch)

	var usage int
	for e := range ch {
		if e.Vendor != "grok" || e.Source != "grok/grok" {
			t.Fatalf("event tagged %s/%s, want grok/grok", e.Vendor, e.Source)
		}
		if e.CoverageOnly {
			continue
		}
		usage++
		if e.Project != "-Users-me-src-proj" {
			t.Fatalf("project = %q, want -Users-me-src-proj", e.Project)
		}
		if !e.Costed {
			t.Fatal("a Grok usage event must be costed")
		}
	}
	// Exactly the 5 usage events from updates.jsonl. If messages.jsonl
	// were also walked this would be 10.
	if usage != 5 {
		t.Fatalf("usage events = %d, want 5 (messages.jsonl must be skipped)", usage)
	}
}

// The same turn really does get written into two session directories:
// across the local corpus 187 of 188 prompt_ids are unique and the one
// exception appears under two session ids in the same worktree. Scanning
// both directories is correct — a parent turn does not include its
// subagents' cost — so dedupe is the only thing standing between that
// turn and being billed twice.
func TestScan_DuplicateTurnAcrossSessionDirsIsCountedOnce(t *testing.T) {
	root := t.TempDir()
	line := `{"timestamp":1786807668,"method":"_x.ai/session/update","params":{"sessionId":"%s","update":{"sessionUpdate":"turn_completed","prompt_id":"shared-1","usage":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":400,"costUsdTicks":1656000000,"modelUsage":{"grok-4.6-build":{"inputTokens":1000,"outputTokens":100,"cachedReadTokens":400,"costUsdTicks":1656000000}}}}}}` + "\n"

	enc := "%2FUsers%2Fme%2F.grok%2Fworktrees%2Fx%2Fsubagent-aaaa"
	for _, sess := range []string{"aaaa", "bbbb"} {
		dir := filepath.Join(root, enc, sess)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "updates.jsonl"),
			[]byte(fmt.Sprintf(line, sess)), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	ch := make(chan Event, 64)
	r := New(ch)
	if err := r.InitialScanSource(
		sources.Source{Vendor: "grok", Label: "grok", Root: root}, time.Time{}); err != nil {
		t.Fatal(err)
	}
	close(ch)

	a := agg.NewWithClock(pricing.Table{}, func() time.Time {
		return time.Unix(1786807668, 0)
	})
	for e := range ch {
		a.Apply(e)
	}
	got := a.Snapshot()
	total := 0.0
	for _, md := range got.Month {
		total += md.USD
	}
	if math.Abs(total-1.656) > 1e-9 {
		t.Fatalf("month total = %v, want 1.656 — the turn appears in two session dirs and must be counted once", total)
	}
	if got.Coverage["grok"].Turns != 1 {
		t.Fatalf("coverage turns = %d, want 1", got.Coverage["grok"].Turns)
	}
}
```

This test imports `agg`, which imports `reader` — so it must live in
`tui/internal/reader/scan_dedupe_test.go` with `package reader_test`, not in the
internal test package. Import `reader` explicitly there and qualify `Event`,
`New` and `InitialScanSource`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/reader/ -run GrokEndToEnd -v`
Expected: FAIL — `usage events = 0` (the walk finds the files but `parseLine` returns nothing for a Grok line).

- [ ] **Step 3: Route `OnChange` through the parser**

In `OnChange`, replace the vendor/source read and the per-line block. The read
becomes:

```go
	r.mu.Lock()
	start := r.offsets[path]
	src := r.src
	r.mu.Unlock()
	vendor, source := src.Vendor, src.ID()
	p := parserFor(vendor)
```

and the loop body from `ev, ok, perr := parseLine(line)` through `r.out <- ev`
becomes:

```go
		slashPath := filepath.ToSlash(path)
		evs, perr := p.Parse(line, slashPath)
		if perr != nil {
			r.mu.Lock()
			r.parseErrors++
			r.mu.Unlock()
			continue
		}
		project := p.Project(slashPath)
		isSub := p.IsSubagent(slashPath)
		for _, ev := range evs {
			// Normalise to forward-slash so the project + subagent
			// detection works the same on Windows as on Unix.
			ev.Project = project
			ev.IsSubagent = isSub
			ev.Vendor = vendor
			ev.Source = source
			r.out <- ev
		}
```

- [ ] **Step 4: Route `InitialScan`'s filter through the parser**

`InitialScan` takes a bare root and has no source, so read the vendor from the
reader's current source at the top of the function:

```go
func (r *Reader) InitialScan(root string, notBefore time.Time) error {
	r.mu.Lock()
	vendor := r.src.Vendor
	r.mu.Unlock()
	p := parserFor(vendor)

	paths := make(chan string, 256)
	// … unchanged …
```

and replace the extension check inside the `WalkDir` callback:

```go
			if !p.Walkable(d.Name()) {
				return nil
			}
```

- [ ] **Step 5: Run the tests**

Run: `cd tui && go test ./internal/reader/ -v`
Expected: PASS.

Run: `cd tui && go test ./...`
Expected: PASS.

- [ ] **Step 6: Verify against the live corpus**

Run: `cd tui && go run ./cmd/claudecounter --once`
Expected: stderr shows a second `scanning …/.grok/sessions (grok/grok) …` line,
and the per-model table lists at least one `grok-*` row with a non-zero dollar
figure.

- [ ] **Step 7: Commit**

```bash
git add tui/internal/reader/reader.go tui/internal/reader/reader_test.go
git commit -m "feat(reader): scan and watch Grok sources through the vendor dispatch

OnChange and InitialScan pick their parser and file filter from the
source's vendor instead of assuming Claude."
```

---

## Task 5: Partial-coverage reporting (Go)

Grok's `usage` object is present on ~20% of July turns and ~92% of August turns. A
July total computed from what is there is roughly a fifth of the truth and looks
exactly as authoritative as a correct one. This surfaces the fraction.

**Files:**
- Modify: `tui/internal/agg/agg.go` (coverage counters, `Totals.Coverage`, `Apply`)
- Modify: `tui/internal/agg/group.go` (`GroupCoverage`)
- Modify: `tui/internal/ui/group_view.go:19` (`renderSeries`), `tui/internal/ui/view_split.go:81`, `tui/internal/ui/view_minimal.go:54` (its two callers)
- Test: `tui/internal/agg/agg_test.go`, `tui/internal/agg/group_test.go`, `tui/internal/ui/group_view_test.go`

**Interfaces:**
- Consumes: `reader.Event.CoverageOnly`/`HasUsage` from Task 3.
- Produces:
  - `agg.Coverage{Turns int; WithUsage int}` with method `Fraction() float64` (returns 1 when `Turns == 0`)
  - `agg.Totals.Coverage map[string]Coverage` — keyed by vendor, scoped to the current month
  - `agg.PartialCoverageThreshold = 0.95`
  - `func (c Coverage) Partial() bool`
  - `func GroupCoverage(in map[SeriesKey]ModelDay, cov map[string]Coverage, m Mode) map[string]Coverage` — maps each display row name to the *worst* coverage among the vendors contributing to that row
  - `renderSeries(series map[string]agg.ModelDay, rowCoverage map[string]agg.Coverage, mode agg.Mode, barWidth int) string` — one new parameter; both existing callers pass `agg.GroupCoverage(...)`

- [ ] **Step 1: Write the failing test**

Add to `tui/internal/agg/agg_test.go`:

```go
func TestCoverage_ReportsTheUsageBearingFraction(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.Local)
	a := agg.NewWithClock(pricing.Table{}, func() time.Time { return now })

	// 3 of 4 turns carried usage.
	for i, hasUsage := range []bool{true, true, true, false} {
		a.Apply(reader.Event{
			Timestamp:    now,
			Vendor:       "grok",
			Source:       "grok/grok",
			CoverageOnly: true,
			HasUsage:     hasUsage,
		})
		_ = i
	}

	got := a.Snapshot()
	cov := got.Coverage["grok"]
	if cov.Turns != 4 || cov.WithUsage != 3 {
		t.Fatalf("coverage = %+v, want {Turns:4 WithUsage:3}", cov)
	}
	if math.Abs(cov.Fraction()-0.75) > 1e-9 {
		t.Fatalf("fraction = %v, want 0.75", cov.Fraction())
	}
	if !cov.Partial() {
		t.Fatal("0.75 is below the threshold and must read as partial")
	}
}

// Coverage events go through the same dedupe as usage events. Without
// that, any path that re-reads a file (AppState.refresh, a source
// removed and re-added, a cache restore that misses an offset) inflates
// the tally — and a *partial* re-read skews the fraction optimistic,
// hiding the very undercount the marker exists to surface.
func TestCoverage_IsDedupedLikeUsage(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.Local)
	a := agg.NewWithClock(pricing.Table{}, func() time.Time { return now })
	ev := reader.Event{
		Timestamp: now, Vendor: "grok", Source: "grok/grok",
		MessageID: "p1", RequestID: "coverage",
		CoverageOnly: true, HasUsage: true,
	}
	a.Apply(ev)
	a.Apply(ev)

	if got := a.Snapshot().Coverage["grok"].Turns; got != 1 {
		t.Fatalf("Turns = %d, want 1 — the second event is a duplicate", got)
	}
}

// The coverage event and the usage events from the same turn share a
// prompt_id and must not evict one another.
func TestCoverage_SentinelDoesNotCollideWithTheTurnsUsageEvents(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.Local)
	a := agg.NewWithClock(pricing.Table{}, func() time.Time { return now })
	a.Apply(reader.Event{
		Timestamp: now, Vendor: "grok", Source: "grok/grok",
		MessageID: "p1", RequestID: "coverage", CoverageOnly: true, HasUsage: true,
	})
	a.Apply(reader.Event{
		Timestamp: now, Vendor: "grok", Source: "grok/grok",
		Model: "grok-4.6-build", MessageID: "p1", RequestID: "grok-4.6-build",
		CostUSD: 1.5, Costed: true,
	})

	got := a.Snapshot()
	if got.Coverage["grok"].Turns != 1 {
		t.Fatalf("Turns = %d, want 1", got.Coverage["grok"].Turns)
	}
	key := agg.SeriesKey{Source: "grok/grok", Vendor: "grok", Model: "grok-4.6-build"}
	if math.Abs(got.Month[key].USD-1.5) > 1e-9 {
		t.Fatalf("month USD = %v, want 1.5 — the usage event must survive", got.Month[key].USD)
	}
}

// A coverage event carries no spend and must never move a dollar or a
// token. It is bookkeeping only.
func TestCoverage_EventContributesNoSpend(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.Local)
	a := agg.NewWithClock(pricing.Table{}, func() time.Time { return now })
	a.Apply(reader.Event{
		Timestamp: now, Vendor: "grok", Source: "grok/grok",
		CoverageOnly: true, HasUsage: true,
		// Deliberately non-zero: if Apply ever falls through to the cell
		// write, these show up as spend.
		Usage:   pricing.Usage{InputTokens: 999},
		CostUSD: 99, Costed: true,
	})
	got := a.Snapshot()
	if len(got.Month) != 0 {
		t.Fatalf("month series = %+v, want none", got.Month)
	}
	if got.Daily[len(got.Daily)-1].USD != 0 {
		t.Fatalf("daily USD = %v, want 0", got.Daily[len(got.Daily)-1].USD)
	}
}

// A vendor that reports usage on everything is complete, and a vendor
// that emits no coverage events at all (Claude) reads as complete rather
// than as zero.
func TestCoverage_FullAndAbsentBothReadAsComplete(t *testing.T) {
	now := time.Date(2026, 8, 15, 12, 0, 0, 0, time.Local)
	a := agg.NewWithClock(pricing.Table{}, func() time.Time { return now })
	a.Apply(reader.Event{Timestamp: now, Vendor: "grok", Source: "grok/grok",
		CoverageOnly: true, HasUsage: true})

	got := a.Snapshot()
	if got.Coverage["grok"].Partial() {
		t.Fatal("1.00 coverage must not read as partial")
	}
	if got.Coverage["claude"].Partial() {
		t.Fatal("a vendor with no coverage events must read as complete, not 0%")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && go test ./internal/agg/ -run Coverage -v`
Expected: FAIL — `got.Coverage undefined`.

- [ ] **Step 3: Add the coverage type and counters**

In `tui/internal/agg/agg.go`, after the `SeriesKey` declaration:

```go
// PartialCoverageThreshold is the usage-bearing fraction below which a
// vendor's figures are presented as a floor rather than a total.
const PartialCoverageThreshold = 0.95

// Coverage is how much of a vendor's activity carried usable usage data.
// Grok added its usage object to turn_completed only recently, so an old
// month's total is a fraction of the truth while looking exactly as
// authoritative as a correct one. This is what lets the UI say so.
type Coverage struct {
	Turns     int // turns seen
	WithUsage int // turns that carried usage
}

// Fraction returns the usage-bearing share. A vendor that reported no
// turns at all is complete by definition, not 0% — Claude emits no
// coverage events and must never render as a partial figure.
func (c Coverage) Fraction() float64 {
	if c.Turns == 0 {
		return 1
	}
	return float64(c.WithUsage) / float64(c.Turns)
}

func (c Coverage) Partial() bool { return c.Fraction() < PartialCoverageThreshold }
```

Add to `Totals`:

```go
	// Coverage is keyed by vendor and scoped to the current month, the
	// same scope as Month.
	Coverage map[string]Coverage
```

Add to `Aggregator`:

```go
	coverage map[covKey]Coverage
```

and next to `cellKey`:

```go
// covKey scopes a coverage tally to a (day, vendor) so Snapshot can
// restrict it to the displayed month rather than the whole scan range.
type covKey struct {
	Day    civilDay
	Vendor string
}
```

Initialise it in `NewWithClock`: `coverage: map[covKey]Coverage{}`.

- [ ] **Step 4: Handle coverage events in `Apply`**

Insert **immediately after** the existing `MessageID:RequestID` dedupe block and
before the unknown-model check.

Order matters and is the opposite of what it looks like it should be. A coverage
event has to pass *through* dedupe, not skip it: the reader emits one per
`turn_completed`, and any path that re-reads a file — `AppState.refresh`,
`reloadSources` re-adding a source, a cache restore that misses an offset —
would otherwise re-count every turn. `cells` survives that because of `perMsg`;
coverage would not. Worse, the inflation is invisible: a full re-read inflates
`Turns` and `WithUsage` equally so the fraction still looks right, while a
*partial* re-read covering only recent files skews it optimistic — hiding
exactly the undercount the marker exists to surface.

The parser gives the event `MessageID = prompt_id` and `RequestID = "coverage"`,
so it occupies its own dedupe slot without colliding with the usage events from
the same turn (whose `RequestID` is the model name).

```go
	if e.CoverageOnly {
		// Bookkeeping only: a coverage event records that a turn
		// happened and whether it carried usable cost. It must never
		// reach the cell write — the fields it shares with a real event
		// (Usage, CostUSD) are not spend. It has already been through
		// dedupe above, which is what keeps a re-scan from inflating it.
		k := covKey{Day: dayOf(e.Timestamp), Vendor: e.Vendor}
		c := a.coverage[k]
		c.Turns++
		if e.HasUsage {
			c.WithUsage++
		}
		a.coverage[k] = c
		return
	}
```

- [ ] **Step 5: Fill `Totals.Coverage` in `Snapshot`**

Add `Coverage: map[string]Coverage{}` to the `out := Totals{…}` literal, and after
the daily-window block:

```go
	// Coverage is scoped to the displayed month, matching out.Month.
	for k, c := range a.coverage {
		if !inMonth(k.Day) {
			continue
		}
		cur := out.Coverage[k.Vendor]
		cur.Turns += c.Turns
		cur.WithUsage += c.WithUsage
		out.Coverage[k.Vendor] = cur
	}
```

- [ ] **Step 6: Run the aggregator tests**

Run: `cd tui && go test ./internal/agg/ -v`
Expected: PASS.

- [ ] **Step 7: Write the failing test for `GroupCoverage`**

`renderSeries` receives display-row *names*, not `SeriesKey`s, so it cannot tell
which vendors a row spans. `GroupCoverage` collapses coverage the same way
`Group` collapses totals, using the same `Mode.label`, so the two maps always
share a key set.

Add to `tui/internal/agg/group_test.go`:

```go
// A row that spans vendors takes the worst of their coverage. Averaging
// would let a large complete Claude figure hide a small partial Grok one
// inside the same row.
func TestGroupCoverage_RowTakesTheWorstContributingVendor(t *testing.T) {
	in := map[agg.SeriesKey]agg.ModelDay{
		{Source: "claude/claude", Vendor: "claude", Model: "m"}: {USD: 100},
		{Source: "grok/grok", Vendor: "grok", Model: "m"}:       {USD: 1},
	}
	cov := map[string]agg.Coverage{"grok": {Turns: 100, WithUsage: 20}}

	// GroupTotal merges everything into one row, which therefore spans
	// both vendors.
	got := agg.GroupCoverage(in, cov, agg.GroupTotal)
	if !got["total"].Partial() {
		t.Fatalf("total row coverage = %+v, want partial", got["total"])
	}
	// GroupVendor keeps them apart.
	byVendor := agg.GroupCoverage(in, cov, agg.GroupVendor)
	if byVendor["claude"].Partial() {
		t.Fatal("the claude row must not be marked partial")
	}
	if !byVendor["grok"].Partial() {
		t.Fatal("the grok row must be marked partial")
	}
	// Key sets match Group's exactly, or a row would render without its
	// marker.
	if len(agg.Group(in, agg.GroupVendor)) != len(byVendor) {
		t.Fatal("GroupCoverage and Group must share a key set")
	}
}
```

- [ ] **Step 8: Run it to verify it fails, then implement `GroupCoverage`**

Run: `cd tui && go test ./internal/agg/ -run GroupCoverage -v`
Expected: FAIL — `undefined: agg.GroupCoverage`.

Add to `tui/internal/agg/group.go`:

```go
// GroupCoverage collapses per-vendor coverage onto the same display rows
// Group produces, so the two maps always share a key set — a row without
// an entry would silently render unmarked.
//
// A row spanning several vendors takes the worst of them. Averaging, or
// weighting by spend, would let a large complete Claude figure hide a
// small partial Grok one inside the same row, which is exactly the
// failure this marker exists to prevent.
func GroupCoverage(in map[SeriesKey]ModelDay, cov map[string]Coverage, m Mode) map[string]Coverage {
	out := make(map[string]Coverage, len(in))
	for k := range in {
		name := m.label(k)
		c := cov[k.Vendor]
		if cur, ok := out[name]; ok && cur.Fraction() <= c.Fraction() {
			continue
		}
		out[name] = c
	}
	return out
}
```

- [ ] **Step 9: Write the failing UI test**

Add to `tui/internal/ui/group_view_test.go` (package `ui` — `renderSeries` is
unexported):

```go
// A vendor below the coverage threshold is marked so a user reading an
// old month sees a floor rather than a confident total.
func TestRenderSeries_MarksPartialCoverage(t *testing.T) {
	series := map[string]agg.ModelDay{"grok": {USD: 12.34}}
	rowCov := map[string]agg.Coverage{"grok": {Turns: 100, WithUsage: 20}}

	out := renderSeries(series, rowCov, agg.GroupVendor, 0)
	if !strings.Contains(out, "~20%") {
		t.Fatalf("expected a coverage marker in:\n%s", out)
	}
}

// A complete vendor renders exactly as it does today — no marker, no
// stray spacing.
func TestRenderSeries_CompleteCoverageIsUnmarked(t *testing.T) {
	series := map[string]agg.ModelDay{"claude": {USD: 12.34}}
	out := renderSeries(series, map[string]agg.Coverage{}, agg.GroupVendor, 0)
	if strings.Contains(out, "%") {
		t.Fatalf("unexpected coverage marker in:\n%s", out)
	}
}
```

Update the six existing `renderSeries(...)` calls in that file to pass
`map[string]agg.Coverage{}` as the new second argument.

- [ ] **Step 10: Run it to verify it fails, then implement**

Run: `cd tui && go test ./internal/ui/ -run PartialCoverage -v`
Expected: FAIL — `too many arguments in call to renderSeries`.

Add the parameter to `renderSeries` and append the suffix per row:

```go
// coverageSuffix marks a figure computed from partial data. Rendered
// inline rather than as a footnote: a user scanning the table for a
// dollar amount must see the caveat attached to that amount, not at the
// bottom of the pane.
func coverageSuffix(c agg.Coverage) string {
	if !c.Partial() {
		return ""
	}
	return fmt.Sprintf(" ~%.0f%%", c.Fraction()*100)
}
```

Style it with the same dim lipgloss style the view already uses for secondary
annotations — read the file and reuse the existing style variable rather than
declaring a new one.

Update both callers:

- `tui/internal/ui/view_split.go:81` →
  `renderSeries(agg.Group(t.Day, mode), agg.GroupCoverage(t.Day, t.Coverage, mode), mode, splitBarWidth)`
- `tui/internal/ui/view_minimal.go:54` →
  `renderSeries(agg.Group(t.Day, mode), agg.GroupCoverage(t.Day, t.Coverage, mode), mode, 0)`

- [ ] **Step 11: Run the tests and commit**

Run: `cd tui && go test ./...`
Expected: PASS.

```bash
git add tui/internal/agg/agg.go tui/internal/agg/agg_test.go \
        tui/internal/agg/group.go tui/internal/agg/group_test.go \
        tui/internal/ui/group_view.go tui/internal/ui/group_view_test.go \
        tui/internal/ui/view_split.go tui/internal/ui/view_minimal.go
git commit -m "feat(agg): report each vendor's usage-bearing coverage

Grok emitted usage on ~20% of July turns and ~92% of August turns. A
July total is a floor; the table now says so instead of presenting an
undercount as authoritative."
```

---

## Task 6: Swift source defaults

Mirror of Task 2. Small and self-contained, so it lands before the aggregator
change that depends on nothing but is much larger.

**Files:**
- Modify: `macapp/Sources/ClaudeCounterCore/Sources.swift:78` (`knownVendors`), `:85-90` (`defaults`)
- Modify: `macapp/Sources/ClaudeCounterBar/SourcesEditorView.swift` (vendor picker options)
- Test: `macapp/Tests/ClaudeCounterCoreTests/SourcesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Sources.defaults(home:) -> [SourceEntry]` returning 1 or 2 entries, Claude first — same contract as Go's `sources.Defaults`.

- [ ] **Step 1: Write the failing test**

Add to `macapp/Tests/ClaudeCounterCoreTests/SourcesTests.swift`:

```swift
func test_defaults_discoversGrokWhenPresent() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }
    try FileManager.default.createDirectory(
        atPath: (home as NSString).appendingPathComponent(".grok/sessions"),
        withIntermediateDirectories: true)

    let got = Sources.defaults(home: home)
    XCTAssertEqual(got.count, 2, "expected the Claude default plus a discovered Grok source")
    XCTAssertEqual(got[0].vendor, "claude", "Claude must stay first")
    XCTAssertEqual(got[1].vendor, "grok")
    XCTAssertEqual(got[1].label, "grok")
    XCTAssertEqual(got[1].root, (home as NSString).appendingPathComponent(".grok/sessions"))
}

func test_defaults_omitsGrokWhenAbsent() throws {
    let home = try makeTempHome()
    defer { try? FileManager.default.removeItem(atPath: home) }

    let got = Sources.defaults(home: home)
    XCTAssertEqual(got.count, 1, "a user with no ~/.grok must see no change at all")
    XCTAssertEqual(got[0].vendor, "claude")
}

/// Creates an empty temporary directory to stand in for $HOME.
private func makeTempHome() throws -> String {
    let dir = NSTemporaryDirectory() + "sources-defaults-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}
```

If `makeTempHome` already exists in the file, drop the duplicate.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd macapp && swift test --filter SourcesTests`
Expected: FAIL — `expected the Claude default plus a discovered Grok source`.

- [ ] **Step 3: Implement**

In `macapp/Sources/ClaudeCounterCore/Sources.swift`, replace `defaults(home:)`:

```swift
    /// The implicit source list used when no config file exists.
    ///
    /// The Claude entry is unconditional and always first — it is the
    /// original hardcoded behaviour. Other vendors are auto-discovered:
    /// added only when their root exists on this machine, mirroring how
    /// `PlanLimits` already finds ~/.grok with zero configuration. A user
    /// with no ~/.grok sees no change whatsoever.
    ///
    /// Mirrors `sources.Defaults` in `tui/internal/sources/sources.go`;
    /// the two lists must stay in step or the surfaces disagree about
    /// what an unconfigured install counts.
    public static func defaults(home: String) -> [SourceEntry] {
        var out = [SourceEntry(vendor: "claude", label: "claude",
                               root: (home as NSString).appendingPathComponent(".claude/projects"))]
        for (vendor, segment) in discoverable {
            let root = (home as NSString).appendingPathComponent(segment)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue {
                out.append(SourceEntry(vendor: vendor, label: vendor, root: root))
            }
        }
        return out
    }

    /// Non-Claude vendors `defaults(home:)` probes for, in append order.
    private static let discoverable: [(vendor: String, segment: String)] = [
        ("grok", ".grok/sessions"),
    ]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd macapp && swift test --filter SourcesTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macapp/Sources/ClaudeCounterCore/Sources.swift \
        macapp/Tests/ClaudeCounterCoreTests/SourcesTests.swift
git commit -m "feat(macapp): auto-discover a Grok install in the default source list

Mirrors sources.Defaults in Go so both surfaces count the same thing on
an unconfigured install."
```

---

## Task 7: Costed cells and cache v5 in the Swift aggregator

Mirror of Task 1, plus the persistence that Go does not need. The macapp keeps
cells between runs, so a vendor-reported dollar must survive a restart — a cell
restored without it would silently render as `$0.00` for every past day.

**Files:**
- Modify: `macapp/Sources/ClaudeCounterCore/Aggregator.swift:170-200` (storage), `:250-300` (`apply`), `:302-460` (`snapshot`)
- Modify: `macapp/Sources/ClaudeCounterCore/Cache.swift:1-99` (schema), `:149-226` (bridge)
- Test: `macapp/Tests/ClaudeCounterCoreTests/AggregatorTests.swift`, `CacheTests.swift`

**Interfaces:**
- Consumes: `UsageEvent` extended in Task 8 — **define the fields here** so this task compiles standalone: add `costUSD: Double = 0`, `costed: Bool = false`, `coverageOnly: Bool = false`, `hasUsage: Bool = false` to `UsageEvent`'s stored properties and `init`, all defaulted so every existing call site is untouched.
- Produces:
  - `Aggregator.CellValue { tokens: TokenCounts; costedUSD: Double; pricedTokens: TokenCounts }` with `adding(_:)`
  - `Aggregator.cells: [CellKey: CellValue]`, `load(cells:perMsg:unknownMsgs:dupes:coverage:)`, `exportState()` returning a 5-tuple with `coverage`
  - `HourBucketKey` gains `vendor`; `exportHourBuckets()` returns `(day:hour:vendor:model:value:)` with `value: CellValue`
  - `Coverage { turns: Int; withUsage: Int }`, `Coverage.fraction`, `Coverage.partial`, `Aggregator.partialCoverageThreshold = 0.95`
  - `Totals.coverage: [String: Coverage]`
  - `DailyTotal.hourlyUSDByModel` unchanged in shape — costed dollars flow into it via the hour buckets
  - `CacheFile.currentVersion = 5`

- [ ] **Step 1: Write the failing tests**

Add to `macapp/Tests/ClaudeCounterCoreTests/AggregatorTests.swift`:

```swift
func test_costedEvent_ignoresPricingTable() async {
    // Price the model absurdly: if snapshot ever consults the table for
    // a costed cell the assertion fails loudly rather than drifting.
    let table = PricingTable(models: ["grok-4.6-build":
        ModelPrice(inputPerMTok: 1000, outputPerMTok: 1000,
                   cacheCreationPerMTok: 0, cacheReadPerMTok: 0)])
    let now = Date(timeIntervalSince1970: 1_786_800_000)
    let agg = Aggregator(pricing: table, now: { now })

    await agg.apply(UsageEvent(
        timestamp: now, sessionID: "s", cwd: "", project: "p",
        model: "grok-4.6-build", messageID: "prompt-1", requestID: "grok-4.6-build",
        isSubagent: false,
        usage: Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 0, cacheRead: 0),
        source: "grok/grok", vendor: "grok",
        costUSD: 0.37, costed: true))

    let got = await agg.snapshot()
    let key = SeriesKey(source: "grok/grok", vendor: "grok", model: "grok-4.6-build")
    XCTAssertEqual(got.month[key]?.usd ?? 0, 0.37, accuracy: 1e-9)
    XCTAssertEqual(got.day[key]?.usd ?? 0, 0.37, accuracy: 1e-9)
    XCTAssertEqual(got.daily.last?.usd ?? 0, 0.37, accuracy: 1e-9)
    XCTAssertEqual(got.monthProj["p"]?.totalUSD ?? 0, 0.37, accuracy: 1e-9)
    XCTAssertEqual(got.unknown, 0, "a costed model has no pricing entry to be missing")
    // The hourly chart must show it too — that is the view the user asked for.
    let hour = Calendar.current.component(.hour, from: now)
    XCTAssertEqual(got.todayHourlyUSD[hour], 0.37, accuracy: 1e-9)
    XCTAssertEqual(got.daily.last?.hourlyUSDByModel[hour]["grok-4.6-build"] ?? 0,
                   0.37, accuracy: 1e-9)
}

func test_pricedAndCostedCells_sumTogether() async {
    let table = PricingTable(models: ["claude-opus-4-7":
        ModelPrice(inputPerMTok: 15, outputPerMTok: 75,
                   cacheCreationPerMTok: 0, cacheReadPerMTok: 0)])
    let now = Date(timeIntervalSince1970: 1_786_800_000)
    let agg = Aggregator(pricing: table, now: { now })

    await agg.apply(UsageEvent(
        timestamp: now, sessionID: "s", cwd: "", project: "p",
        model: "claude-opus-4-7", messageID: "m1", requestID: "r1", isSubagent: false,
        usage: Usage(input: 1_000_000, output: 0, cacheCreate: 0, cacheRead: 0),
        source: "claude/claude", vendor: "claude"))
    await agg.apply(UsageEvent(
        timestamp: now, sessionID: "s", cwd: "", project: "p",
        model: "grok-4.6-build", messageID: "prompt-1", requestID: "grok-4.6-build",
        isSubagent: false,
        usage: Usage(input: 500, output: 0, cacheCreate: 0, cacheRead: 0),
        source: "grok/grok", vendor: "grok", costUSD: 2.5, costed: true))

    let got = await agg.snapshot()
    XCTAssertEqual(got.month.values.reduce(0) { $0 + $1.usd }, 17.5, accuracy: 1e-9)
    XCTAssertEqual(got.monthProj["p"]?.totalUSD ?? 0, 17.5, accuracy: 1e-9)
    XCTAssertEqual(got.daily.last?.usd ?? 0, 17.5, accuracy: 1e-9)
}

func test_coverageEvent_contributesNoSpendAndReportsTheFraction() async {
    let now = Date(timeIntervalSince1970: 1_786_800_000)
    let agg = Aggregator(pricing: PricingTable(models: [:]), now: { now })
    for hasUsage in [true, true, true, false] {
        await agg.apply(UsageEvent(
            timestamp: now, sessionID: "s", cwd: "", project: "p",
            model: "", messageID: "", requestID: "", isSubagent: false,
            usage: Usage(input: 999, output: 0, cacheCreate: 0, cacheRead: 0),
            source: "grok/grok", vendor: "grok",
            costUSD: 99, costed: true, coverageOnly: true, hasUsage: hasUsage))
    }
    let got = await agg.snapshot()
    XCTAssertTrue(got.month.isEmpty, "coverage events are bookkeeping, never spend")
    XCTAssertEqual(got.daily.last?.usd ?? 0, 0, accuracy: 1e-9)
    XCTAssertEqual(got.coverage["grok"]?.turns, 4)
    XCTAssertEqual(got.coverage["grok"]?.withUsage, 3)
    XCTAssertEqual(got.coverage["grok"]?.fraction ?? 0, 0.75, accuracy: 1e-9)
    XCTAssertTrue(got.coverage["grok"]?.partial ?? false)
    // A vendor that emits no coverage events reads as complete, not 0%.
    XCTAssertFalse(got.coverage["claude"]?.partial ?? false)
}
```

Add to `macapp/Tests/ClaudeCounterCoreTests/CacheTests.swift`:

```swift
func test_cache_roundTripsVendorReportedCost() async throws {
    let now = Date(timeIntervalSince1970: 1_786_800_000)
    let source = Aggregator(pricing: PricingTable(models: [:]), now: { now })
    await source.apply(UsageEvent(
        timestamp: now, sessionID: "s", cwd: "", project: "p",
        model: "grok-4.6-build", messageID: "prompt-1", requestID: "grok-4.6-build",
        isSubagent: false,
        usage: Usage(input: 100, output: 10, cacheCreate: 0, cacheRead: 50),
        source: "grok/grok", vendor: "grok", costUSD: 0.37, costed: true))
    await source.apply(UsageEvent(
        timestamp: now, sessionID: "s", cwd: "", project: "p",
        model: "", messageID: "", requestID: "", isSubagent: false,
        usage: Usage(input: 0, output: 0, cacheCreate: 0, cacheRead: 0),
        source: "grok/grok", vendor: "grok", coverageOnly: true, hasUsage: true))

    let file = await CacheFile.snapshot(aggregator: source, offsets: [:], parseErrors: 0)
    XCTAssertEqual(file.version, 5)

    let restored = Aggregator(pricing: PricingTable(models: [:]), now: { now })
    _ = await file.restore(into: restored)
    let got = await restored.snapshot()

    let key = SeriesKey(source: "grok/grok", vendor: "grok", model: "grok-4.6-build")
    XCTAssertEqual(got.month[key]?.usd ?? 0, 0.37, accuracy: 1e-9,
                   "a vendor-reported dollar must survive a restart")
    XCTAssertEqual(got.daily.last?.usd ?? 0, 0.37, accuracy: 1e-9)
    XCTAssertEqual(got.coverage["grok"]?.turns, 1)
}

func test_cache_v4IsInvalidatedOnLoad() throws {
    // A v4 cell carries no cost field. Restoring it would render every
    // past Grok day as $0.00, so the whole file must be dropped and
    // rebuilt by a full rescan.
    XCTAssertGreaterThan(CacheFile.currentVersion, 4)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd macapp && swift test --filter 'AggregatorTests|CacheTests'`
Expected: FAIL — `extra arguments 'costUSD', 'costed' in call`.

- [ ] **Step 3: Extend `UsageEvent`**

In `macapp/Sources/ClaudeCounterCore/Reader.swift`, add to `UsageEvent`'s stored
properties (after `vendor`) and to its `init` (all defaulted, so no existing call
site changes):

```swift
    /// A dollar figure the vendor reported for this event. Grok emits
    /// costUsdTicks (nano-dollars) per turn and per model; that is
    /// authoritative in a way our pricing table can never be, so it is
    /// used as given. Mirrors `reader.Event.CostUSD` in Go.
    public var costUSD: Double
    /// Marks `costUSD` as authoritative. A costed event's tokens are
    /// still recorded but never priced, and its model never counts
    /// toward the unknown tally.
    public var costed: Bool
    /// Bookkeeping only: a turn happened, and `hasUsage` says whether it
    /// carried usable usage data. Never spend. Grok's usage object is
    /// absent on most historical turns, so this is what lets a total
    /// over an old month be presented as a floor.
    public var coverageOnly: Bool
    public var hasUsage: Bool
```

init parameters: `costUSD: Double = 0, costed: Bool = false, coverageOnly: Bool = false, hasUsage: Bool = false`.

- [ ] **Step 4: Add `CellValue` and `Coverage`**

In `Aggregator.swift`, after the `SeriesKey` declaration:

```swift
/// One cell's accumulated contribution. `tokens` is everything the cell
/// saw and drives the token charts. The dollar side is split because a
/// cell may hold both kinds: `costedUSD` is summed as-is from
/// vendor-reported figures, `pricedTokens` is the subset that goes
/// through the pricing table at snapshot time.
///
/// Keeping them separate rather than branching on "is this series
/// costed" matters for the per-project, per-day and per-hour
/// aggregations, which key on model alone — there a costed and a priced
/// contribution can land in one bucket. Mirrors `agg.cellVal` in Go.
public struct CellValue: Equatable, Sendable {
    public var tokens: TokenCounts
    public var costedUSD: Double
    public var pricedTokens: TokenCounts

    public init(tokens: TokenCounts = .zero, costedUSD: Double = 0,
                pricedTokens: TokenCounts = .zero) {
        self.tokens = tokens
        self.costedUSD = costedUSD
        self.pricedTokens = pricedTokens
    }

    public static let zero = CellValue()

    public func adding(_ other: CellValue) -> CellValue {
        CellValue(tokens: tokens.adding(other.tokens),
                  costedUSD: costedUSD + other.costedUSD,
                  pricedTokens: pricedTokens.adding(other.pricedTokens))
    }
}

/// How much of a vendor's activity carried usable usage data. Mirrors
/// `agg.Coverage` in Go, threshold included.
public struct Coverage: Equatable, Sendable, Codable {
    public var turns: Int
    public var withUsage: Int

    public init(turns: Int = 0, withUsage: Int = 0) {
        self.turns = turns; self.withUsage = withUsage
    }

    /// A vendor that reported no turns is complete by definition, not
    /// 0% — Claude emits no coverage events and must never render as a
    /// partial figure.
    public var fraction: Double { turns == 0 ? 1 : Double(withUsage) / Double(turns) }
    public var partial: Bool { fraction < Aggregator.partialCoverageThreshold }
}
```

Add to `Totals`: `public var coverage: [String: Coverage] = [:]`.

- [ ] **Step 5: Change the aggregator's storage**

In the `Aggregator` actor:

```swift
    /// The usage-bearing fraction below which a vendor's figures are
    /// presented as a floor rather than a total.
    public static let partialCoverageThreshold = 0.95

    private var cells: [CellKey: CellValue] = [:]
    private var hourBuckets: [HourBucketKey: CellValue] = [:]
    private var coverage: [CoverageKey: Coverage] = [:]

    /// Scopes a coverage tally to a (day, vendor) so `snapshot` can
    /// restrict it to the displayed month.
    private struct CoverageKey: Hashable { let day: CivilDay; let vendor: String }
```

Add `vendor` to `HourBucketKey`, which is currently `(day, hour, model)`:

```swift
    /// Vendor is part of the key even though the hourly chart stacks by
    /// model alone. Without it a costed and a priced contribution could
    /// share a bucket whenever two vendors use the same model name, and
    /// the bucket would no longer be one kind or the other — which is
    /// what `CacheFile.HourEntry` relies on to round-trip in one Bool
    /// instead of a second token quartet. `CellKey` already carries
    /// vendor for the same reason.
    private struct HourBucketKey: Hashable {
        let day: CivilDay
        let hour: Int
        let vendor: String
        let model: String
    }
```

Update `load`, `exportState`, `exportHourBuckets`, `loadHourBuckets` and `reset`
to carry `CellValue` and `coverage` — signatures listed in **Interfaces** above.
`exportHourBuckets` returns `(day:hour:vendor:model:value:)` with `value: CellValue`.

- [ ] **Step 6: Update `apply`**

Insert **immediately after** the dedupe block, not before it — same ordering and
same reason as Go's Task 5 Step 4. This matters more here than in Go: `AppState`
has three paths that re-scan (`start`, `refresh`, `reloadSources`), so a coverage
event that skipped dedupe would inflate on ordinary use, not just in theory.

```swift
        if e.coverageOnly {
            // Bookkeeping only. Must never reach the cell write — the
            // fields it shares with a real event (usage, costUSD) are not
            // spend. It has already been through dedupe above, which is
            // what keeps a re-scan from inflating it.
            let k = CoverageKey(day: dayOf(e.timestamp, calendar: calendar), vendor: e.vendor)
            var c = coverage[k] ?? Coverage()
            c.turns += 1
            if e.hasUsage { c.withUsage += 1 }
            coverage[k] = c
            return true
        }
```

Change the unknown check to `if !e.costed && !pricing.has(model: e.model)`, and
the two bucket writes to build a `CellValue`:

```swift
        let contribution = e.costed
            ? CellValue(tokens: TokenCounts.zero.adding(e.usage), costedUSD: e.costUSD)
            : CellValue(tokens: TokenCounts.zero.adding(e.usage),
                        pricedTokens: TokenCounts.zero.adding(e.usage))
        cells[cellKey] = (cells[cellKey] ?? .zero).adding(contribution)

        let hour = hourOf(e.timestamp, calendar: calendar)
        let hk = HourBucketKey(day: cellKey.day, hour: hour, vendor: e.vendor, model: e.model)
        hourBuckets[hk] = (hourBuckets[hk] ?? .zero).adding(contribution)
```

- [ ] **Step 7: Update `snapshot`**

Change `modelTok`, `projModelTok` and `byDM` to `[…: CellValue]` (the fill loops
are unchanged — `CellValue.adding` has the same shape as `TokenCounts.adding`).
Then, in each pricing site, add the costed dollars:

```swift
        for (mk, v) in modelTok {
            var usd = v.costedUSD
            if pricing.has(model: mk.key.model) {
                usd += pricing.cost(model: mk.key.model, usage: v.pricedTokens.toUsage())
            }
            let md = ModelDay(usd: usd, tokens: v.tokens)
            switch mk.scope {
            case "day":   out.day[mk.key] = md
            case "month": out.month[mk.key] = md
            default: break
            }
        }
```

Apply the same `var usd = v.costedUSD` + conditional `+=` shape to the
per-project loop, the `byDM` daily loop (`dayCost` and `dayCostByModel`), and the
hour-bucket loop. In the hour-bucket loop the `priced` guard around
`hourlyUSDByDay` must become "cost is non-zero *or* the model is priced", so a
costed model still lands in the stacked hourly chart:

```swift
        for (hk, v) in hourBuckets {
            var cost = v.costedUSD
            if pricing.has(model: hk.model) {
                cost += pricing.cost(model: hk.model, usage: v.pricedTokens.toUsage())
            }
            if cost != 0 {
                var hours = hourlyUSDByDay[hk.day] ?? Array(repeating: [:], count: 24)
                hours[hk.hour][hk.model, default: 0] += cost
                hourlyUSDByDay[hk.day] = hours
            }
            if hk.day == today {
                hourly[hk.hour] = hourly[hk.hour].adding(v.tokens)
                hourlyUSD[hk.hour] += cost
            }
        }
```

Fill `out.coverage` from the `coverage` map, restricted to the displayed month,
exactly as Go's `Snapshot` does.

- [ ] **Step 8: Bump the cache to v5**

In `Cache.swift`, add to the version-history comment:

```
/// - 5: cells and hour buckets carry a vendor-reported `usd` alongside
///   the token quartet, and the file carries per-(day, vendor) coverage
///   counts. Old caches are invalidated on load → one full rescan. Without
///   the bump, a restored Grok cell would have no cost and every past day
///   would render as $0.00 while looking correct.
```

Set `public static let currentVersion = 5`. Add `usd: Double` and `costed: Bool`
to `CellEntry`, and `usd: Double`, `costed: Bool` and `vendor: String` to
`HourEntry` (and to their inits).

`usd` persists `CellValue.costedUSD`; `costed` is what makes `pricedTokens`
recoverable without a second token quartet on disk. The reconstruction is
`pricedTokens = costed ? .zero : tokens`, and it is exact **because both keys
carry vendor**: `apply` puts a contribution's tokens on exactly one side, and a
vendor-homogeneous bucket can only ever accumulate one kind. That is the whole
reason `HourBucketKey` gained `vendor` in Step 5 — without it the Bool would be
a lossy summary of a mixed bucket, and the cheaper-looking schema would quietly
misreport an hour.

Add `public let coverage: [CoverageEntry]?` to `CacheFile` with:

```swift
    /// One (day, vendor) coverage tally. Persisted because cells persist:
    /// a restored month whose coverage reset to zero would present a
    /// known-partial Grok figure as complete.
    public struct CoverageEntry: Codable, Sendable {
        public let day: String
        public let vendor: String
        public let turns: Int
        public let withUsage: Int
    }
```

Update `CacheFile.snapshot` and `CacheFile.restore` to carry `costedUSD`, the
`costed` flag, the hour buckets' vendor and the coverage array.

Confirm the v4 invalidation path already keys off `version != currentVersion`
(it does — `AppState` deletes and rescans on mismatch); if not, add it.

Also add the round-trip assertion for the hourly path, which is the one the user
actually asked about and the one the `vendor` key exists to protect:

```swift
func test_cache_roundTripsCostedHourlyBuckets() async throws {
    let now = Date(timeIntervalSince1970: 1_786_800_000)
    let source = Aggregator(pricing: PricingTable(models: [:]), now: { now })
    await source.apply(UsageEvent(
        timestamp: now, sessionID: "s", cwd: "", project: "p",
        model: "grok-4.6-build", messageID: "prompt-1", requestID: "grok-4.6-build",
        isSubagent: false,
        usage: Usage(input: 100, output: 10, cacheCreate: 0, cacheRead: 50),
        source: "grok/grok", vendor: "grok", costUSD: 0.37, costed: true))

    let file = await CacheFile.snapshot(aggregator: source, offsets: [:], parseErrors: 0)
    let restored = Aggregator(pricing: PricingTable(models: [:]), now: { now })
    _ = await file.restore(into: restored)

    let got = await restored.snapshot()
    let hour = Calendar.current.component(.hour, from: now)
    XCTAssertEqual(got.todayHourlyUSD[hour], 0.37, accuracy: 1e-9,
                   "the hourly chart must survive a restart, not flatten to zero")
    XCTAssertEqual(got.daily.last?.hourlyUSDByModel[hour]["grok-4.6-build"] ?? 0,
                   0.37, accuracy: 1e-9)
}
```

- [ ] **Step 9: Run the tests**

Run: `cd macapp && swift test`
Expected: PASS, including every pre-existing test.

- [ ] **Step 10: Commit**

```bash
git add macapp/Sources/ClaudeCounterCore/Aggregator.swift \
        macapp/Sources/ClaudeCounterCore/Cache.swift \
        macapp/Sources/ClaudeCounterCore/Reader.swift \
        macapp/Tests/ClaudeCounterCoreTests/AggregatorTests.swift \
        macapp/Tests/ClaudeCounterCoreTests/CacheTests.swift
git commit -m "feat(macapp): costed cells, coverage counts, cache v5

Mirrors the Go aggregator: a cell is either priced from tokens or costed
from a vendor-reported dollar. The cache bumps to v5 because a v4 cell
has nowhere to keep that dollar and would restore as \$0.00."
```

---

## Task 8: The Swift Grok reader and AppState wiring

Mirror of Tasks 3 and 4.

**Files:**
- Create: `macapp/Sources/ClaudeCounterCore/GrokReader.swift`
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/grok_updates.jsonl` (copy of the Go fixture, byte-identical)
- Modify: `macapp/Sources/ClaudeCounterCore/Reader.swift` (per-vendor dispatch in the scan/change paths)
- Test: `macapp/Tests/ClaudeCounterCoreTests/GrokReaderTests.swift`

**Interfaces:**
- Consumes: `UsageEvent`'s four new fields from Task 7.
- Produces:
  - `protocol VendorParser { func walkable(_ name: String) -> Bool; func parse(_ line: Data, path: String) -> ParseResult2; func project(_ path: String) -> String; func isSubagent(_ path: String) -> Bool }`
  - `enum ParseResult2 { case events([UsageEvent]); case parseError }` — plural because one Grok line yields several
  - `func parserFor(vendor: String) -> VendorParser`
  - `struct GrokParser: VendorParser`, `struct ClaudeParser: VendorParser`
  - `func grokProjectKey(_ path: String) -> String`

- [ ] **Step 1: Copy the fixture**

```bash
cp tui/internal/reader/testdata/grok_updates.jsonl \
   macapp/Tests/ClaudeCounterCoreTests/Fixtures/grok_updates.jsonl
```

Byte-identical on purpose: the two parsers must agree line for line, and a
diverging fixture would hide exactly the disagreement the parity suite exists to
catch.

- [ ] **Step 2: Write the failing test**

Create `macapp/Tests/ClaudeCounterCoreTests/GrokReaderTests.swift` with the Swift
equivalents of every assertion in `tui/internal/reader/grok_test.go`:
`test_grokParser_emitsOneEventPerModelPlusOneCoverageEvent`,
`test_grokParser_tokenAndCostMapping`,
`test_grokParser_topLevelTotalsNeverAddedOnTopOfModelUsage`,
`test_grokProjectKey_matchesClaudeEncoding`,
`test_grokParser_walkableOnlyMatchesUpdatesJSONL`,
`test_grokParser_isSubagent`.

Load the fixture with the same helper the existing `ReaderTests` use for
`session_normal.jsonl` — read that file first and match it rather than inventing
a new loader. Use the same numeric expectations as the Go test: input
`210887 - 158592`, cacheRead `158592`, output `5833`, cacheCreate `0`,
`costUSD == 0.3721028`, `p3` total `3.00`, project `-Users-me-src-proj`.

- [ ] **Step 3: Run it to verify it fails**

Run: `cd macapp && swift test --filter GrokReaderTests`
Expected: FAIL — `cannot find 'GrokParser' in scope`.

- [ ] **Step 4: Implement `GrokReader.swift`**

Port `tui/internal/reader/grok.go` field for field, keeping the comments (they
carry the *why*, which is what stops a future edit from re-introducing the
double-count). Key points, all identical to Go:

- `nanoDollarsPerUSD = 1e9`
- `walkable` matches only `"updates.jsonl"`
- one coverage event per `turn_completed`, then one usage event per `modelUsage`
  entry, falling back to the top-level totals under model `"grok"` only when
  `modelUsage` is empty
- `messageID = prompt_id`, `requestID = model`
- token mapping with the saturating subtraction
- `grokProjectKey`: percent-decode the session directory then replace `/` and `.`
  with `-`, using `removingPercentEncoding`

Add `ClaudeParser` wrapping the existing `parseLine`, and `parserFor(vendor:)`.

- [ ] **Step 5: Route the scan through the dispatch**

In `Reader.swift`, wherever the scan filters on the `.jsonl` extension and
wherever it calls `parseLine`, take the parser from the source's vendor instead —
the same change as Go's Task 4. Read the file's existing scan entry points first
and thread the vendor through them.

- [ ] **Step 6: Run the tests**

Run: `cd macapp && swift test`
Expected: PASS.

- [ ] **Step 7: Verify in the real app**

```bash
cd macapp && ./scripts/build-app.sh && open ./.build/ClaudeCounterBar.app
```

Expected: the popover's "By model · month" table lists a `grok-*` row with a
non-zero dollar figure; cycling the grouping control to `vendor` shows `claude`
and `grok` as two rows; the monthly and hourly charts show a Grok-coloured
segment.

- [ ] **Step 8: Commit**

```bash
git add macapp/Sources/ClaudeCounterCore/GrokReader.swift \
        macapp/Sources/ClaudeCounterCore/Reader.swift \
        macapp/Tests/ClaudeCounterCoreTests/GrokReaderTests.swift \
        macapp/Tests/ClaudeCounterCoreTests/Fixtures/grok_updates.jsonl
git commit -m "feat(macapp): Grok reader behind a per-vendor parser dispatch

Byte-identical fixture to the Go suite so the two parsers cannot drift."
```

---

## Task 9: Cross-language parity, the coverage marker in the popover, and docs

The parity harness pins the budget engines and the grouping modes. A costed cell
is a third thing the two languages can disagree about, and a disagreement there
would make the two apps report different dollars for the same Grok month.

**Files:**
- Create: `tui/internal/agg/testdata/costed_parity.json`
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/costed_parity.json` (byte-identical)
- Modify: `tui/internal/agg/grouping_parity_test.go` (or a new `costed_parity_test.go` alongside it)
- Modify: `macapp/Tests/ClaudeCounterCoreTests/GroupingParityTests.swift` (or a new file alongside)
- Modify: `macapp/Sources/ClaudeCounterCore/Grouping.swift`, `macapp/Sources/ClaudeCounterBar/PopoverView.swift`
- Modify: `README.md`, `docs/superpowers/specs/2026-08-10-multi-vendor-usage-design.md`

**Interfaces:**
- Consumes: everything above.
- Produces: `Grouping.groupCoverage(_ input: [SeriesKey: ModelDay], coverage: [String: Coverage], by mode: GroupMode) -> [String: Coverage]` — the Swift mirror of `agg.GroupCoverage`, same worst-vendor rule.

- [ ] **Step 1: Write the shared fixture**

Create `tui/internal/agg/testdata/costed_parity.json`. Follow the exact shape of
the existing `grouping_parity` fixture — read it first — and add a costed vendor
alongside the priced one. It must contain: two Claude models under one source,
two Grok models under a Grok source, one Grok turn whose `modelUsage` has two
entries, and a coverage tally of 20 usage-bearing turns out of 100. Expected
outputs to pin: month USD per `SeriesKey`, the four grouping modes' totals, the
daily-window USD for the fixture's day, and `coverage["grok"].fraction == 0.2`.

- [ ] **Step 2: Write the failing parity tests in both languages**

Both read the same JSON, drive their own aggregator, and assert the pinned
expected values. Mirror the structure of the existing grouping-parity tests
rather than inventing a new harness.

- [ ] **Step 3: Run them to verify they fail, then make them pass**

Run: `cd tui && go test ./internal/agg/ -run Parity -v`
Run: `cd macapp && swift test --filter Parity`
Expected: both FAIL on the missing fixture, then both PASS once it exists and the
expectations are filled in from a hand-computed value — **not** from whichever
implementation you ran first, which would pin a bug into the fixture.

- [ ] **Step 4: Mirror `GroupCoverage` in Swift and mark the popover**

Add to `macapp/Sources/ClaudeCounterCore/Grouping.swift`, mirroring
`agg.GroupCoverage` including the worst-vendor rule and its comment:

```swift
    /// Collapses per-vendor coverage onto the same display rows `group`
    /// produces, so the two dictionaries always share a key set — a row
    /// without an entry would silently render unmarked.
    ///
    /// A row spanning several vendors takes the worst of them. Averaging,
    /// or weighting by spend, would let a large complete Claude figure
    /// hide a small partial Grok one inside the same row, which is
    /// exactly the failure this marker exists to prevent. Mirrors
    /// `agg.GroupCoverage` in `tui/internal/agg/group.go`.
    public static func groupCoverage(_ input: [SeriesKey: ModelDay],
                                     coverage: [String: Coverage],
                                     by mode: GroupMode) -> [String: Coverage] {
        var out: [String: Coverage] = [:]
        for key in input.keys {
            let name = mode.seriesName(for: key)
            let c = coverage[key.vendor] ?? Coverage()
            if let cur = out[name], cur.fraction <= c.fraction { continue }
            out[name] = c
        }
        return out
    }
```

`seriesName(for:)` is currently `fileprivate` — that is fine, this extension
lives in the same file.

Add a test in `GroupingTests.swift` asserting the same three things the Go test
does: a `total` row spanning both vendors reads partial, a `vendor` row for
`claude` does not, and the key set matches `group`'s.

In `PopoverView.swift`, render the marker on a partial row, matching the TUI's
` ~20%` form. Use the existing secondary/dimmed text style rather than declaring
a new one.

- [ ] **Step 5: Update the README**

Two edits:

1. The comparison table and the vendor section must say Grok spend is now counted
   and that its dollars are vendor-reported rather than computed from the pricing
   table.
2. Document `sources.toml` auto-discovery: `~/.grok/sessions` is picked up with no
   configuration when it exists, and the coverage marker means the figure is a
   floor because Grok only recently began emitting usage.

- [ ] **Step 6: Mark Phase B done in the spec**

In `docs/superpowers/specs/2026-08-10-multi-vendor-usage-design.md`, update the
status line to note Phase B has shipped and Phase C (Codex) is next.

- [ ] **Step 7: Full verification**

```bash
make test
cd tui && go run ./cmd/claudecounter --once
```

Expected: all tests pass; `--once` prints Grok rows with non-zero dollars.

- [ ] **Step 8: Commit**

```bash
git add tui/internal/agg/testdata/costed_parity.json tui/internal/agg/*_parity_test.go \
        macapp/Tests/ClaudeCounterCoreTests/Fixtures/costed_parity.json \
        macapp/Tests/ClaudeCounterCoreTests/*Parity*.swift \
        macapp/Sources/ClaudeCounterBar/PopoverView.swift \
        README.md docs/superpowers/specs/2026-08-10-multi-vendor-usage-design.md
git commit -m "test: cross-language parity for costed cells and coverage

Plus the popover coverage marker and the README correction. A costed
cell is a third thing the two languages could disagree about; the
fixture pins it the way grouping and budgets are already pinned."
```

---

## Follow-up: Phase C (Codex)

Codex gets its own plan once this lands. Its four open items, from the spec's
*Deferred* section, plus one this plan's probing turned up:

1. Sum `last_token_usage` deltas; summing overshoots the session's own
   `total_token_usage` by 0.3–0.7% without dedupe.
2. **The spec names `eventId` as the dedupe key, and it is not there.** A live
   `token_count` line (verified 2026-08-15) is exactly
   `{timestamp, type, payload}` with no id at any level. The Codex plan must
   settle on a real key — most likely `(session file, timestamp)` — before any
   parser is written.
3. Model resolution via `event_msg → thread_settings_applied → thread_settings.model`
   (confirmed present: `"model":"gpt-5.6-sol"`). `turn_context` carries no model.
4. Widen `pricing.Fetch`'s LiteLLM parse past Anthropic. LiteLLM already carries
   OpenAI models, so this is a filter change, not a new data source.
5. `codex-auto-review` has no pricing entry and lands in `agg`'s `Unknown`
   counter. Unlike Grok, Codex is **priced**, not costed — it reports tokens, not
   dollars — so it uses the path that already exists rather than Task 1's.

Also required for Codex: add `"codex"` to `knownVendors` in **both**
`tui/internal/sources/sources.go:24` and
`macapp/Sources/ClaudeCounterCore/Sources.swift:78`, add it to `discoverable`
(`~/.codex/sessions`), and add it to the vendor picker in `SourcesEditorView.swift`.
Until then a hand-written `vendor = "codex"` is rejected at load.
