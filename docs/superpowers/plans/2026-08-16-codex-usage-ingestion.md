# Codex Usage Ingestion Implementation Plan (Phase C)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Codex spend appears in the per-model table and the charts alongside Claude and Grok, on both surfaces.

**Architecture:** Codex is *priced*, not costed — it reports tokens and the dollars come from the pricing table, exactly like Claude. So no new aggregator capability is needed; Phase B's costed path is untouched. Three things are: the pricing table must admit OpenAI models (and a stale cache must be refetched, or the widening is invisible), a Codex reader must turn cumulative `total_token_usage` into per-turn deltas, and `codex` must be wired in as a vendor everywhere `claude` and `grok` already are.

**Tech Stack:** Go 1.x (`tui/`), Swift 6 / SwiftUI (`macapp/`).

**Spec:** `docs/superpowers/specs/2026-08-16-codex-usage-design.md` — read it. It records the empirical findings this plan assumes, including two corrections to the earlier multi-vendor spec.

## Global Constraints

- **Nothing here may break Claude or Grok counting.** Every failure degrades to "fewer cells", never to a wrong number. Both suites must stay green: Go all packages, Swift 250 tests.
- **Both surfaces must agree.** `README.md` promises the TUI and menu bar "produce identical numbers".
- **Codex is priced, not costed.** A Codex event sets no `CostUSD`/`Costed`; it goes through the pricing table like Claude. Do not touch `cellVal.CostedUSD` / `CellValue.costedUSD`.
- **Deltas of `total_token_usage`, never sums of `last_token_usage`.** Summing overshoots by 0.86% corpus-wide. A delta is `current − previous` within one session file; the first event's delta is its own value. **Never emit a negative delta** — a decrease means a restart, so adopt the new value as the running total and contribute nothing.
- **Token mapping, per delta:** `In = input_tokens − cached_input_tokens` (saturating at 0), `CacheRead = cached_input_tokens`, `Out = output_tokens`, `CacheCreate = 0`. `reasoning_output_tokens` is never added on top.
- **Model resolution:** the most recent preceding `thread_settings_applied.model`. If the session declares none, fall back on `session_meta.payload.parent_thread_id` — absent → `gpt-5.6-sol`, present → `codex-auto-review`. A declared model is never overridden.
- **`codex-auto-review` prices as `gpt-5.6-luna`** ($0.20/Mtok in, $1.20/Mtok out — owner-confirmed and LiteLLM-verified). The alias affects pricing only; the displayed model name stays `codex-auto-review`.
- **Day attribution:** a delta belongs to the local day of the **closing** event.
- **Project key:** from `session_meta.payload.cwd`, with every `/` and `.` replaced by `-` — the Claude encoding. Codex's directory layout is dated, not project-keyed, so the path carries no project information.
- **Subagent:** `IsSubagent` is `parent_thread_id` present.
- Comment density and naming follow the surrounding code — long "why" comments on non-obvious decisions.

## Consumer inventory — read before starting

Phase B shipped a feature that was dead in the macapp because a consumer of the vendor list was never put on a task's file list. Every consumer is enumerated here; each is on a task or explicitly out of scope.

| Consumer | Task | Note |
|---|---|---|
| `tui/internal/sources/sources.go` — `knownVendors`, `discoverable` | 3 | |
| `tui/internal/reader/vendor.go` — `parserFor` | 3 | |
| `tui/internal/pricing/fetch.go` — `parseLiteLLM` | 1 | |
| `tui/cmd/claudecounter/main.go` — `loadPricing` | 1 | stale-cache refetch |
| `macapp/.../Sources.swift` — `knownVendors`, `discoverable` | 5 | |
| `macapp/.../Reader.swift` — `parserFor` | 5 | |
| `macapp/.../PricingFetch.swift` | 4 | |
| `macapp/.../AppState.swift` — `resolveSources` | 5 | already routes through `Sources.defaults` since `eef9e14`; **task 5 must prove it with an AppState-level test**, not assume it |
| `macapp/Sources/ClaudeCounterBar/SourcesEditorView.swift` — vendor picker | 5 | currently `["claude", "grok"]` |
| `SessionTracker.swift`, `LiveEventBuffer.swift` | — | **out of scope**: both already handle priced events; Codex sets no `costed` flag so their existing pricing path is correct |
| `agg` / `Aggregator` costed machinery | — | **out of scope**: Codex is priced |
| Grok's coverage marker | — | **out of scope**: 100% of Codex tokens are priceable |

---

## Task 1: Admit OpenAI models to the pricing table, and refetch a stale cache

Widening the parse is necessary but **not sufficient**: `loadPricing` (`main.go:872`) prefers a cached `pricing.toml` and only fetches when it is missing or `--refresh` is passed. A user whose cache predates this change would keep an Anthropic-only table and see Codex priced at $0 — correct code, invisible in practice. This task does both halves.

**Files:**
- Modify: `tui/internal/pricing/fetch.go` (`parseLiteLLM`, `SaveTOML`)
- Modify: `tui/internal/pricing/pricing.go` (schema marker on load)
- Modify: `tui/cmd/claudecounter/main.go:872-890` (`loadPricing`)
- Test: `tui/internal/pricing/fetch_test.go`, `tui/internal/pricing/pricing_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `pricing.TableSchema = 2` (const), `pricing.Table.Schema int`, `pricing.Load` populating it, `SaveTOML` emitting `# schema = 2`.

- [ ] **Step 1: Write the failing tests**

In `fetch_test.go`, add a test that feeds `parseLiteLLM` a JSON blob containing one `anthropic` entry, one `openai` entry (`gpt-5.6-sol`, with all four cost fields), one `openai` entry with zero costs, and one `azure` entry — asserting both the Anthropic and the OpenAI model survive, the zero-cost and azure entries do not, and the Anthropic model's four rates are unchanged from today.

In `pricing_test.go`, add a test that `Load` on a TOML file with no `# schema` line reports `Schema == 0` (a pre-widening cache), and on one with `# schema = 2` reports `2`.

- [ ] **Step 2: Run them and confirm they fail**

Run: `cd tui && go test ./internal/pricing/ -run 'OpenAI|Schema' -v`
Expected: FAIL — the OpenAI entry is filtered out; `Schema` is undefined.

- [ ] **Step 3: Widen the parse**

In `parseLiteLLM`, replace the Anthropic-only guard:

```go
		// Anthropic and OpenAI both. Verified against the live LiteLLM
		// table: 26 anthropic and 145 openai entries survive the
		// non-zero-cost filter below, with no name collisions between
		// the two sets and no "/"-containing OpenAI names — so the
		// prefix-strip below needs no OpenAI equivalent.
		//
		// Caveat worth knowing: 52 of those OpenAI entries omit
		// cache_read_input_token_cost, which unmarshals to 0 and would
		// price cached reads free. Neither model Codex currently uses
		// (gpt-5.6-sol, gpt-5.6-luna) is among them, but cached reads
		// dominate Codex volume, so a future model landing in that set
		// would under-report rather than fail loudly.
		if !strings.EqualFold(e.Provider, "anthropic") && !strings.EqualFold(e.Provider, "openai") {
			continue
		}
```

Change the final emptiness check's message from "no anthropic models" to "no priced models".

- [ ] **Step 4: Add the schema marker**

In `pricing.go`, add `const TableSchema = 2` with a comment explaining that the number exists so a cache written before a parser widening is refetched rather than silently serving a table missing a whole provider. Add `Schema int` to `Table`, and have `Load` parse a leading `# schema = N` comment (absent → 0).

In `SaveTOML`, emit `# schema = 2` in the header.

- [ ] **Step 5: Refetch a stale cache**

In `loadPricing`, change the cache-hit condition so a cached table below the current schema is treated as a miss:

```go
	if !refresh {
		if t, err := pricing.Load(path); err == nil && len(t.Models) > 0 && t.Schema >= pricing.TableSchema {
			return t, ""
		} else if err == nil && len(t.Models) > 0 {
			// A cache written before the parser learned a provider is
			// not wrong, just incomplete — it would price every model
			// from the missing provider at zero, silently. Refetch once;
			// SaveTOML stamps the new schema so this happens only once.
			log.Printf("pricing: cache at %s predates schema %d; refetching", path, pricing.TableSchema)
		} else if err != nil && !errors.Is(err, fs.ErrNotExist) {
			log.Printf("pricing: %s unreadable (%v); falling back", path, err)
		}
	}
```

- [ ] **Step 6: Run the tests**

Run: `cd tui && go test ./internal/pricing/ ./cmd/claudecounter/ -v`
Expected: PASS.

Run: `cd tui && go test ./...`
Expected: PASS.

- [ ] **Step 7: Verify against the live table**

Run: `cd tui && go run ./cmd/claudecounter --refresh --once 2>&1 | head -5`
Then: `grep -c 'gpt-5' ~/.config/claudecounter/pricing.toml`
Expected: a non-zero count, and a `# schema = 2` line at the top of that file.

- [ ] **Step 8: Commit**

```bash
git add tui/internal/pricing/ tui/cmd/claudecounter/main.go
git commit -m "feat(pricing): admit OpenAI models, refetch a pre-widening cache

Widening parseLiteLLM alone is invisible to anyone with a cached
pricing.toml — loadPricing prefers the cache. A schema marker makes a
pre-widening cache a miss exactly once."
```

---

## Task 2: The Codex reader

**Files:**
- Create: `tui/internal/reader/codex.go`
- Create: `tui/internal/reader/testdata/codex_rollout.jsonl`
- Test: `tui/internal/reader/codex_test.go`

**Interfaces:**
- Consumes: `vendorParser` (`Walkable`, `Parse`, `Project`, `IsSubagent`) from Phase B, with the root parameter added in `eb0c323`.
- Produces: `codexParser` (a **stateful** parser — see below), `codexModelForSession`, `aliasedPricingModel(model string) string`.

**A structural difference from the other two parsers.** `claudeParser` and `grokParser` are stateless: a line yields its events without reference to any other line. Codex cannot be — a delta needs the previous cumulative total, the model needs the last `thread_settings_applied`, and the project needs `session_meta` from the top of the file. `codexParser` therefore carries per-file state and **must be reset per file**. `Parse` is called line-by-line in file order by `OnChange`; the reset hook is added in Task 3. Note `OnChange` may be called repeatedly on a growing file, resuming mid-file from a byte offset — the state must survive across those calls for the same path and reset only when the path changes or the file shrinks.

- [ ] **Step 1: Create the fixture**

`tui/internal/reader/testdata/codex_rollout.jsonl`, one JSON object per line:

```
{"timestamp":"2026-08-09T08:34:15.910Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/proj","originator":"codex-tui"}}
{"timestamp":"2026-08-09T08:34:16.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoning_output_tokens":40,"total_tokens":1100}}}}
{"timestamp":"2026-08-09T08:35:00.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.6-sol","model_provider_id":"openai"}}}
{"timestamp":"2026-08-09T08:36:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":1400,"output_tokens":300,"reasoning_output_tokens":90,"total_tokens":3300}}}}
{"timestamp":"2026-08-09T08:36:30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":1400,"output_tokens":300,"reasoning_output_tokens":90,"total_tokens":3300}}}}
{"timestamp":"2026-08-09T08:37:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":1,"total_tokens":11}}}}
{"timestamp":"2026-08-09T08:38:00.000Z","type":"turn_context","payload":{"turn_id":"t1","cwd":"/Users/me/src/proj"}}
{not json
```

Line 2 is a first `token_count` with no model yet declared. Line 3 declares the model. Line 4 is a second reading — its delta is the difference. Line 5 **repeats line 4's totals exactly** (the duplicate case; delta must be zero). Line 6 **decreases** (the restart case; must contribute nothing and reset the running total). Line 7 is a non-usage line. Line 8 is malformed.

- [ ] **Step 2: Write the failing tests**

Create `tui/internal/reader/codex_test.go` (`package reader`). Assertions:

- `TestCodexParser_DeltasTelescope` — the events from lines 2 and 4 carry `Out` of 100 and 200 respectively (300 − 100), and `In` of 600 (1000−400) and 1000 (1600−600 uncached delta). Compute the expected values from the fixture by hand and state them literally.
- `TestCodexParser_DuplicateReadingYieldsNoEvent` — line 5 produces no usage event.
- `TestCodexParser_DecreaseYieldsNoNegativeDelta` — line 6 produces no usage event, and a subsequent higher reading would delta from 11, not from 3300. Add a line 9 to the fixture if needed to assert the second half, or assert the parser's internal running total via a follow-up `Parse` call.
- `TestCodexParser_ModelFallsBackBeforeFirstDeclaration` — the line-2 event's model is `gpt-5.6-sol` (no `parent_thread_id` in `session_meta`), and the line-4 event's is also `gpt-5.6-sol` (declared).
- `TestCodexParser_ParentThreadIdImpliesAutoReview` — a second fixture, or a modified copy in the test, whose `session_meta` carries `parent_thread_id` and which declares no model, yields `codex-auto-review` and `IsSubagent == true`.
- `TestCodexParser_ProjectFromSessionMetaCwd` — project is `-Users-me-src-proj`.
- `TestCodexParser_MalformedLineIsAParseError` — exactly one parse error.
- `TestAliasedPricingModel` — `codex-auto-review` maps to `gpt-5.6-luna`; every other name maps to itself.

- [ ] **Step 3: Run them and confirm they fail**

Run: `cd tui && go test ./internal/reader/ -run Codex -v`
Expected: FAIL — `undefined: codexParser`.

- [ ] **Step 4: Implement `codex.go`**

Key elements, matching the surrounding code's comment style:

```go
// codexAliases maps a Codex-internal model name to the LiteLLM model
// whose rates it actually bills at. Codex's auto-review runs on GPT-5.6
// Luna ($0.20/Mtok in, $1.20/Mtok out) — owner-confirmed and matching
// LiteLLM's gpt-5.6-luna entry exactly. The alias affects pricing only;
// the model name the user sees stays codex-auto-review.
//
// This is data rather than logic because the model behind auto-review is
// a moving target: a future Codex release changes this map, not the
// reader.
var codexAliases = map[string]string{"codex-auto-review": "gpt-5.6-luna"}

// codexFallbackModel resolves the model for a session that never emits
// thread_settings_applied — 25 of 74 files in the corpus probed on
// 2026-08-16, from an older CLI. parent_thread_id discriminates them
// exactly: across all 49 sessions that DO declare, no-parent always
// meant gpt-5.6-sol (25 files) and has-parent always meant
// codex-auto-review (24 files), with zero exceptions.
//
// Data, not logic, for the same reason as codexAliases.
var codexFallbackModel = map[bool]string{false: "gpt-5.6-sol", true: "codex-auto-review"}
```

The token mapping is per-delta with a saturating subtraction, identical in shape to `grokUsage.toUsage`. The delta rule:

```go
	// total_token_usage is cumulative per session and was verified
	// monotonic in 69 of 69 corpus files, so consecutive differences
	// telescope to the session's final total exactly. Summing
	// last_token_usage instead overshoots it by 0.86% corpus-wide,
	// which is what the superseded design tried to fix with a dedupe
	// key that does not exist in the data.
	//
	// A repeated reading yields a zero delta and is dropped, which is
	// why no dedupe key is needed. A decrease means the session
	// restarted its counter: adopt the new value and contribute
	// nothing, because a negative cell would be a wrong number rather
	// than a missing one.
```

`Walkable` matches `strings.HasPrefix(name, "rollout-") && strings.HasSuffix(name, ".jsonl")`.

`Project` returns the encoded `cwd` captured from `session_meta`; `IsSubagent` returns whether `parent_thread_id` was present. Both read the parser's per-file state rather than the path — Codex's layout is dated, not project-keyed. Document that divergence from the other two parsers.

- [ ] **Step 5: Run the tests**

Run: `cd tui && go test ./internal/reader/ -v`
Expected: PASS, including every pre-existing Claude and Grok test.

- [ ] **Step 6: Commit**

```bash
git add tui/internal/reader/codex.go tui/internal/reader/codex_test.go tui/internal/reader/testdata/codex_rollout.jsonl
git commit -m "feat(reader): Codex parser over cumulative-total deltas

Deltas of total_token_usage telescope exactly and make a duplicate
reading a no-op, which is why the missing eventId stops mattering."
```

---

## Task 3: Wire `codex` in as a vendor (Go)

**Files:**
- Modify: `tui/internal/sources/sources.go` (`knownVendors`, `discoverable`)
- Modify: `tui/internal/reader/vendor.go` (`parserFor`), `tui/internal/reader/reader.go` (per-file parser state reset)
- Test: `tui/internal/sources/sources_test.go`, `tui/internal/reader/reader_test.go`

**Interfaces:**
- Consumes: `codexParser` from Task 2.
- Produces: `parserFor("codex")` returning a fresh `*codexParser`; `sources.Defaults` discovering `~/.codex/sessions`.

- [ ] **Step 1: Write the failing tests**

- `TestDefaults_DiscoversCodexWhenPresent` — mirrors the Grok test: a home with `.codex/sessions` yields a third source, Claude still first.
- `TestLoad_AcceptsCodexVendor` — a `sources.toml` with `vendor = "codex"` loads without error.
- `TestInitialScanSource_CodexEndToEnd` — a temp root laid out as `<root>/2026/08/09/rollout-x.jsonl` holding the Task 2 fixture, scanned via `InitialScanSource` with `sources.Source{Vendor: "codex", ...}`, yields the expected usage events tagged `codex/codex`, with the project key from `cwd` and no negative deltas.
- `TestCodexParserState_ResetsBetweenFiles` — two rollout files under one root, the second with *lower* cumulative totals than the first; assert the second file's events are not deltas against the first file's running total. This is the test that catches a missing reset, and a missing reset silently drops a whole file's spend.

- [ ] **Step 2: Run them and confirm they fail**

Run: `cd tui && go test ./internal/sources/ ./internal/reader/ -run 'Codex' -v`
Expected: FAIL — unknown vendor; no codex discovery.

- [ ] **Step 3: Implement**

Add `"codex": true` to `knownVendors` and `{vendor: "codex", segments: []string{".codex", "sessions"}}` to `discoverable`.

Add the `codex` case to `parserFor`. Because `codexParser` is stateful, `parserFor` must return a **fresh instance per file**, and `OnChange` must reset it when the path changes or the file shrinks. Read `OnChange` — it already detects `stat.Size() < start` for truncation — and hook the reset there, keyed on path. State that the other two parsers are stateless and unaffected.

- [ ] **Step 4: Run the tests**

Run: `cd tui && go test ./...`
Expected: PASS.

- [ ] **Step 5: Verify against the live corpus**

Run: `cd tui && go run ./cmd/claudecounter --once`
Expected: a `scanning …/.codex/sessions (codex/codex) …` line, and `gpt-5.6-sol` plus `codex-auto-review` rows with non-zero dollars. Against the corpus probed on 2026-08-16 the all-time figures were $835.67 and $6.57; the month figures will be smaller. Report what you see.

- [ ] **Step 6: Commit**

```bash
git add tui/internal/sources/ tui/internal/reader/
git commit -m "feat(sources): discover and scan a Codex install"
```

---

## Task 4: Admit OpenAI models to the Swift pricing fetch

Mirror of Task 1. Small and independent, so it lands before the larger Swift work.

**Files:**
- Modify: `macapp/Sources/ClaudeCounterCore/PricingFetch.swift`, and whichever type owns the cached-table load (read `Pricing.swift` and the `AppState` pricing wiring first to find the cache path — the Go side's stale-cache trap has a Swift equivalent and it must be closed too).
- Test: `macapp/Tests/ClaudeCounterCoreTests/PricingFetchAndTOMLTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a parse admitting `openai`, and the Swift equivalent of the schema marker.

- [ ] **Step 1: Read the Go implementation from Task 1**, then write the mirrored failing tests: an OpenAI entry survives the parse with all four rates, the Anthropic set is unchanged, an azure entry does not survive, and a cached table below the current schema is refetched.

- [ ] **Step 2: Run them, confirm they fail, implement, confirm they pass.**

Run: `cd macapp && swift test --filter Pricing`

- [ ] **Step 3: Report explicitly** whether the macapp actually has a persisted pricing cache with the same staleness hazard, and what you did about it. If it fetches fresh every launch, say so — that is a valid answer and means only the parse changes.

- [ ] **Step 4: Commit**

```bash
git add macapp/Sources/ClaudeCounterCore/ macapp/Tests/
git commit -m "feat(macapp): admit OpenAI models to the pricing fetch"
```

---

## Task 5: The Swift Codex reader and vendor wiring

**Files:**
- Create: `macapp/Sources/ClaudeCounterCore/CodexReader.swift`
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/codex_rollout.jsonl` (byte-identical copy of the Go fixture)
- Modify: `macapp/Sources/ClaudeCounterCore/Sources.swift` (`knownVendors`, `discoverable`), `Reader.swift` (`parserFor`, per-file state reset)
- Modify: `macapp/Sources/ClaudeCounterBar/SourcesEditorView.swift` (vendor picker)
- Test: `macapp/Tests/ClaudeCounterCoreTests/CodexReaderTests.swift`, `SourcesTests.swift`, `AppStateTests.swift`

**Interfaces:**
- Consumes: Task 4's pricing; the Go implementation as the specification.
- Produces: `CodexParser`, `codexAliases`, `codexFallbackModel`, `parserFor(vendor: "codex")`.

- [ ] **Step 1: Copy the fixture byte-identically** from `tui/internal/reader/testdata/codex_rollout.jsonl` and say how you verified (`shasum -a 256` on both).

- [ ] **Step 2: Write the failing tests** — the Swift equivalent of every assertion in `codex_test.go`, using the same literal numbers, plus:

**`test_appState_discoversCodexWithNoSourcesToml`** — construct an `AppState` with no `sources.toml` and a temp `home` containing `.codex/sessions`, call `start()`, and assert `app.sources` contains a `codex` entry. **This test is mandatory.** Phase B shipped Grok dead in the macapp because `Sources.defaults` was tested in isolation while nothing asserted `AppState` reached it; `eef9e14` fixed that path, and this test is what proves it still holds for a third vendor.

**`test_codexParserState_resetsBetweenFiles`** — the Swift mirror of the Go state-reset test.

- [ ] **Step 3: Run them, confirm they fail, implement, confirm they pass.**

Port `codex.go` field for field, comments included — they carry the *why*. Add `codex` to `knownVendors`, `discoverable`, `parserFor`, and the `SourcesEditorView` picker (currently `["claude", "grok"]`).

Run: `cd macapp && swift test`
Expected: PASS, 250 pre-existing plus the new ones.

- [ ] **Step 4: Build and verify against the real corpus**

```bash
cd macapp && ./scripts/build-app.sh release
```

Do **not** launch the app — the controller will handle that. Report that the build succeeds.

- [ ] **Step 5: Commit**

```bash
git add macapp/
git commit -m "feat(macapp): Codex reader and vendor wiring"
```

---

## Task 6: Parity, docs, and end-to-end verification

**Files:**
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/codex_parity.json` (single shared fixture, read by both languages — matches the `grouping_parity`/`limits_parity`/`costed_parity` precedent, which have no Go-side copy)
- Create: `tui/internal/agg/codex_parity_test.go`, `macapp/Tests/ClaudeCounterCoreTests/CodexParityTests.swift`
- Modify: `README.md`, `docs/superpowers/specs/2026-08-10-multi-vendor-usage-design.md`, `docs/superpowers/specs/2026-08-16-codex-usage-design.md`

- [ ] **Step 1: Write the parity fixture**, pinning a Codex month across two models (one aliased) in all four grouping modes, plus the per-project and daily figures. **Hand-compute every expected value from the fixture's inputs** — do not run one implementation and record its output, or the harness will certify both languages agreeing on a wrong answer. Show the arithmetic in your report.

- [ ] **Step 2: Write both parity suites**, mirroring the existing `costed_parity` pair. Confirm RED before the fixture exists, then GREEN.

- [ ] **Step 3: Update the README** — the comparison table and vendor section gain Codex; state that Codex spend is priced from the LiteLLM table (unlike Grok's vendor-reported dollars), that `~/.codex/sessions` is auto-discovered, and that `codex-auto-review` bills at GPT-5.6 Luna rates. Read the changed passages as a new user and check nothing overstates what ships.

- [ ] **Step 4: Mark the phases done** — set Phase C shipped in both spec documents' status lines.

- [ ] **Step 5: Full verification**

```bash
cd tui && go test ./... && go run ./cmd/claudecounter --once
cd macapp && swift test && ./scripts/build-app.sh release
```

Quote the `--once` per-model table in your report, including the Claude, Grok and Codex rows, so the three vendors can be seen side by side.

- [ ] **Step 6: Commit**

```bash
git add .
git commit -m "test: cross-language parity for Codex, plus docs"
```

## Follow-ups deliberately not in this plan

- Deleting `projectFromPath`, unused in production in both languages since `eb0c323`.
- The TUI marking day rows with the month-scoped coverage fraction.
