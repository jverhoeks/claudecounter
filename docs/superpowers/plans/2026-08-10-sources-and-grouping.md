# Sources and Grouping (Phase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user monitor more than one Claude subscription by configuring source roots, and view spend grouped by model, vendor, source or total in both apps.

**Architecture:** A new `sources` package turns a TOML file into a validated list of `(vendor, label, root)` triples, falling back to today's hardcoded roots when the file is absent. `reader.Event` and the aggregator's cell key gain `Vendor` and `Source`, so the per-model maps key on a `SeriesKey` instead of a bare model string. A pure `Group` function collapses that key by mode, and both surfaces render whichever grouping is selected.

**Tech Stack:** Go 1.25 (`github.com/BurntSushi/toml` — already a dependency), Swift 5.9 / macOS 13+, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-10-multi-vendor-usage-design.md` — implement the sections marked **[A]** only.

## Global Constraints

- **Nothing may break cost counting.** Every change here is additive to a working counting path. A user with no `sources.toml` must see byte-identical numbers to today.
- **`(vendor, label)` is the series identity**, rendered `vendor/label`. Labels must be unique *within* a vendor; the same label under different vendors is fine and must stay distinct.
- **Vendor and source come from the configured root a file was found under** — never inferred from the model name. Inference already fails on real data (`codex-auto-review`).
- **Vendor is stored alongside source, not derived from it at snapshot time.** The macapp persists cells between runs; a label removed from config would otherwise leave cached cells unattributable.
- **Phase A is Claude-only.** No Grok reader, no vendor-supplied cost, no coverage reporting — those are Phase B. The `vendor` grouping mode is built now and simply has one member.
- **Overlapping roots are rejected at load**, because an event under two roots would be counted twice.
- All Go tests run with `TZ=UTC` (the Makefile sets this). No dependency may be added, upgraded, or tidied.

## File structure

| File | Responsibility |
|---|---|
| `tui/internal/sources/sources.go` | `Source`, `Config`, `Load`, `Defaults`, validation |
| `tui/internal/agg/agg.go` | `SeriesKey`, cell key gains `Source`/`Vendor`, `Snapshot` |
| `tui/internal/agg/group.go` | `Mode`, `Group` — pure collapsing of `SeriesKey` |
| `tui/internal/reader/reader.go` | `Event.Vendor`/`Event.Source`, per-source scanning |
| `tui/internal/ui/group_view.go` | Rendering a grouped series list |
| `macapp/Sources/ClaudeCounterCore/Sources.swift` | Swift mirror of the loader |
| `macapp/Sources/ClaudeCounterCore/Grouping.swift` | Swift mirror of `Mode`/`Group` |
| `macapp/Sources/ClaudeCounterBar/SourcesEditorView.swift` | The GUI editor |

---

### Task 1: `sources` package — types, defaults, and loading

**Files:**
- Create: `tui/internal/sources/sources.go`
- Test: `tui/internal/sources/sources_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `sources.Source{Vendor, Label, Root string}` with method `ID() string` returning `"vendor/label"`; `sources.Config{Sources []Source}`; `sources.DefaultConfigPath() string`; `sources.Defaults(home string) []Source`; `sources.Load(path, home string) (Config, error)`.

- [ ] **Step 1: Write the failing test**

```go
package sources

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func write(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "sources.toml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// A missing file is the normal state: fall back to today's hardcoded
// roots so an existing user sees no change at all.
func TestLoadMissingFileYieldsDefaults(t *testing.T) {
	got, err := Load(filepath.Join(t.TempDir(), "absent.toml"), "/home/u")
	if err != nil {
		t.Fatalf("missing file must not error: %v", err)
	}
	want := Defaults("/home/u")
	if len(got.Sources) != len(want) || len(got.Sources) == 0 {
		t.Fatalf("got %+v, want defaults %+v", got.Sources, want)
	}
	if got.Sources[0] != want[0] {
		t.Fatalf("got %+v, want %+v", got.Sources[0], want[0])
	}
}

func TestDefaultsAreClaudeProjectsUnderHome(t *testing.T) {
	d := Defaults("/home/u")
	if len(d) != 1 {
		t.Fatalf("Phase A ships one default source, got %+v", d)
	}
	if d[0].Vendor != "claude" || d[0].Label != "claude" {
		t.Fatalf("got %+v", d[0])
	}
	if d[0].Root != "/home/u/.claude/projects" {
		t.Fatalf("Root = %q", d[0].Root)
	}
}

func TestIDIsVendorSlashLabel(t *testing.T) {
	s := Source{Vendor: "claude", Label: "work"}
	if s.ID() != "claude/work" {
		t.Fatalf("ID() = %q", s.ID())
	}
}

func TestLoadParsesAndExpandsTilde(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "work"
root   = "~/.claude/projects"

[[source]]
vendor = "claude"
label  = "personal"
root   = "~/.claude-personal/projects"
`)
	got, err := Load(p, "/home/u")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.Sources) != 2 {
		t.Fatalf("got %d sources", len(got.Sources))
	}
	if got.Sources[0].Root != "/home/u/.claude/projects" {
		t.Fatalf("tilde not expanded: %q", got.Sources[0].Root)
	}
	if got.Sources[1].ID() != "claude/personal" {
		t.Fatalf("ID = %q", got.Sources[1].ID())
	}
}

// The same label under different vendors is a legitimate configuration —
// they are distinct series and must not be rejected.
func TestLoadAllowsSameLabelAcrossVendors(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "personal"
root   = "~/.claude/projects"

[[source]]
vendor = "grok"
label  = "personal"
root   = "~/.grok/sessions"
`)
	if _, err := Load(p, "/home/u"); err != nil {
		t.Fatalf("same label across vendors must be allowed: %v", err)
	}
}

func TestLoadRejectsDuplicateLabelWithinVendor(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "work"
root   = "~/.claude/projects"

[[source]]
vendor = "claude"
label  = "work"
root   = "~/.other/projects"
`)
	_, err := Load(p, "/home/u")
	if err == nil {
		t.Fatal("duplicate (vendor,label) must be rejected — it would silently merge two subscriptions")
	}
	if !strings.Contains(err.Error(), "claude/work") {
		t.Fatalf("error should name the offending series, got %v", err)
	}
}

// Overlapping roots would count every event in the overlap twice.
func TestLoadRejectsNestedRoots(t *testing.T) {
	p := write(t, `
[[source]]
vendor = "claude"
label  = "outer"
root   = "~/.claude/projects"

[[source]]
vendor = "claude"
label  = "inner"
root   = "~/.claude/projects/sub"
`)
	if _, err := Load(p, "/home/u"); err == nil {
		t.Fatal("nested roots must be rejected — events in the overlap would double-count")
	}
}

func TestLoadRejectsUnknownVendorAndEmptyFields(t *testing.T) {
	for name, body := range map[string]string{
		"unknown vendor": "[[source]]\nvendor = \"openai\"\nlabel = \"x\"\nroot = \"~/x\"\n",
		"empty label":    "[[source]]\nvendor = \"claude\"\nlabel = \"\"\nroot = \"~/x\"\n",
		"empty root":     "[[source]]\nvendor = \"claude\"\nlabel = \"x\"\nroot = \"\"\n",
	} {
		if _, err := Load(write(t, body), "/home/u"); err == nil {
			t.Errorf("%s must be rejected", name)
		}
	}
}

func TestLoadMalformedReturnsError(t *testing.T) {
	if _, err := Load(write(t, "[[source]]\nvendor = = =\n"), "/home/u"); err == nil {
		t.Fatal("malformed TOML must error so a typo is not read as 'no sources'")
	}
}

// An empty but valid file means "no sources", which is different from
// "no file". It must not silently fall back to defaults.
func TestLoadEmptyFileYieldsNoSources(t *testing.T) {
	got, err := Load(write(t, "# nothing here\n"), "/home/u")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.Sources) != 0 {
		t.Fatalf("an empty file means no sources, got %+v", got.Sources)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/sources/ -v`
Expected: FAIL — `no Go files in .../internal/sources`.

- [ ] **Step 3: Write minimal implementation**

```go
// Package sources turns the user's sources.toml into a validated list of
// roots to scan. Each source pairs a vendor (which reader handles it)
// with a user-chosen label (which subscription or install it is).
//
// The root path is the only thing that can distinguish two Claude
// subscriptions: transcripts carry no account identifier, and the one in
// ~/.claude.json is machine-global and reflects whoever is logged in now.
package sources

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/BurntSushi/toml"
)

// knownVendors are the vendors a reader exists for. Phase A ships
// claude; grok is accepted so a user can configure it ahead of Phase B
// without the file failing to load.
var knownVendors = map[string]bool{"claude": true, "grok": true}

// Source is one configured root.
type Source struct {
	Vendor string
	Label  string
	Root   string
}

// ID is the series identity: vendor and label together. Two sources may
// share a label across vendors, so the label alone is not unique.
func (s Source) ID() string { return s.Vendor + "/" + s.Label }

type Config struct {
	Sources []Source
}

type tomlFile struct {
	Source []struct {
		Vendor string `toml:"vendor"`
		Label  string `toml:"label"`
		Root   string `toml:"root"`
	} `toml:"source"`
}

// DefaultConfigPath sits beside limits.toml so both surfaces read one
// directory.
func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "claudecounter", "sources.toml")
}

// Defaults is the implicit source list used when no config file exists:
// exactly today's hardcoded behaviour, so an existing user sees no
// change.
func Defaults(home string) []Source {
	return []Source{{
		Vendor: "claude",
		Label:  "claude",
		Root:   filepath.Join(home, ".claude", "projects"),
	}}
}

// Load reads sources.toml. A missing file yields Defaults(home) and no
// error — that is the normal unconfigured state. A malformed or invalid
// file returns an error so a typo is surfaced rather than silently
// read as "no sources".
func Load(path, home string) (Config, error) {
	if path == "" {
		return Config{Sources: Defaults(home)}, nil
	}
	var f tomlFile
	if _, err := toml.DecodeFile(path, &f); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Config{Sources: Defaults(home)}, nil
		}
		return Config{}, err
	}

	out := make([]Source, 0, len(f.Source))
	seen := map[string]bool{}
	for i, s := range f.Source {
		if !knownVendors[s.Vendor] {
			return Config{}, fmt.Errorf("source %d: unknown vendor %q", i, s.Vendor)
		}
		if s.Label == "" {
			return Config{}, fmt.Errorf("source %d: label must not be empty", i)
		}
		if s.Root == "" {
			return Config{}, fmt.Errorf("source %d: root must not be empty", i)
		}
		src := Source{Vendor: s.Vendor, Label: s.Label, Root: expand(s.Root, home)}
		if seen[src.ID()] {
			return Config{}, fmt.Errorf("duplicate source %s: two roots under one label would merge two subscriptions", src.ID())
		}
		seen[src.ID()] = true
		out = append(out, src)
	}
	if err := checkOverlap(out); err != nil {
		return Config{}, err
	}
	return Config{Sources: out}, nil
}

func expand(p, home string) string {
	if p == "~" {
		return home
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home, p[2:])
	}
	return filepath.Clean(p)
}

// checkOverlap rejects a root nested inside another. An event under both
// would be scanned twice and counted twice, which is a silent doubling of
// the user's spend.
func checkOverlap(ss []Source) error {
	for i := range ss {
		for j := range ss {
			if i == j {
				continue
			}
			a, b := ss[i].Root, ss[j].Root
			if a == b {
				return fmt.Errorf("sources %s and %s share the root %s", ss[i].ID(), ss[j].ID(), a)
			}
			if strings.HasPrefix(b, a+string(filepath.Separator)) {
				return fmt.Errorf("source %s root %s is nested inside source %s root %s: events would count twice", ss[j].ID(), b, ss[i].ID(), a)
			}
		}
	}
	return nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && TZ=UTC go test ./internal/sources/ -v`
Expected: PASS — 9 tests.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/sources/
git commit -m "feat(sources): configurable source roots from sources.toml

(vendor,label) is the series identity, so the same label under two
vendors stays distinct. Nested or duplicate roots are rejected at load —
an event under two roots would silently double a user's spend."
```

---

### Task 2: `reader` carries vendor and source

**Files:**
- Modify: `tui/internal/reader/reader.go` — `Event` struct at :18-28, `OnChange` at :115, `InitialScan` at :209
- Test: `tui/internal/reader/reader_test.go`

**Interfaces:**
- Consumes: `sources.Source` (Task 1).
- Produces: `reader.Event` gains `Vendor string` and `Source string` (the latter holding `Source.ID()`, i.e. `"vendor/label"`); `Reader.InitialScanSource(src sources.Source, notBefore time.Time) error`; `Reader.OnChangeSource(src sources.Source, path string) error`. The existing `InitialScan(root, notBefore)` and `OnChange(path)` remain, delegating with the Task 1 default source, so no existing caller breaks.

- [ ] **Step 1: Write the failing test**

Append to `tui/internal/reader/reader_test.go`:

```go
func TestInitialScanSourceTagsEvents(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "proj-a")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join("testdata", "session_normal.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "s.jsonl"), body, 0o644); err != nil {
		t.Fatal(err)
	}

	ch := make(chan Event, 256)
	r := New(ch)
	src := sources.Source{Vendor: "claude", Label: "work", Root: root}
	if err := r.InitialScanSource(src, time.Time{}); err != nil {
		t.Fatalf("InitialScanSource: %v", err)
	}
	close(ch)

	n := 0
	for e := range ch {
		n++
		if e.Vendor != "claude" {
			t.Fatalf("Vendor = %q, want claude", e.Vendor)
		}
		if e.Source != "claude/work" {
			t.Fatalf("Source = %q, want claude/work", e.Source)
		}
	}
	if n == 0 {
		t.Fatal("expected at least one event from the fixture")
	}
}

// The old single-root entry point must keep working unchanged, tagged
// with the default source, so existing callers see no behaviour change.
func TestInitialScanDefaultsToClaudeSource(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "proj-a")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(filepath.Join("testdata", "session_normal.jsonl"))
	_ = os.WriteFile(filepath.Join(dir, "s.jsonl"), body, 0o644)

	ch := make(chan Event, 256)
	r := New(ch)
	if err := r.InitialScan(root, time.Time{}); err != nil {
		t.Fatalf("InitialScan: %v", err)
	}
	close(ch)
	for e := range ch {
		if e.Vendor != "claude" || e.Source != "claude/claude" {
			t.Fatalf("default tagging wrong: vendor=%q source=%q", e.Vendor, e.Source)
		}
	}
}
```

Add `"github.com/jverhoeks/claudecounter/tui/internal/sources"` to that file's imports.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/reader/ -run TestInitialScan -v`
Expected: FAIL — `r.InitialScanSource undefined` and `e.Vendor undefined`.

- [ ] **Step 3: Write minimal implementation**

Add the two fields to `Event` (reader.go:18-28), with comments:

```go
	// Vendor is which tool produced this event ("claude"). It comes from
	// the configured root the file was found under, never from the model
	// name — inference already fails on real data (codex-auto-review).
	Vendor string
	// Source is the series identity "vendor/label", identifying which
	// subscription or install produced the event.
	Source string
```

Add a `src` field to `Reader` so `parse`-time tagging knows the current source, and the two new entry points. Keep the old ones delegating:

```go
// InitialScanSource walks one configured source's root, tagging every
// event with that source's vendor and identity.
func (r *Reader) InitialScanSource(src sources.Source, notBefore time.Time) error {
	r.mu.Lock()
	r.src = src
	r.mu.Unlock()
	return r.InitialScan(src.Root, notBefore)
}

// OnChangeSource handles a changed file belonging to a known source.
func (r *Reader) OnChangeSource(src sources.Source, path string) error {
	r.mu.Lock()
	r.src = src
	r.mu.Unlock()
	return r.OnChange(path)
}
```

Where the reader constructs an `Event`, set `e.Vendor = r.src.Vendor` and `e.Source = r.src.ID()`. Initialise `r.src` in `New` to `sources.Defaults(home)[0]` (use `os.UserHomeDir()`; on error use `sources.Source{Vendor: "claude", Label: "claude"}`) so `InitialScan` alone still tags correctly.

> **Note for the implementer:** read `OnChange` (reader.go:115) and `InitialScan` (reader.go:209) fully before editing. The reader already holds a mutex for its offset map — reuse it rather than adding a second. If the event construction happens in a helper that does not have the `*Reader`, pass the vendor/source down rather than reaching for a package-level variable.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && TZ=UTC go test ./internal/reader/ -v`
Expected: PASS — the two new tests plus all pre-existing reader tests.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/reader/
git commit -m "feat(reader): tag events with vendor and source

Both come from the configured root a file was found under. The old
single-root entry points remain and delegate with the default source, so
existing callers are unchanged."
```

---

### Task 3: aggregation key gains source and vendor

**Files:**
- Modify: `tui/internal/agg/agg.go` — `cellKey` at :90-95, `Totals` at :66-75, `Apply` at :126, `Snapshot` at :184-260
- Test: `tui/internal/agg/agg_test.go`

**Interfaces:**
- Consumes: `reader.Event.Vendor`/`.Source` (Task 2).
- Produces: `agg.SeriesKey{Source, Vendor, Model string}`; `Totals.Day` and `Totals.Month` become `map[SeriesKey]ModelDay`. `DayProj`/`MonthProj`/`Daily`/`Unknown`/`Dupes`/`AsOf` are unchanged.

- [ ] **Step 1: Write the failing test**

```go
func TestSnapshotKeysBySeries(t *testing.T) {
	a := NewWithClock(testTable(), func() time.Time {
		return time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	})
	base := time.Date(2026, 8, 10, 9, 0, 0, 0, time.UTC)

	// Same model, two different subscriptions.
	a.Apply(reader.Event{
		Timestamp: base, Project: "p", Model: "claude-opus-4-7",
		Vendor: "claude", Source: "claude/work",
		MessageID: "m1", RequestID: "r1",
		Usage: pricing.Usage{InputTokens: 1000, OutputTokens: 100},
	})
	a.Apply(reader.Event{
		Timestamp: base, Project: "p", Model: "claude-opus-4-7",
		Vendor: "claude", Source: "claude/personal",
		MessageID: "m2", RequestID: "r2",
		Usage: pricing.Usage{InputTokens: 2000, OutputTokens: 200},
	})

	snap := a.Snapshot()
	work := SeriesKey{Source: "claude/work", Vendor: "claude", Model: "claude-opus-4-7"}
	pers := SeriesKey{Source: "claude/personal", Vendor: "claude", Model: "claude-opus-4-7"}

	if len(snap.Day) != 2 {
		t.Fatalf("two sources must stay two series, got %d: %+v", len(snap.Day), snap.Day)
	}
	if snap.Day[work].Tokens.InputTokens != 1000 {
		t.Fatalf("work series wrong: %+v", snap.Day[work])
	}
	if snap.Day[pers].Tokens.InputTokens != 2000 {
		t.Fatalf("personal series wrong: %+v", snap.Day[pers])
	}
}

// Dedupe must still be by messageID:requestID and must not become
// per-source — the same message seen under two roots is still one event.
func TestDedupeIsUnaffectedBySource(t *testing.T) {
	a := NewWithClock(testTable(), func() time.Time {
		return time.Date(2026, 8, 10, 12, 0, 0, 0, time.UTC)
	})
	base := time.Date(2026, 8, 10, 9, 0, 0, 0, time.UTC)
	for _, src := range []string{"claude/work", "claude/personal"} {
		a.Apply(reader.Event{
			Timestamp: base, Project: "p", Model: "claude-opus-4-7",
			Vendor: "claude", Source: src,
			MessageID: "same", RequestID: "same",
			Usage: pricing.Usage{InputTokens: 1000},
		})
	}
	if a.Dupes() != 1 {
		t.Fatalf("Dupes = %d, want 1", a.Dupes())
	}
	snap := a.Snapshot()
	if len(snap.Day) != 1 {
		t.Fatalf("a deduped event must produce one series, got %+v", snap.Day)
	}
}
```

> **Note for the implementer:** `testTable()` may not exist in `agg_test.go`. Read the file first and reuse whatever helper the existing tests use to build a `pricing.Table` containing `claude-opus-4-7`; if none exists, add one.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/agg/ -run 'TestSnapshotKeysBySeries|TestDedupeIsUnaffected' -v`
Expected: FAIL — `undefined: SeriesKey`, and `Totals.Day` is `map[string]ModelDay`.

- [ ] **Step 3: Write minimal implementation**

Add `SeriesKey` and widen the cell key:

```go
// SeriesKey identifies one chartable series. Source and Vendor are both
// stored rather than Vendor being derived from Source at snapshot time:
// the macapp persists cells between runs, so a label removed from the
// config would otherwise leave its cached cells unattributable.
type SeriesKey struct {
	Source string // "vendor/label"
	Vendor string
	Model  string
}

type cellKey struct {
	Day     civilDay
	Project string
	Source  string
	Vendor  string
	Model   string
	IsSub   bool
}
```

Change `Totals.Day`/`Totals.Month` to `map[SeriesKey]ModelDay`. In `Apply`, populate the new cell-key fields from `e.Source`/`e.Vendor`. In `Snapshot`, change the internal `modelKey` to carry the series:

```go
	type modelKey struct {
		Scope string
		Key   SeriesKey
	}
```

and build it as `modelKey{"day", SeriesKey{Source: k.Source, Vendor: k.Vendor, Model: k.Model}}`. The pricing lookup uses `mk.Key.Model`. Assign into `out.Day[mk.Key]` / `out.Month[mk.Key]`.

Leave the project maps, `Daily`, `Unknown`, `Dupes` and the dedupe rule exactly as they are.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && TZ=UTC go test ./internal/agg/ -v`
Expected: PASS — new tests plus all pre-existing agg tests. Other packages will not compile yet; that is expected and is fixed in Tasks 4–6.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/agg/
git commit -m "feat(agg): key per-model totals by (source, vendor, model)

Vendor is stored beside source rather than derived at snapshot time,
because the macapp persists cells and a label removed from config would
leave them unattributable. Dedupe is untouched: the same message under
two roots is still one event."
```

---

### Task 4: grouping — a pure collapse of `SeriesKey`

**Files:**
- Create: `tui/internal/agg/group.go`
- Test: `tui/internal/agg/group_test.go`

**Interfaces:**
- Consumes: `agg.SeriesKey`, `agg.ModelDay` (Task 3).
- Produces: `agg.Mode` (`GroupModel`, `GroupVendor`, `GroupSource`, `GroupTotal`) with `String()` returning `model|vendor|source|total` and `Next() Mode`; `agg.Group(in map[SeriesKey]ModelDay, m Mode) map[string]ModelDay`.

- [ ] **Step 1: Write the failing test**

```go
package agg

import "testing"

func seed() map[SeriesKey]ModelDay {
	return map[SeriesKey]ModelDay{
		{Source: "claude/work", Vendor: "claude", Model: "claude-opus-4-7"}:   {USD: 10, Tokens: TokenCounts{InputTokens: 100}},
		{Source: "claude/work", Vendor: "claude", Model: "claude-sonnet-4-6"}: {USD: 5, Tokens: TokenCounts{InputTokens: 50}},
		{Source: "claude/home", Vendor: "claude", Model: "claude-opus-4-7"}:   {USD: 2, Tokens: TokenCounts{InputTokens: 20}},
		{Source: "grok/home", Vendor: "grok", Model: "grok-4.5-build"}:        {USD: 3, Tokens: TokenCounts{InputTokens: 30}},
	}
}

func TestGroupModelMergesAcrossSources(t *testing.T) {
	got := Group(seed(), GroupModel)
	if len(got) != 3 {
		t.Fatalf("want 3 models, got %d: %+v", len(got), got)
	}
	// opus appears under two sources and must merge to 12.
	if got["claude-opus-4-7"].USD != 12 {
		t.Fatalf("opus USD = %v, want 12", got["claude-opus-4-7"].USD)
	}
	if got["claude-opus-4-7"].Tokens.InputTokens != 120 {
		t.Fatalf("tokens must merge too, got %+v", got["claude-opus-4-7"].Tokens)
	}
}

func TestGroupVendorCollapsesModels(t *testing.T) {
	got := Group(seed(), GroupVendor)
	if len(got) != 2 {
		t.Fatalf("want 2 vendors, got %+v", got)
	}
	if got["claude"].USD != 17 {
		t.Fatalf("claude USD = %v, want 17 (10+5+2)", got["claude"].USD)
	}
	if got["grok"].USD != 3 {
		t.Fatalf("grok USD = %v, want 3", got["grok"].USD)
	}
}

func TestGroupSourceKeepsSubscriptionsApart(t *testing.T) {
	got := Group(seed(), GroupSource)
	if len(got) != 3 {
		t.Fatalf("want 3 sources, got %+v", got)
	}
	if got["claude/work"].USD != 15 {
		t.Fatalf("claude/work USD = %v, want 15 (10+5)", got["claude/work"].USD)
	}
	if got["claude/home"].USD != 2 {
		t.Fatalf("claude/home USD = %v, want 2", got["claude/home"].USD)
	}
}

func TestGroupTotalIsOneSeries(t *testing.T) {
	got := Group(seed(), GroupTotal)
	if len(got) != 1 {
		t.Fatalf("want 1 series, got %+v", got)
	}
	if got["total"].USD != 20 {
		t.Fatalf("total USD = %v, want 20", got["total"].USD)
	}
}

// Every mode must sum to the same grand total — a grouping that loses or
// duplicates spend is the whole risk here.
func TestEveryModeSumsToTheSameTotal(t *testing.T) {
	in := seed()
	var want float64
	for _, v := range in {
		want += v.USD
	}
	for _, m := range []Mode{GroupModel, GroupVendor, GroupSource, GroupTotal} {
		var got float64
		for _, v := range Group(in, m) {
			got += v.USD
		}
		if got != want {
			t.Errorf("mode %s sums to %v, want %v", m, got, want)
		}
	}
}

func TestModeNextCycles(t *testing.T) {
	m := GroupModel
	for _, want := range []Mode{GroupVendor, GroupSource, GroupTotal, GroupModel} {
		m = m.Next()
		if m != want {
			t.Fatalf("Next() = %v, want %v", m, want)
		}
	}
}

func TestModeStrings(t *testing.T) {
	for m, want := range map[Mode]string{
		GroupModel: "model", GroupVendor: "vendor",
		GroupSource: "source", GroupTotal: "total",
	} {
		if m.String() != want {
			t.Errorf("%d.String() = %q, want %q", m, m.String(), want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/agg/ -run 'TestGroup|TestMode|TestEveryMode' -v`
Expected: FAIL — `undefined: Group`, `undefined: GroupModel`.

- [ ] **Step 3: Write minimal implementation**

```go
package agg

// Mode selects how per-series totals are collapsed for display. The same
// mode drives the monthly table and the charts on both surfaces.
type Mode int

const (
	GroupModel  Mode = iota // one series per model, merged across sources
	GroupVendor             // one series per vendor — the "all Claude" view
	GroupSource             // one series per configured subscription
	GroupTotal              // a single series
)

func (m Mode) String() string {
	switch m {
	case GroupVendor:
		return "vendor"
	case GroupSource:
		return "source"
	case GroupTotal:
		return "total"
	default:
		return "model"
	}
}

// Next cycles model -> vendor -> source -> total -> model.
func (m Mode) Next() Mode {
	if m >= GroupTotal {
		return GroupModel
	}
	return m + 1
}

// label reduces a series key to its display name under a mode.
func (m Mode) label(k SeriesKey) string {
	switch m {
	case GroupVendor:
		return k.Vendor
	case GroupSource:
		return k.Source
	case GroupTotal:
		return "total"
	default:
		return k.Model
	}
}

// Group collapses per-series totals by mode. Every mode partitions the
// same input, so all four sum to the same grand total — no mode may lose
// or duplicate spend.
func Group(in map[SeriesKey]ModelDay, m Mode) map[string]ModelDay {
	out := make(map[string]ModelDay, len(in))
	for k, v := range in {
		name := m.label(k)
		cur := out[name]
		cur.USD += v.USD
		cur.Tokens = cur.Tokens.Add(v.Tokens)
		out[name] = cur
	}
	return out
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && TZ=UTC go test ./internal/agg/ -v`
Expected: PASS — 7 new tests plus everything from Task 3.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/agg/group.go tui/internal/agg/group_test.go
git commit -m "feat(agg): pure grouping of series by model, vendor, source or total

Every mode partitions the same input, so all four sum to the same grand
total — pinned by a test, since a grouping that loses or duplicates spend
is the main risk."
```

---

### Task 5: TUI renders the selected grouping

**Files:**
- Create: `tui/internal/ui/group_view.go`
- Modify: `tui/internal/ui/view_minimal.go:41-66` (`viewMinimal`, `sumUSD`), `tui/internal/ui/view_split.go`, `tui/internal/ui/view_full.go`, `tui/internal/ui/model.go`
- Test: `tui/internal/ui/group_view_test.go`

**Interfaces:**
- Consumes: `agg.Group`, `agg.Mode` and friends (Task 4); `agg.Totals.Day`/`.Month` as `map[agg.SeriesKey]agg.ModelDay` (Task 3); existing `ui.FormatUSD`, `styleDim`, `styleMoney`, `styleHead`.
- Produces: `ui.renderSeries(series map[string]agg.ModelDay, mode agg.Mode) string`; `ui.renderModeBar(mode agg.Mode) string`; the model carries `groupMode agg.Mode` cycled by the `g` key.

- [ ] **Step 1: Write the failing test**

```go
package ui

import (
	"strings"
	"testing"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

func series() map[string]agg.ModelDay {
	return map[string]agg.ModelDay{
		"claude-opus-4-7":   {USD: 12},
		"claude-sonnet-4-6": {USD: 5},
		"grok-4.5-build":    {USD: 3},
	}
}

func TestRenderSeriesSortsByUSDDescending(t *testing.T) {
	out := renderSeries(series(), agg.GroupModel)
	iOpus := strings.Index(out, "claude-opus-4-7")
	iSonnet := strings.Index(out, "claude-sonnet-4-6")
	iGrok := strings.Index(out, "grok-4.5-build")
	if !(iOpus < iSonnet && iSonnet < iGrok) {
		t.Fatalf("rows must be ordered by USD desc:\n%s", out)
	}
}

func TestRenderSeriesShowsShareOfTotal(t *testing.T) {
	out := renderSeries(series(), agg.GroupModel)
	// 12 of 20 is 60%.
	if !strings.Contains(out, "60%") {
		t.Fatalf("expected a 60%% share for opus:\n%s", out)
	}
}

// A source label contains a slash and must survive rendering intact —
// truncating it to the vendor would merge two subscriptions visually.
func TestRenderSeriesKeepsFullSourceLabel(t *testing.T) {
	out := renderSeries(map[string]agg.ModelDay{
		"claude/work":     {USD: 10},
		"claude/personal": {USD: 4},
	}, agg.GroupSource)
	for _, want := range []string{"claude/work", "claude/personal"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q:\n%s", want, out)
		}
	}
}

func TestRenderSeriesEmptyIsEmpty(t *testing.T) {
	if got := renderSeries(map[string]agg.ModelDay{}, agg.GroupModel); got != "" {
		t.Fatalf("no series must render nothing, got %q", got)
	}
}

func TestRenderModeBarMarksActiveMode(t *testing.T) {
	out := renderModeBar(agg.GroupVendor)
	if !strings.Contains(out, "[vendor]") {
		t.Fatalf("active mode must be bracketed:\n%s", out)
	}
	for _, other := range []string{"model", "source", "total"} {
		if !strings.Contains(out, other) {
			t.Errorf("mode bar must list %q:\n%s", other, out)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/ui/ -run 'TestRenderSeries|TestRenderModeBar' -v`
Expected: FAIL — `undefined: renderSeries`, `undefined: renderModeBar`.

- [ ] **Step 3: Write minimal implementation**

Create `group_view.go`:

```go
package ui

import (
	"fmt"
	"sort"
	"strings"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// renderSeries draws one row per grouped series, ordered by spend. The
// share column is of the rendered total, so it always sums to 100%
// whichever mode is active.
func renderSeries(series map[string]agg.ModelDay, mode agg.Mode) string {
	if len(series) == 0 {
		return ""
	}
	names := make([]string, 0, len(series))
	var total float64
	for n, v := range series {
		names = append(names, n)
		total += v.USD
	}
	sort.Slice(names, func(i, j int) bool {
		if series[names[i]].USD != series[names[j]].USD {
			return series[names[i]].USD > series[names[j]].USD
		}
		return names[i] < names[j] // stable for equal spend
	})

	var b strings.Builder
	for _, n := range names {
		pct := 0.0
		if total > 0 {
			pct = 100 * series[n].USD / total
		}
		// The name is not shortened: a source label like "claude/work"
		// loses its meaning if truncated to its vendor.
		b.WriteString(fmt.Sprintf("  %-22s %10s  %3.0f%%\n",
			n, FormatUSD(series[n].USD), pct))
	}
	return b.String()
}

// renderModeBar shows the four modes with the active one bracketed, so
// the cycle key is discoverable without a legend.
func renderModeBar(mode agg.Mode) string {
	parts := make([]string, 0, 4)
	for _, m := range []agg.Mode{agg.GroupModel, agg.GroupVendor, agg.GroupSource, agg.GroupTotal} {
		if m == mode {
			parts = append(parts, "["+m.String()+"]")
			continue
		}
		parts = append(parts, m.String())
	}
	return styleDim.Render("group: "+strings.Join(parts, " ")+"   (b)") + "\n"
}
```

Then update the views:

- `sumUSD` (view_minimal.go:19) currently takes `map[string]agg.ModelDay`. Change its parameter to `map[agg.SeriesKey]agg.ModelDay` — it only sums values, so the body is unchanged.
- `viewMinimal` gains a `mode agg.Mode` parameter; replace its inline per-model line (view_minimal.go:55-66) with `renderModeBar(mode)` followed by `renderSeries(agg.Group(t.Day, mode), mode)`.
- Do the same in `view_split.go`, and pass the mode through from `view_full.go`'s `viewSplit` call.
- In `model.go`, add `groupMode agg.Mode` to the model struct, handle `"b"` in `Update` with `m.groupMode = m.groupMode.Next()`, and pass `m.groupMode` at every `viewMinimal`/`viewSplit` call site.

> **Key choice, already verified — do not substitute.** The bound keys in `model.go` are `[ 1 2 3 4 5 d g G m q tab up w`. Both `g` and `G` are taken by the report view's go-to-top / go-to-bottom (`model.go:255`), and `m` is the month bucket. `b` ("group **b**y") is free and is what this plan uses. If you find `b` bound after all, report it rather than picking a replacement silently — the key is documented in Task 12.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && TZ=UTC go test ./... && go vet ./...`
Expected: PASS across the whole module — this is the task where the Task 3 key change stops breaking other packages. Existing `ui` tests calling `viewMinimal` need their call sites updated to pass `agg.GroupModel`.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/ui/
git commit -m "feat(ui): render the selected grouping, cycled with b

The share column is of the rendered total so it sums to 100% in every
mode. Series names are never shortened — a source label truncated to its
vendor would visually merge two subscriptions."
```

---

### Task 6: wire sources into the TUI entry points

**Files:**
- Modify: `tui/cmd/claudecounter/main.go` — flag block, `scanSnapshot`, `runTUI`, the watcher wiring
- Test: `tui/cmd/claudecounter/sources_cli_test.go`

**Interfaces:**
- Consumes: `sources.Load`, `sources.DefaultConfigPath` (Task 1); `reader.InitialScanSource`/`OnChangeSource` (Task 2).
- Produces: a `--sources-config` flag; `scanSnapshot` scanning every configured source.

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Two roots, each with one project, must both land in the snapshot and
// stay distinguishable by source.
func TestScanSnapshotCoversEverySource(t *testing.T) {
	home := t.TempDir()
	fixture, err := os.ReadFile(filepath.Join("..", "..", "internal", "reader", "testdata", "session_normal.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	for _, root := range []string{"a", "b"} {
		dir := filepath.Join(home, root, "projects", "proj")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		// Distinct message ids per root so dedupe does not collapse them.
		body := strings.ReplaceAll(string(fixture), `"id":"msg`, `"id":"`+root+`msg`)
		if err := os.WriteFile(filepath.Join(dir, "s.jsonl"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cfg := filepath.Join(home, "sources.toml")
	if err := os.WriteFile(cfg, []byte(`
[[source]]
vendor = "claude"
label  = "a"
root   = "`+filepath.Join(home, "a", "projects")+`"

[[source]]
vendor = "claude"
label  = "b"
root   = "`+filepath.Join(home, "b", "projects")+`"
`), 0o644); err != nil {
		t.Fatal(err)
	}

	snap := scanSnapshotFromConfig(cfg, home, testPricingTable(t))
	seen := map[string]bool{}
	for k := range snap.Month {
		seen[k.Source] = true
	}
	if !seen["claude/a"] || !seen["claude/b"] {
		t.Fatalf("both sources must appear, got %+v", seen)
	}
}

// With no config file the behaviour must be exactly what it was before
// this feature existed: one implicit claude source.
func TestScanSnapshotWithNoConfigUsesDefault(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, ".claude", "projects", "proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	fixture, _ := os.ReadFile(filepath.Join("..", "..", "internal", "reader", "testdata", "session_normal.jsonl"))
	_ = os.WriteFile(filepath.Join(dir, "s.jsonl"), fixture, 0o644)

	snap := scanSnapshotFromConfig(filepath.Join(home, "absent.toml"), home, testPricingTable(t))
	for k := range snap.Month {
		if k.Source != "claude/claude" {
			t.Fatalf("default source must be claude/claude, got %q", k.Source)
		}
	}
	if len(snap.Month) == 0 {
		t.Fatal("expected the default root to be scanned")
	}
}
```

> **Note for the implementer:** `testPricingTable(t)` may not exist. Read `tui/cmd/claudecounter/` tests and reuse whatever they use to build a table; add a small helper if there is none.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./cmd/claudecounter/ -run TestScanSnapshot -v`
Expected: FAIL — `undefined: scanSnapshotFromConfig`.

- [ ] **Step 3: Write minimal implementation**

Add a `--sources-config` flag defaulting to `sources.DefaultConfigPath()`, and refactor `scanSnapshot` so the multi-source version is testable:

```go
// scanSnapshotFromConfig loads the source list and scans every configured
// root into one aggregator. A malformed config is fatal here (the
// one-shot paths exit non-zero); the live TUI path must not be, and
// handles the error separately — see runTUI.
func scanSnapshotFromConfig(cfgPath, home string, table pricing.Table) agg.Totals {
	cfg, err := sources.Load(cfgPath, home)
	if err != nil {
		fmt.Fprintln(os.Stderr, "sources config:", err)
		os.Exit(1)
	}
	return scanSnapshotSources(cfg.Sources, table)
}

// scanSnapshotSources scans each source's root in turn into a single
// aggregator, so dedupe still spans every source.
func scanSnapshotSources(srcs []sources.Source, table pricing.Table) agg.Totals {
	evCh := make(chan reader.Event, 1024)
	r := reader.New(evCh)
	a := agg.New(table)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for e := range evCh {
			a.Apply(e)
		}
	}()

	notBefore := scanCutoff(time.Now().Local())
	for _, s := range srcs {
		// A configured root that does not exist contributes nothing and
		// is not an error — same rule as an absent vendor.
		if _, err := os.Stat(s.Root); err != nil {
			continue
		}
		if err := r.InitialScanSource(s, notBefore); err != nil {
			log.Fatalf("initial scan %s: %v", s.ID(), err)
		}
	}
	close(evCh)
	<-done
	return a.Snapshot()
}
```

Rewrite the existing `scanSnapshot` to call `scanSnapshotSources` with the default source list, so `--once` behaviour is unchanged. Update `runTUI` and the watcher wiring to watch every configured root, dispatching changes through `OnChangeSource` with the matching source.

> **Note for the implementer:** the watcher currently takes one root. Read `tui/internal/watcher/watcher.go` and `runTUI` before changing them. Map each changed path back to its source by longest-matching root prefix — the load-time overlap check guarantees exactly one match. In the live TUI path, a malformed sources config must **not** exit; surface it the way a malformed `limits.toml` already is and fall back to the default source list, so counting continues.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && TZ=UTC go test ./... && go vet ./...`
Expected: PASS across the module.

Then verify by hand:

Run: `cd tui && go build -o /tmp/cc-src ./cmd/claudecounter && /tmp/cc-src --once`
Expected: the same totals as before this branch — the default path is unchanged.

- [ ] **Step 5: Commit**

```bash
git add tui/cmd/claudecounter/
git commit -m "feat(tui): scan every configured source

One aggregator across all sources, so dedupe still spans them. A missing
root is skipped silently; a malformed config exits non-zero in the
one-shot paths but never stops the live TUI counting."
```

---

### Task 7: drop the `n/a` gauge rows

**Files:**
- Modify: `tui/internal/ui/gauges.go` — `BuildRows` (the `n/a` synthesis) and `naReason`
- Modify: `macapp/Sources/ClaudeCounterCore/GaugeRows.swift` — the equivalent branch
- Test: `tui/internal/ui/gauges_test.go`, `macapp/Tests/ClaudeCounterCoreTests/GaugeRowsTests.swift`

**Interfaces:**
- Consumes: existing `ui.BuildRows`, `GaugeRows.build`.
- Produces: `Row.NotApplicable` and `GaugeRow.notApplicable` are removed; a vendor with nothing in a band is simply absent.

- [ ] **Step 1: Write the failing test**

Replace the existing `n/a` assertions. In Go:

```go
// Codex stopped emitting its 5h window and Grok never had one, so the
// short band was one real row plus two placeholders. A vendor with
// nothing in a band is now simply not listed.
func TestBuildRowsOmitsVendorWithNothingInBand(t *testing.T) {
	rows := BuildRows(BandShort, statuses(), gauges())
	if got := strings.Join(vendors(rows), ","); got != "claude,codex" {
		t.Fatalf("order = %q, want claude,codex (grok has no short window)", got)
	}
	for _, r := range rows {
		if r.Plan == nil && r.Budget == nil {
			t.Fatalf("no placeholder rows should remain: %+v", r)
		}
	}
}

func TestRenderGaugesHasNoNaText(t *testing.T) {
	out := RenderGauges(statuses(), gauges(), limits.DefaultWarnPct)
	if strings.Contains(out, "n/a") {
		t.Fatalf("no n/a rows should render:\n%s", out)
	}
}
```

In Swift:

```swift
func test_build_omitsVendorWithNothingInBand() {
    let rows = GaugeRows.build(band: .short, statuses: statuses, gauges: gauges)
    XCTAssertEqual(rows.map(\.vendor), ["claude", "codex"])
    XCTAssertTrue(rows.allSatisfy { $0.plan != nil || $0.budget != nil })
}
```

> **Note for the implementer:** the current fixtures give codex a `5h` gauge, so `codex` stays in the short band. Read the existing `gauges()` / `gauges` fixtures and adjust the expected vendor list to match whatever they actually contain — the point is that a vendor with *no* row in the band disappears entirely.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tui && TZ=UTC go test ./internal/ui/ -run 'TestBuildRowsOmitsVendor|TestRenderGaugesHasNoNa' -v`
Expected: FAIL — the `n/a` row is still synthesised.

Run: `make macapp-test 2>&1 | grep -A3 omitsVendorWithNothing`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

In `gauges.go`, delete the `matched`/`naReason` synthesis so an unmatched vendor simply contributes no row, and remove the now-unused `NotApplicable` field and `naReason` function. Do the same in `GaugeRows.swift`, removing `notApplicable` from `GaugeRow`. Update `GaugesView.swift` to drop its `notApplicable` branch, and delete the `n/a` paragraph from `README.md`.

Keep the bands themselves — the reader keys on `window_minutes`, so a returning Codex 5h row reappears with no code change.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-all`
Expected: PASS both suites.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/ui/ macapp/Sources/ macapp/Tests/ README.md
git commit -m "feat(gauges): drop the n/a placeholder rows

Codex stopped emitting its 5h window in August and Grok never had one,
so the short band was one real row and two placeholders. Bands stay: the
reader keys on window_minutes, so a returning 5h row reappears on its
own."
```

---

### Task 8: Swift `Sources.swift`

**Files:**
- Create: `macapp/Sources/ClaudeCounterCore/Sources.swift`
- Test: `macapp/Tests/ClaudeCounterCoreTests/SourcesTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SourceEntry{vendor, label, root: String}` with `var id: String { "\(vendor)/\(label)" }`; `SourcesConfig{sources: [SourceEntry]}`; `Sources.defaultConfigPath() -> String`; `Sources.defaults(home:) -> [SourceEntry]`; `Sources.load(path:home:) throws -> SourcesConfig`; `SourcesError`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeCounterCore

final class SourcesTests: XCTestCase {

    private func write(_ body: String) throws -> String {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        try body.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func test_load_missingFileYieldsDefaults() throws {
        let cfg = try Sources.load(path: NSTemporaryDirectory() + "/absent-\(UUID().uuidString).toml",
                                   home: "/home/u")
        XCTAssertEqual(cfg.sources, Sources.defaults(home: "/home/u"))
    }

    func test_defaults_isClaudeProjectsUnderHome() {
        let d = Sources.defaults(home: "/home/u")
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].vendor, "claude")
        XCTAssertEqual(d[0].label, "claude")
        XCTAssertEqual(d[0].root, "/home/u/.claude/projects")
    }

    func test_id_isVendorSlashLabel() {
        XCTAssertEqual(SourceEntry(vendor: "claude", label: "work", root: "/x").id, "claude/work")
    }

    func test_load_parsesAndExpandsTilde() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/.claude/projects"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        let cfg = try Sources.load(path: p, home: "/home/u")
        XCTAssertEqual(cfg.sources.count, 1)
        XCTAssertEqual(cfg.sources[0].root, "/home/u/.claude/projects")
    }

    func test_load_allowsSameLabelAcrossVendors() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "personal"
        root   = "~/.claude/projects"

        [[source]]
        vendor = "grok"
        label  = "personal"
        root   = "~/.grok/sessions"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertNoThrow(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_rejectsDuplicateLabelWithinVendor() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/a"

        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/b"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_rejectsNestedRoots() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "outer"
        root   = "~/.claude/projects"

        [[source]]
        vendor = "claude"
        label  = "inner"
        root   = "~/.claude/projects/sub"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_rejectsUnknownVendor() throws {
        let p = try write("""
        [[source]]
        vendor = "openai"
        label  = "x"
        root   = "~/x"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_emptyFileYieldsNoSources() throws {
        let p = try write("# nothing\n")
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertEqual(try Sources.load(path: p, home: "/home/u").sources.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make macapp-test`
Expected: FAIL — `cannot find 'Sources' in scope`.

- [ ] **Step 3: Write minimal implementation**

Mirror the Go loader. Follow the house style in `Limits.swift` for the hand-rolled TOML reading — in particular, split lines on `isNewline` (Swift's `Character` treats `\r\n` as one grapheme, so splitting on `"\n"` alone silently fails on CRLF files, a bug already fixed once in this codebase) and trim whitespace *inside* bracketed headers before comparing.

The parser needs one shape `Limits.swift` does not: repeated `[[source]]` tables. Accumulate a current entry on each `[[source]]` header, pushing the previous one, and push the last at EOF. Validate exactly as Go does: known vendor, non-empty label and root, unique `(vendor, label)`, no nested or duplicate roots. Expand a leading `~/`.

- [ ] **Step 4: Run test to verify it passes**

Run: `make macapp-test`
Expected: PASS — 9 new tests plus the existing suite.

- [ ] **Step 5: Commit**

```bash
git add macapp/Sources/ClaudeCounterCore/Sources.swift macapp/Tests/ClaudeCounterCoreTests/SourcesTests.swift
git commit -m "feat(macapp): Sources.swift mirroring the Go source loader

Same validation: known vendor, unique (vendor,label), no nested roots.
Lines split on isNewline so a CRLF sources.toml parses, matching the fix
already applied to Limits.swift."
```

---

### Task 9: Swift aggregation key, cache version, and grouping

**Files:**
- Modify: `macapp/Sources/ClaudeCounterCore/Aggregator.swift` — `CellKey` at :153, `Totals` at :105-110, the snapshot scope structs at :318-330
- Modify: `macapp/Sources/ClaudeCounterCore/Cache.swift` — `CellEntry` at :33, `currentVersion` at :31, the encode/decode at :147-194
- Create: `macapp/Sources/ClaudeCounterCore/Grouping.swift`
- Test: `macapp/Tests/ClaudeCounterCoreTests/GroupingTests.swift`, plus updates to `AggregatorTests.swift` and `CacheTests.swift`

**Interfaces:**
- Consumes: `SourceEntry` (Task 8).
- Produces: `SeriesKey{source, vendor, model: String}` (`Hashable`, `Codable`); `Totals.day`/`.month` become `[SeriesKey: ModelDay]`; `GroupMode` (`.model`, `.vendor`, `.source`, `.total`) with `label`/`next`; `Grouping.group(_:by:) -> [String: ModelDay]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeCounterCore

final class GroupingTests: XCTestCase {

    private var seed: [SeriesKey: ModelDay] {
        [
            SeriesKey(source: "claude/work", vendor: "claude", model: "claude-opus-4-7"):   ModelDay(usd: 10),
            SeriesKey(source: "claude/work", vendor: "claude", model: "claude-sonnet-4-6"): ModelDay(usd: 5),
            SeriesKey(source: "claude/home", vendor: "claude", model: "claude-opus-4-7"):   ModelDay(usd: 2),
            SeriesKey(source: "grok/home",   vendor: "grok",   model: "grok-4.5-build"):    ModelDay(usd: 3),
        ]
    }

    func test_group_byModel_mergesAcrossSources() {
        let g = Grouping.group(seed, by: .model)
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g["claude-opus-4-7"]?.usd, 12)
    }

    func test_group_byVendor_collapsesModels() {
        let g = Grouping.group(seed, by: .vendor)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g["claude"]?.usd, 17)
        XCTAssertEqual(g["grok"]?.usd, 3)
    }

    func test_group_bySource_keepsSubscriptionsApart() {
        let g = Grouping.group(seed, by: .source)
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g["claude/work"]?.usd, 15)
        XCTAssertEqual(g["claude/home"]?.usd, 2)
    }

    func test_group_byTotal_isOneSeries() {
        let g = Grouping.group(seed, by: .total)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g["total"]?.usd, 20)
    }

    func test_everyMode_sumsToTheSameTotal() {
        let want = seed.values.reduce(0) { $0 + $1.usd }
        for mode in [GroupMode.model, .vendor, .source, .total] {
            let got = Grouping.group(seed, by: mode).values.reduce(0) { $0 + $1.usd }
            XCTAssertEqual(got, want, accuracy: 0.0001, "mode \(mode)")
        }
    }

    func test_next_cycles() {
        var m = GroupMode.model
        for want in [GroupMode.vendor, .source, .total, .model] {
            m = m.next
            XCTAssertEqual(m, want)
        }
    }
}
```

Also add, to `CacheTests.swift`:

```swift
// Bumping the version invalidates old caches so a stale cell without a
// source cannot be resurrected under the wrong series.
func test_cacheVersion_wasBumpedForSeriesKeys() {
    XCTAssertEqual(CacheFile.currentVersion, 4)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make macapp-test`
Expected: FAIL — `cannot find 'SeriesKey' in scope`, and the cache-version assertion fails at 3.

- [ ] **Step 3: Write minimal implementation**

Add `SeriesKey` and `Grouping.swift` mirroring the Go versions exactly (same four modes, same `label` mapping, same `next` cycle). Change `Totals.day`/`.month` to `[SeriesKey: ModelDay]`, add `source` and `vendor` to `Aggregator.CellKey`, and set them from the event.

For the cache: add `source` and `vendor` to `CellEntry` and bump `currentVersion` to 4. Add a version-history entry explaining why, in the style of the existing 1/2/3 notes:

```swift
/// - 4: cells are keyed by (day, project, source, vendor, model, isSub)
///   so multiple configured sources stay distinct. Old caches are
///   invalidated on load → one full rescan re-tags every cell with the
///   source it came from. Without the bump, cached cells would carry no
///   source and silently merge into one series.
```

`AppState.swift:135` already discards a cache whose version differs, so no migration code is needed.

> **Note for the implementer:** `ModelDay`'s memberwise init may require more than `usd:`. Read `Aggregator.swift:72-104` and use the real initialiser in the tests.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make macapp-test`
Expected: PASS — new tests plus the existing suite, with `AggregatorTests`/`CacheTests` call sites updated for the new key.

- [ ] **Step 5: Commit**

```bash
git add macapp/Sources/ macapp/Tests/
git commit -m "feat(macapp): series-keyed totals, cache v4, and grouping

Cache version bumped so cached cells without a source cannot be
resurrected under the wrong series; AppState already discards on
mismatch, so one rescan re-tags everything."
```

---

### Task 10: macapp scans every source, with a GUI editor

**Files:**
- Create: `macapp/Sources/ClaudeCounterBar/SourcesEditorView.swift`
- Modify: `macapp/Sources/ClaudeCounterCore/AppState.swift` (source list + scanning), `macapp/Sources/ClaudeCounterCore/Watcher.swift` (watch every root), `macapp/Sources/ClaudeCounterBar/PopoverView.swift` (mount the editor and the mode control)
- Test: `macapp/Tests/ClaudeCounterCoreTests/SourcesWriteTests.swift`

**Interfaces:**
- Consumes: `Sources.load`, `SourceEntry` (Task 8); `GroupMode`, `Grouping.group` (Task 9).
- Produces: `Sources.write(_ sources: [SourceEntry], to path: String) throws`; `AppState.sources: [SourceEntry]`, `AppState.groupMode: GroupMode`, `AppState.setGroupMode(_:)`, `AppState.reloadSources()`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeCounterCore

final class SourcesWriteTests: XCTestCase {

    // The GUI editor writes the same file the TUI reads, so a round trip
    // through write+load must be lossless.
    func test_write_thenLoad_roundTrips() throws {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let want = [
            SourceEntry(vendor: "claude", label: "work", root: "/home/u/.claude/projects"),
            SourceEntry(vendor: "claude", label: "personal", root: "/home/u/.claude-p/projects"),
        ]
        try Sources.write(want, to: p)
        let got = try Sources.load(path: p, home: "/home/u")
        XCTAssertEqual(got.sources, want)
    }

    // Writing a config the loader would reject must fail at write time,
    // not leave the user with a file neither app can read.
    func test_write_rejectsInvalidConfig() {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let bad = [
            SourceEntry(vendor: "claude", label: "dup", root: "/a"),
            SourceEntry(vendor: "claude", label: "dup", root: "/b"),
        ]
        XCTAssertThrowsError(try Sources.write(bad, to: p))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make macapp-test`
Expected: FAIL — `type 'Sources' has no member 'write'`.

- [ ] **Step 3: Write minimal implementation**

Add `Sources.write` — validate through the same rules `load` applies (call a shared `validate` helper so the two cannot drift), then emit `[[source]]` tables. Create the directory if needed, matching how `limits.toml`'s directory is handled.

In `AppState`, load the source list at start and on `reloadSources()`, scan every source's root instead of the single hardcoded one, and hold `groupMode` with a `setGroupMode(_:)` that publishes. A malformed sources config must degrade to the default list with `lastError` set — never stop counting.

`SourcesEditorView.swift` is a SwiftUI list of the configured sources with add/remove/edit and a folder picker for the root, calling `Sources.write` then `AppState.reloadSources()`. Show the validation error inline rather than silently refusing to save. Mount it from `PopoverView` alongside the existing settings affordances, and add a segmented control bound to `groupMode` above the per-model list.

> **Note for the implementer:** read `Watcher.swift` before changing it — it currently takes one root. Watching N roots may mean N watcher instances or one with multiple paths; pick whichever fits the existing FSEventStream setup and say which in your report. Also read how `PopoverView` currently reaches settings, and follow that pattern rather than inventing a second one.

- [ ] **Step 4: Run tests and build to verify**

Run: `make macapp-test`
Expected: PASS.

Run: `make macapp-debug`
Expected: builds cleanly.

- [ ] **Step 5: Commit**

```bash
git add macapp/Sources/ macapp/Tests/
git commit -m "feat(macapp): scan every source, add a sources editor

write() validates through the same rules load() applies, so the GUI
cannot produce a file the TUI would reject."
```

---

### Task 11: cross-language grouping parity

**Files:**
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/grouping_parity.json`
- Test: `tui/internal/agg/grouping_parity_test.go`, `macapp/Tests/ClaudeCounterCoreTests/GroupingParityTests.swift`

**Interfaces:**
- Consumes: `agg.Group`/`agg.Mode` (Task 4); `Grouping.group`/`GroupMode` (Task 9).
- Produces: one fixture read by both suites.

- [ ] **Step 1: Write the fixture and both tests**

`grouping_parity.json`:

```json
{
  "series": [
    {"source": "claude/work",     "vendor": "claude", "model": "claude-opus-4-7",   "usd": 10.0},
    {"source": "claude/work",     "vendor": "claude", "model": "claude-sonnet-4-6", "usd": 5.0},
    {"source": "claude/personal", "vendor": "claude", "model": "claude-opus-4-7",   "usd": 2.5},
    {"source": "grok/personal",   "vendor": "grok",   "model": "grok-4.5-build",    "usd": 3.25}
  ],
  "expect": {
    "model":  {"claude-opus-4-7": 12.5, "claude-sonnet-4-6": 5.0, "grok-4.5-build": 3.25},
    "vendor": {"claude": 17.5, "grok": 3.25},
    "source": {"claude/work": 15.0, "claude/personal": 2.5, "grok/personal": 3.25},
    "total":  {"total": 20.75}
  }
}
```

Both tests read this file, run all four modes, and compare every bucket with a 0.0001 tolerance. Go reads it at `"../../../macapp/Tests/ClaudeCounterCoreTests/Fixtures/grouping_parity.json"`; Swift reads it from `Bundle.module`. Both must fail loudly on a missing or empty fixture, exactly as the existing `limits_parity` tests do.

> **Note for the implementer:** this is a **second** fixture, not an extension of `limits_parity.json`. That one pins the budget engines; overloading it would blur what each fixture protects. Read `tui/internal/limits/parity_test.go` and `LimitsParityTests.swift` and follow their structure, including the empty-fixture guard.

- [ ] **Step 2: Run both suites**

Run: `cd tui && TZ=UTC go test ./internal/agg/ -run TestGroupingParity -v`
Run: `make macapp-test 2>&1 | grep -i groupingparity`

If both implementations are already correct these pass on the first run — a valid outcome for a parity test written against finished code, **but you must then prove they can fail.**

- [ ] **Step 3: Prove the tests can fail**

Temporarily change Go's `Mode.label` so `GroupSource` returns `k.Vendor`, confirm the Go parity test fails on the `source` bucket, and restore it. Do the equivalent on the Swift side. Record both failure outputs in your report — without this the fixture proves only that it parses.

- [ ] **Step 4: Run the full suite**

Run: `make test-all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macapp/Tests/ClaudeCounterCoreTests/Fixtures/grouping_parity.json \
        tui/internal/agg/grouping_parity_test.go \
        macapp/Tests/ClaudeCounterCoreTests/GroupingParityTests.swift
git commit -m "test: cross-language parity for the grouping modes

A second fixture, separate from limits_parity.json, which pins the budget
engines. If these disagree the two apps disagree about what a vendor or
subscription total is."
```

---

### Task 12: documentation

**Files:**
- Modify: `README.md`, `tui/README.md`, `macapp/README.md`

**Interfaces:** consumes everything above; produces no code.

- [ ] **Step 1: Read the implementation, then write**

Document, against the code as built rather than this plan's prose:

- `~/.config/claudecounter/sources.toml` — the format, that `(vendor, label)` is the series identity rendered `vendor/label`, that the same label under two vendors is fine, and that duplicate or nested roots are rejected with the reason (double counting).
- That **no config file means exactly today's behaviour** — one implicit `claude/claude` source.
- Why the root path is the only way to separate two Claude subscriptions: transcripts carry no account identifier, and `~/.claude.json`'s is machine-global and reflects whoever is logged in now.
- The four grouping modes, the `b` key in the TUI, and the segmented control in the popover.
- `--sources-config`.
- Remove the `n/a` row paragraph (Task 7 deleted the feature).

Generate the sample grouped output by running the real binary; replace real dollar figures with illustrative ones but keep the exact layout the renderer produces.

- [ ] **Step 2: Verify every documented command**

Run: `cd tui && go build -o /tmp/cc-doc ./cmd/claudecounter && /tmp/cc-doc --help 2>&1 | grep -A1 sources`
Expected: `--sources-config` appears.

- [ ] **Step 3: Commit**

```bash
git add README.md tui/README.md macapp/README.md
git commit -m "docs: configurable sources and the grouping control"
```

---

## Self-Review

**Spec coverage (Phase A sections only):**

| Spec section | Task |
|---|---|
| Configurable sources — [A] | 1 (Go), 8 (Swift), 10 (GUI + write) |
| Vendor and source as first-class dimensions — [A] | 2 (reader), 3 (Go agg), 9 (Swift agg + cache) |
| The grouping control — [A] | 4 (Go pure), 5 (TUI), 9 (Swift pure), 10 (popover) |
| Drop the `n/a` placeholder rows — [A] | 7 |
| Error handling table (sources rows) | 1 and 8 (validation), 6 and 10 (missing root, malformed config) |
| Cross-language agreement | 11 |
| Phase B sections | none — correctly absent |

**Placeholder scan:** no `TBD`/`TODO`/"handle edge cases"/"similar to Task N". Five implementer notes point at real code to read (`OnChange`/`InitialScan`, `testTable`, `testPricingTable`, `Watcher.swift`, `ModelDay`'s initialiser) rather than leaving behaviour unspecified.

**Type consistency:** `SeriesKey{Source,Vendor,Model}` (Go) and `SeriesKey{source,vendor,model}` (Swift) match. `agg.Mode`/`GroupMode` both have four cases in the same cycle order with the same `String()`/`label` values (`model|vendor|source|total`). `Source.ID()` and `SourceEntry.id` both yield `vendor/label`. `Group`/`Grouping.group` both return a name-keyed map. The parity fixture in Task 11 uses those exact strings.

**Known risk, stated rather than hidden:** Task 3 changes `Totals.Day`/`.Month` and will break `ui` and `cmd` compilation until Task 5 and Task 6 land. That is deliberate — splitting the key change from its call-site updates keeps each diff reviewable — but Tasks 3 and 4 cannot be verified with a whole-module test run, only a package-scoped one. Their step 4 commands say so.

---

**Plan complete and saved to `docs/superpowers/plans/2026-08-10-sources-and-grouping.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
