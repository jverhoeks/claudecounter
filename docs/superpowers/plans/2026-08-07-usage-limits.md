# Usage Limits & Utilisation Gauges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show how close the user is to a spending ceiling and to each vendor's plan limit, in both the Go TUI and the macOS menu bar app.

**Architecture:** Two new Go packages — `limits` (pure evaluation of configured USD budgets over calendar-day / ISO-week windows) and `planlimits` (on-demand scanners that read vendor-reported utilisation out of Codex and Grok local logs). A renderer in `internal/ui` groups rows by duration band (short window, then weekly) and is stacked-ready from the start. The macapp mirrors both in Swift and shares a single JSON fixture file with the Go tests so the two implementations cannot drift.

**Tech Stack:** Go 1.25 (`github.com/BurntSushi/toml` v1.6.0, `lipgloss` v1.1.0 — both already dependencies), Swift 5.9 / macOS 13+, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-07-usage-limits-design.md`

## Global Constraints

- **Nothing here may break cost counting.** Limits and plan gauges are strictly additive. Every failure path degrades to "row not shown", never to an error that reaches the counting path.
- **Key Codex rate limits on `window_minutes`, never on the slot name (`primary`/`secondary`) or `limit_id`.** Slot naming varies across Codex CLI versions.
- **Grok gets a percentage and never a USD figure.** Its `_meta.totalTokens` is cumulative context, not billable tokens.
- **Claude gets a USD budget and never a plan percentage.** Do not read `~/.claude/fetch-claude-usage.swift`, and do not call `claude.ai/api/organizations/*/usage`. Out of scope by explicit decision.
- **Windows:** day = local calendar day (matches `agg.dayOf`, `tui/internal/agg/agg.go:83`). Week = ISO week (matches `report.go:74`, `lt.ISOWeek()`).
- **Both plan gauges are point-in-time snapshots.** Always take the single most recent observation. Never aggregate across events.
- **Stale rows** (`ResetsAt` in the past) render dimmed and never drive the menu bar glyph.
- **Display order is fixed** per group: `claude`, `codex`, `grok`. Glyph escalation order is by descending `Pct` over non-stale rows. These are different orderings and both matter.
- **All tests run with `TZ=UTC`** so local-time window maths is deterministic.

---

### Task 1: `limits` package — config loading

**Files:**
- Create: `tui/internal/limits/config.go`
- Test: `tui/internal/limits/config_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `limits.Config{Daily, Weekly float64; WarnPct int}`, `limits.DefaultWarnPct = 80`, `limits.Load(path string) (Config, error)`, `limits.DefaultConfigPath() string`.

- [ ] **Step 1: Write the failing test**

```go
package limits

import (
	"os"
	"path/filepath"
	"testing"
)

func writeTemp(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "limits.toml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadFullConfig(t *testing.T) {
	p := writeTemp(t, "[limits]\ndaily = 50.0\nweekly = 250.0\nwarn_pct = 70\n")
	got, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Daily != 50.0 || got.Weekly != 250.0 || got.WarnPct != 70 {
		t.Fatalf("got %+v", got)
	}
}

// A missing file is the normal "user has not configured limits" state.
// It must not be an error — the gauge simply hides.
func TestLoadMissingFileIsNotAnError(t *testing.T) {
	got, err := Load(filepath.Join(t.TempDir(), "absent.toml"))
	if err != nil {
		t.Fatalf("missing file must not error, got %v", err)
	}
	if got.Daily != 0 || got.Weekly != 0 {
		t.Fatalf("missing file must yield zero limits, got %+v", got)
	}
}

func TestLoadAppliesDefaultWarnPct(t *testing.T) {
	p := writeTemp(t, "[limits]\ndaily = 10.0\n")
	got, err := Load(p)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.WarnPct != DefaultWarnPct {
		t.Fatalf("WarnPct = %d, want %d", got.WarnPct, DefaultWarnPct)
	}
}

func TestLoadMalformedReturnsError(t *testing.T) {
	p := writeTemp(t, "[limits]\ndaily = = =\n")
	if _, err := Load(p); err == nil {
		t.Fatal("malformed TOML must return an error so the caller can log it once")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/limits/ -run TestLoad -v`
Expected: FAIL — the package does not exist (`no Go files in .../internal/limits`).

- [ ] **Step 3: Write minimal implementation**

```go
// Package limits evaluates user-configured USD spending ceilings against
// the cost totals the aggregator already computes. It is deliberately
// inert: a missing or unreadable config means "no limits configured",
// never an error that reaches the live counting path.
package limits

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// DefaultWarnPct is the amber threshold applied when the config omits
// warn_pct. A single threshold covers both windows; per-window
// thresholds are deliberately not supported yet.
const DefaultWarnPct = 80

// Config is the parsed contents of limits.toml. A limit of zero (or
// absent) means that window is unconfigured, which is distinct from a
// limit of zero dollars — an unconfigured window renders no row at all.
type Config struct {
	Daily   float64
	Weekly  float64
	WarnPct int
}

type tomlFile struct {
	Limits struct {
		Daily   float64 `toml:"daily"`
		Weekly  float64 `toml:"weekly"`
		WarnPct int     `toml:"warn_pct"`
	} `toml:"limits"`
}

// DefaultConfigPath is the shared location both the TUI and the menu bar
// app read, so the two surfaces cannot disagree about the user's limits.
func DefaultConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "claudecounter", "limits.toml")
}

// Load reads limits.toml. A missing file yields a zero Config and no
// error: that is the normal unconfigured state, not a failure. Malformed
// TOML does return an error so the caller can surface it once rather
// than silently behaving as if no limits were set.
func Load(path string) (Config, error) {
	if path == "" {
		return Config{}, nil
	}
	var f tomlFile
	if _, err := toml.DecodeFile(path, &f); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Config{}, nil
		}
		return Config{}, err
	}
	cfg := Config{
		Daily:   f.Limits.Daily,
		Weekly:  f.Limits.Weekly,
		WarnPct: f.Limits.WarnPct,
	}
	if cfg.WarnPct <= 0 {
		cfg.WarnPct = DefaultWarnPct
	}
	return cfg, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && TZ=UTC go test ./internal/limits/ -v`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/limits/config.go tui/internal/limits/config_test.go
git commit -m "feat(limits): config loading from limits.toml

A missing file is the unconfigured state and returns no error; only
malformed TOML errors, so the caller can log it once. warn_pct defaults
to 80 when absent."
```

---

### Task 2: `limits` package — window evaluation

**Files:**
- Create: `tui/internal/limits/limits.go`
- Test: `tui/internal/limits/limits_test.go`

**Interfaces:**
- Consumes: `limits.Config` (Task 1); `agg.DailyTotal{Day string; USD float64; Tokens uint64}` where `Day` is `YYYY-MM-DD` in local time.
- Produces: `limits.Window` (`WindowDay`, `WindowWeek`) with `String()` (display label: `daily`/`wk`) **and** `Key()` (stable identity: `day`/`week`); `limits.State` (`StateUnset`, `StateOK`, `StateWarn`, `StateOver`) with `String()`; `limits.Status{Window; SpentUSD, LimitUSD, Pct float64; State; ResetsAt time.Time}`; `limits.Evaluate(daily []agg.DailyTotal, cfg Config, now time.Time) []Status` returning exactly two entries, `WindowDay` first.

- [ ] **Step 1: Write the failing test**

```go
package limits

import (
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

func at(s string) time.Time {
	t, err := time.ParseInLocation("2006-01-02T15:04:05", s, time.Local)
	if err != nil {
		panic(err)
	}
	return t
}

// Friday 2026-08-07 sits in ISO week 32, whose Monday is 2026-08-03.
var week = []agg.DailyTotal{
	{Day: "2026-08-03", USD: 10}, // Mon, in week
	{Day: "2026-08-06", USD: 20}, // Thu, in week
	{Day: "2026-08-07", USD: 39}, // Fri, today
	{Day: "2026-08-02", USD: 99}, // Sun, PREVIOUS ISO week — must be excluded
}

func TestEvaluateDayUsesLocalCalendarDay(t *testing.T) {
	got := Evaluate(week, Config{Daily: 50, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	day := got[0]
	if day.Window != WindowDay {
		t.Fatalf("first status must be WindowDay, got %v", day.Window)
	}
	if day.SpentUSD != 39 {
		t.Fatalf("SpentUSD = %v, want 39 (only today)", day.SpentUSD)
	}
	if day.Pct != 78 {
		t.Fatalf("Pct = %v, want 78", day.Pct)
	}
	if day.State != StateOK {
		t.Fatalf("State = %v, want OK (78 < warn 80)", day.State)
	}
}

func TestEvaluateWeekExcludesPreviousISOWeek(t *testing.T) {
	got := Evaluate(week, Config{Daily: 50, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	wk := got[1]
	if wk.SpentUSD != 69 {
		t.Fatalf("SpentUSD = %v, want 69 (10+20+39; the 99 on 2026-08-02 is last ISO week)", wk.SpentUSD)
	}
}

func TestEvaluateWarnAndOverThresholds(t *testing.T) {
	in := []agg.DailyTotal{{Day: "2026-08-07", USD: 40}}
	warn := Evaluate(in, Config{Daily: 50, WarnPct: 80}, at("2026-08-07T12:00:00"))[0]
	if warn.State != StateWarn {
		t.Fatalf("40/50 = 80%% must be Warn, got %v", warn.State)
	}
	over := Evaluate([]agg.DailyTotal{{Day: "2026-08-07", USD: 50}},
		Config{Daily: 50, WarnPct: 80}, at("2026-08-07T12:00:00"))[0]
	if over.State != StateOver {
		t.Fatalf("exactly at limit must be Over, got %v", over.State)
	}
}

func TestEvaluateUnsetLimit(t *testing.T) {
	got := Evaluate(week, Config{Daily: 0, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	if got[0].State != StateUnset {
		t.Fatalf("zero limit must be Unset, got %v", got[0].State)
	}
	if got[0].Pct != 0 {
		t.Fatalf("Unset must not compute a percentage, got %v", got[0].Pct)
	}
	if got[1].State == StateUnset {
		t.Fatal("the other window must still evaluate")
	}
}

// 2026-12-28 is a Monday in ISO week 53 of ISO year 2026, but its
// calendar year is still 2026 while 2027-01-01 falls in the SAME ISO
// week. Grouping by calendar year would split this week in two.
func TestEvaluateWeekAcrossISOYearBoundary(t *testing.T) {
	in := []agg.DailyTotal{
		{Day: "2026-12-28", USD: 5}, // Mon, ISO 2026-W53
		{Day: "2027-01-01", USD: 7}, // Fri, ISO 2026-W53
		{Day: "2027-01-04", USD: 9}, // Mon, ISO 2027-W01 — excluded
	}
	got := Evaluate(in, Config{Weekly: 100, WarnPct: 80}, at("2027-01-01T12:00:00"))
	if got[1].SpentUSD != 12 {
		t.Fatalf("SpentUSD = %v, want 12 (5+7 share ISO week 2026-W53)", got[1].SpentUSD)
	}
}

func TestEvaluateResetTimes(t *testing.T) {
	got := Evaluate(week, Config{Daily: 50, Weekly: 250, WarnPct: 80}, at("2026-08-07T12:00:00"))
	if want := at("2026-08-08T00:00:00"); !got[0].ResetsAt.Equal(want) {
		t.Fatalf("day ResetsAt = %v, want next local midnight %v", got[0].ResetsAt, want)
	}
	if want := at("2026-08-10T00:00:00"); !got[1].ResetsAt.Equal(want) {
		t.Fatalf("week ResetsAt = %v, want next Monday %v", got[1].ResetsAt, want)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/limits/ -run TestEvaluate -v`
Expected: FAIL — `undefined: Evaluate`, `undefined: WindowDay`, `undefined: StateOK`.

- [ ] **Step 3: Write minimal implementation**

```go
package limits

import (
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// Window is the period a Status covers.
type Window int

const (
	WindowDay Window = iota
	WindowWeek
)

// String is the DISPLAY label, rendered in the gauge rows.
func (w Window) String() string {
	if w == WindowWeek {
		return "wk"
	}
	return "daily"
}

// Key is the stable IDENTITY of the window, independent of how it is
// displayed. The cross-language parity fixture compares Key, not String:
// if the two were the same value, someone retuning a display label would
// silently keep the parity test green while changing what users see.
func (w Window) Key() string {
	if w == WindowWeek {
		return "week"
	}
	return "day"
}

// State is how a window's spend compares to its limit.
type State int

const (
	StateUnset State = iota // no limit configured for this window
	StateOK
	StateWarn
	StateOver
)

func (s State) String() string {
	switch s {
	case StateOK:
		return "ok"
	case StateWarn:
		return "warn"
	case StateOver:
		return "over"
	default:
		return "unset"
	}
}

// Status is one window's evaluation. Pct is 0 when State is Unset —
// a percentage of an unconfigured limit is meaningless, not zero.
type Status struct {
	Window   Window
	SpentUSD float64
	LimitUSD float64
	Pct      float64
	State    State
	ResetsAt time.Time
}

// Evaluate reports spend against the configured limits. It is pure: no
// clock, no filesystem, no aggregator state — everything it needs is an
// argument, which is what makes the window boundaries directly testable.
//
// It always returns exactly two entries, WindowDay first, so callers can
// index without checking length.
func Evaluate(daily []agg.DailyTotal, cfg Config, now time.Time) []Status {
	lt := now.Local()
	todayKey := lt.Format("2006-01-02")
	nowYear, nowWeek := lt.ISOWeek()

	var daySpent, weekSpent float64
	for _, d := range daily {
		if d.Day == todayKey {
			daySpent += d.USD
		}
		t, err := time.ParseInLocation("2006-01-02", d.Day, time.Local)
		if err != nil {
			continue // unparseable day key: skip, never fail the whole gauge
		}
		// ISO week, not calendar week: the ISO year can differ from the
		// calendar year around New Year, and comparing both fields is
		// what keeps a week that straddles 31 Dec in one bucket.
		if y, w := t.ISOWeek(); y == nowYear && w == nowWeek {
			weekSpent += d.USD
		}
	}

	return []Status{
		build(WindowDay, daySpent, cfg.Daily, cfg.WarnPct, nextMidnight(lt)),
		build(WindowWeek, weekSpent, cfg.Weekly, cfg.WarnPct, nextMonday(lt)),
	}
}

func build(w Window, spent, limit float64, warnPct int, resets time.Time) Status {
	st := Status{Window: w, SpentUSD: spent, LimitUSD: limit, ResetsAt: resets}
	if limit <= 0 {
		st.State = StateUnset
		return st
	}
	st.Pct = 100 * spent / limit
	switch {
	case st.Pct >= 100:
		st.State = StateOver
	case st.Pct >= float64(warnPct):
		st.State = StateWarn
	default:
		st.State = StateOK
	}
	return st
}

func nextMidnight(lt time.Time) time.Time {
	return time.Date(lt.Year(), lt.Month(), lt.Day(), 0, 0, 0, 0, lt.Location()).AddDate(0, 0, 1)
}

// nextMonday returns the start of the next ISO week. Go's Weekday has
// Sunday at 0, so Sunday needs 1 day and every other day needs
// 8-weekday days to reach the following Monday.
func nextMonday(lt time.Time) time.Time {
	midnight := time.Date(lt.Year(), lt.Month(), lt.Day(), 0, 0, 0, 0, lt.Location())
	delta := (8 - int(lt.Weekday())) % 7
	if delta == 0 {
		delta = 7
	}
	return midnight.AddDate(0, 0, delta)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && TZ=UTC go test ./internal/limits/ -v`
Expected: PASS — all tests including Task 1's.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/limits/limits.go tui/internal/limits/limits_test.go
git commit -m "feat(limits): pure window evaluation for day and ISO week

Evaluate takes the daily snapshot, config and clock as arguments so the
boundary cases are directly testable. Week grouping compares both ISO
year and ISO week, which keeps a week straddling 31 Dec in one bucket."
```

---

### Task 3: `planlimits` — types and the Codex scanner

**Files:**
- Create: `tui/internal/planlimits/planlimits.go`
- Create: `tui/internal/planlimits/codex.go`
- Create: `tui/internal/planlimits/testdata/codex_old_layout.jsonl`
- Create: `tui/internal/planlimits/testdata/codex_new_layout.jsonl`
- Test: `tui/internal/planlimits/codex_test.go`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `planlimits.Gauge{Vendor, WindowLbl string; Pct float64; ResetsAt, Observed time.Time; Stale bool; Plan string}`; `planlimits.WindowLabel(minutes int) string`; `planlimits.IsShortWindow(minutes int) bool`; `planlimits.ScanCodex(root string, now time.Time) ([]Gauge, error)`; `planlimits.DefaultCodexRoot() string`.

- [ ] **Step 1: Write the failing test**

Create `tui/internal/planlimits/testdata/codex_old_layout.jsonl` — the pre-change layout, 5h in `primary` and weekly in `secondary`. The second `token_count` line is newer and must win:

```jsonl
{"timestamp":"2026-08-07T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":11.0,"window_minutes":300,"resets_at":4102444800},"secondary":{"used_percent":22.0,"window_minutes":10080,"resets_at":4102444800}}}}
{"timestamp":"2026-08-07T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":92.0,"window_minutes":300,"resets_at":4102444800},"secondary":{"used_percent":30.0,"window_minutes":10080,"resets_at":4102444800}}}}
{"timestamp":"2026-08-07T11:30:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","plan_type":"plus","primary":null,"secondary":null}}}
```

Create `tui/internal/planlimits/testdata/codex_new_layout.jsonl` — weekly moved into `primary`, no 5h window, different `limit_id`:

```jsonl
{"timestamp":"2026-08-07T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"premium","plan_type":"plus","primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":4102444800},"secondary":null}}}
```

Create `tui/internal/planlimits/codex_test.go`:

```go
package planlimits

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func now() time.Time { return time.Date(2026, 8, 7, 13, 0, 0, 0, time.UTC) }

// copyFixture places a fixture into a temp dir under the session-file
// layout ScanCodex walks, with a controlled mtime.
func copyFixture(t *testing.T, name string, mtime time.Time) string {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, "2026", "08", "07")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(dir, "rollout-"+name)
	if err := os.WriteFile(dst, body, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(dst, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	return root
}

func byLabel(gs []Gauge) map[string]Gauge {
	m := map[string]Gauge{}
	for _, g := range gs {
		m[g.WindowLbl] = g
	}
	return m
}

// The old layout puts 5h in primary and weekly in secondary. Keying on
// the slot name instead of window_minutes would mislabel both.
func TestScanCodexOldLayoutBothWindows(t *testing.T) {
	root := copyFixture(t, "codex_old_layout.jsonl", now().Add(-time.Hour))
	gs, err := ScanCodex(root, now())
	if err != nil {
		t.Fatalf("ScanCodex: %v", err)
	}
	m := byLabel(gs)
	if len(m) != 2 {
		t.Fatalf("want 2 windows, got %d: %+v", len(m), gs)
	}
	if m["5h"].Pct != 92 {
		t.Fatalf("5h Pct = %v, want 92 (newest observation wins)", m["5h"].Pct)
	}
	if m["7d"].Pct != 30 {
		t.Fatalf("7d Pct = %v, want 30", m["7d"].Pct)
	}
	if m["5h"].Vendor != "codex" || m["5h"].Plan != "plus" {
		t.Fatalf("vendor/plan wrong: %+v", m["5h"])
	}
}

// The new layout puts the weekly window in primary. It must still be
// labelled 7d, proving the reader keys on window_minutes.
func TestScanCodexNewLayoutWeeklyInPrimary(t *testing.T) {
	root := copyFixture(t, "codex_new_layout.jsonl", now().Add(-time.Hour))
	gs, err := ScanCodex(root, now())
	if err != nil {
		t.Fatalf("ScanCodex: %v", err)
	}
	m := byLabel(gs)
	if len(m) != 1 {
		t.Fatalf("want 1 window, got %d: %+v", len(m), gs)
	}
	if m["7d"].Pct != 100 {
		t.Fatalf("7d Pct = %v, want 100", m["7d"].Pct)
	}
}

func TestScanCodexMarksExpiredWindowStale(t *testing.T) {
	root := copyFixture(t, "codex_new_layout.jsonl", now().Add(-time.Hour))
	// resets_at in the fixture is far future; evaluate as if now is later.
	future := time.Unix(4102444800, 0).Add(time.Hour)
	gs, err := ScanCodex(root, future)
	if err != nil {
		t.Fatalf("ScanCodex: %v", err)
	}
	if len(gs) != 1 || !gs[0].Stale {
		t.Fatalf("expired window must be Stale, got %+v", gs)
	}
}

func TestScanCodexMissingRootIsNotAnError(t *testing.T) {
	gs, err := ScanCodex(filepath.Join(t.TempDir(), "absent"), now())
	if err != nil {
		t.Fatalf("absent root must not error, got %v", err)
	}
	if len(gs) != 0 {
		t.Fatalf("absent root must yield no gauges, got %+v", gs)
	}
}

func TestWindowLabel(t *testing.T) {
	for _, c := range []struct {
		min  int
		want string
	}{{300, "5h"}, {10080, "7d"}, {60, "1h"}, {1440, "24h"}} {
		if got := WindowLabel(c.min); got != c.want {
			t.Errorf("WindowLabel(%d) = %q, want %q", c.min, got, c.want)
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/planlimits/ -v`
Expected: FAIL — `undefined: ScanCodex`, `undefined: Gauge`, `undefined: WindowLabel`.

- [ ] **Step 3: Write minimal implementation**

`tui/internal/planlimits/planlimits.go`:

```go
// Package planlimits reads vendor-reported plan utilisation out of the
// Codex and Grok CLIs' own local logs. These percentages are
// authoritative — they come from the vendor, not from our pricing table —
// and they cover windows the vendor defines, which do not align with the
// calendar day or ISO week used for USD budgets.
//
// Every observation is point-in-time. Scanners take the single most
// recent value and never aggregate across events.
package planlimits

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// shortWindowCutoffMinutes divides the "short window" duration band from
// the weekly band. A day and a 5-hour window sit on the short side.
const shortWindowCutoffMinutes = 1440

// Gauge is one vendor's utilisation of one of its own windows.
type Gauge struct {
	Vendor    string    // "codex" | "grok"
	WindowLbl string    // "5h" | "7d" | "wk"
	Pct       float64
	ResetsAt  time.Time
	Observed  time.Time // when the vendor wrote this figure
	Stale     bool      // the window closed before now
	Plan      string    // "plus" | "SuperGrok" | ""
}

// WindowLabel renders a window duration compactly: hours below a day,
// whole days above. 300 -> "5h", 10080 -> "7d".
func WindowLabel(minutes int) string {
	if minutes < shortWindowCutoffMinutes {
		return fmt.Sprintf("%dh", minutes/60)
	}
	if minutes == shortWindowCutoffMinutes {
		return "24h"
	}
	return fmt.Sprintf("%dd", minutes/shortWindowCutoffMinutes)
}

// IsShortWindow reports whether a window belongs in the short-window
// display band rather than the weekly band.
func IsShortWindow(minutes int) bool { return minutes <= shortWindowCutoffMinutes }

// DefaultCodexRoot is where the Codex CLI writes session transcripts.
func DefaultCodexRoot() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".codex", "sessions")
}

// DefaultGrokLog is the Grok CLI's unified log, which carries its
// billing/usage lines.
func DefaultGrokLog() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".grok", "logs", "unified.jsonl")
}
```

`tui/internal/planlimits/codex.go`:

```go
package planlimits

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// codexScanMaxAge bounds the walk. The longest window Codex reports is
// 7 days, so an observation older than this cannot describe a live
// window and is not worth reading.
const codexScanMaxAge = 8 * 24 * time.Hour

// codexScanMaxFiles caps the walk on very large corpora. Files are
// visited newest-first, so the cap only ever drops observations that
// are older than ones already found.
const codexScanMaxFiles = 50

type codexLine struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Payload   struct {
		Type       string `json:"type"`
		RateLimits *struct {
			LimitID   string      `json:"limit_id"`
			PlanType  string      `json:"plan_type"`
			Primary   *codexSlot  `json:"primary"`
			Secondary *codexSlot  `json:"secondary"`
		} `json:"rate_limits"`
	} `json:"payload"`
}

type codexSlot struct {
	UsedPercent   float64 `json:"used_percent"`
	WindowMinutes int     `json:"window_minutes"`
	ResetsAt      int64   `json:"resets_at"`
}

// ScanCodex returns the most recent utilisation observation for each
// window Codex reports.
//
// The slot names are NOT stable across Codex CLI versions: older builds
// put the 5-hour window in `primary` and the weekly in `secondary`;
// newer ones put the weekly in `primary` and omit the 5-hour window
// entirely. `limit_id` varies too ("codex", "premium"). Keying on
// window_minutes is therefore the only reliable identity.
//
// A missing or unreadable root is not an error — these are optional
// inputs and their absence simply means no rows.
func ScanCodex(root string, now time.Time) ([]Gauge, error) {
	if root == "" {
		return nil, nil
	}
	files, err := codexFiles(root, now)
	if err != nil || len(files) == 0 {
		return nil, nil
	}

	// window_minutes -> newest observation seen so far.
	best := map[int]Gauge{}
	bestAt := map[int]time.Time{}

	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			continue // unreadable file: keep scanning the rest
		}
		sc := bufio.NewScanner(fh)
		sc.Buffer(make([]byte, 0, 1024*1024), 16*1024*1024)
		for sc.Scan() {
			raw := sc.Bytes()
			// Cheap reject before the JSON parse: the vast majority of
			// lines in a session transcript carry no rate limits.
			if !strings.Contains(string(raw), `"rate_limits"`) {
				continue
			}
			var l codexLine
			if err := json.Unmarshal(raw, &l); err != nil {
				continue // malformed line: skip, partial data beats none
			}
			if l.Payload.Type != "token_count" || l.Payload.RateLimits == nil {
				continue
			}
			obs, err := time.Parse(time.RFC3339, l.Timestamp)
			if err != nil {
				continue
			}
			rl := l.Payload.RateLimits
			for _, slot := range []*codexSlot{rl.Primary, rl.Secondary} {
				if slot == nil || slot.WindowMinutes <= 0 {
					continue
				}
				if prev, ok := bestAt[slot.WindowMinutes]; ok && !obs.After(prev) {
					continue
				}
				resets := time.Unix(slot.ResetsAt, 0)
				bestAt[slot.WindowMinutes] = obs
				best[slot.WindowMinutes] = Gauge{
					Vendor:    "codex",
					WindowLbl: WindowLabel(slot.WindowMinutes),
					Pct:       slot.UsedPercent,
					ResetsAt:  resets,
					Observed:  obs,
					Stale:     resets.Before(now),
					Plan:      rl.PlanType,
				}
			}
		}
		fh.Close()
	}

	mins := make([]int, 0, len(best))
	for m := range best {
		mins = append(mins, m)
	}
	sort.Ints(mins) // shortest window first, so 5h precedes 7d
	out := make([]Gauge, 0, len(mins))
	for _, m := range mins {
		out = append(out, best[m])
	}
	return out, nil
}

// codexFiles lists session transcripts newest-first, dropping anything
// older than the longest window Codex reports.
func codexFiles(root string, now time.Time) ([]string, error) {
	type entry struct {
		path string
		mod  time.Time
	}
	var entries []entry
	cutoff := now.Add(-codexScanMaxAge)

	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable subtree: skip it, keep walking
		}
		if d.IsDir() || !strings.HasSuffix(p, ".jsonl") {
			return nil
		}
		info, err := d.Info()
		if err != nil || info.ModTime().Before(cutoff) {
			return nil
		}
		entries = append(entries, entry{p, info.ModTime()})
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].mod.After(entries[j].mod) })
	if len(entries) > codexScanMaxFiles {
		entries = entries[:codexScanMaxFiles]
	}
	out := make([]string, len(entries))
	for i, e := range entries {
		out[i] = e.path
	}
	return out, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && TZ=UTC go test ./internal/planlimits/ -v`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/planlimits/
git commit -m "feat(planlimits): Codex rate-limit scanner keyed on window_minutes

Codex slot names are not stable across CLI versions: older builds put the
5h window in primary and weekly in secondary, newer ones put weekly in
primary and drop the 5h window. Fixtures cover both layouts so the
key-on-window_minutes rule is a regression test, not a comment."
```

---

### Task 4: `planlimits` — the Grok scanner

**Files:**
- Create: `tui/internal/planlimits/grok.go`
- Create: `tui/internal/planlimits/testdata/grok_unified.jsonl`
- Test: `tui/internal/planlimits/grok_test.go`

**Interfaces:**
- Consumes: `planlimits.Gauge`, `planlimits.DefaultGrokLog` (Task 3).
- Produces: `planlimits.ScanGrok(path string, now time.Time) ([]Gauge, error)` returning at most one `Gauge` with `Vendor: "grok"`, `WindowLbl: "wk"`.

- [ ] **Step 1: Write the failing test**

Create `tui/internal/planlimits/testdata/grok_unified.jsonl` — note the interleaved noise lines and the two billing lines, of which the later must win:

```jsonl
{"ts":"2026-08-07T09:00:00.000Z","src":"grok-pager","lvl":"info","msg":"prompt.drain","ctx":{"kind":"prompt","remaining_in_queue":0}}
{"ts":"2026-08-07T10:00:00.000Z","src":"shell","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":9.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-31T20:00:10.825033+00:00","end":"2026-08-07T20:00:10.825033+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0}},"subscriptionTier":"SuperGrok"}}
{"ts":"2026-08-07T11:00:00.000Z","src":"shell","lvl":"info","msg":"turn.phase_transition","ctx":{}}
{"ts":"2026-08-07T12:00:00.000Z","src":"shell","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":14.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-31T20:00:10.825033+00:00","end":"2026-08-07T20:00:10.825033+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0}},"subscriptionTier":"SuperGrok"}}
```

Create `tui/internal/planlimits/grok_test.go`:

```go
package planlimits

import (
	"path/filepath"
	"testing"
	"time"
)

func grokFixture() string { return filepath.Join("testdata", "grok_unified.jsonl") }

func TestScanGrokTakesNewestBillingLine(t *testing.T) {
	// Period ends 2026-08-07T20:00Z; evaluate an hour before that.
	at := time.Date(2026, 8, 7, 19, 0, 0, 0, time.UTC)
	gs, err := ScanGrok(grokFixture(), at)
	if err != nil {
		t.Fatalf("ScanGrok: %v", err)
	}
	if len(gs) != 1 {
		t.Fatalf("want 1 gauge, got %d: %+v", len(gs), gs)
	}
	g := gs[0]
	if g.Pct != 14 {
		t.Fatalf("Pct = %v, want 14 (the later billing line wins)", g.Pct)
	}
	if g.Vendor != "grok" || g.WindowLbl != "wk" {
		t.Fatalf("vendor/label wrong: %+v", g)
	}
	if g.Plan != "SuperGrok" {
		t.Fatalf("Plan = %q, want SuperGrok", g.Plan)
	}
	if g.Stale {
		t.Fatal("period has not ended yet, must not be stale")
	}
}

// Grok's period is vendor-anchored (Thursday 20:00 UTC). Once it closes,
// the percentage describes a window that has ended and must not read as
// current.
func TestScanGrokMarksClosedPeriodStale(t *testing.T) {
	at := time.Date(2026, 8, 8, 9, 0, 0, 0, time.UTC)
	gs, err := ScanGrok(grokFixture(), at)
	if err != nil {
		t.Fatalf("ScanGrok: %v", err)
	}
	if len(gs) != 1 || !gs[0].Stale {
		t.Fatalf("closed period must be Stale, got %+v", gs)
	}
}

func TestScanGrokMissingLogIsNotAnError(t *testing.T) {
	gs, err := ScanGrok(filepath.Join(t.TempDir(), "absent.jsonl"), time.Now())
	if err != nil {
		t.Fatalf("absent log must not error, got %v", err)
	}
	if len(gs) != 0 {
		t.Fatalf("absent log must yield no gauges, got %+v", gs)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/planlimits/ -run TestScanGrok -v`
Expected: FAIL — `undefined: ScanGrok`.

- [ ] **Step 3: Write minimal implementation**

```go
package planlimits

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
	"time"
)

// grokBillingMarker is the log message that carries the usage figure.
const grokBillingMarker = "billing: fetched credits config"

type grokLine struct {
	TS  string `json:"ts"`
	Msg string `json:"msg"`
	Ctx struct {
		Config struct {
			CreditUsagePercent float64 `json:"creditUsagePercent"`
			CurrentPeriod      struct {
				Type  string `json:"type"`
				Start string `json:"start"`
				End   string `json:"end"`
			} `json:"currentPeriod"`
		} `json:"config"`
		SubscriptionTier string `json:"subscriptionTier"`
	} `json:"ctx"`
}

// ScanGrok returns Grok's weekly utilisation, or nothing.
//
// Grok reports only a weekly billing period — every observed period was
// USAGE_PERIOD_TYPE_WEEKLY — and it is vendor-anchored (Thursday 20:00
// UTC), so it aligns with neither the ISO week nor Codex's 7-day rolling
// window. It is never reconciled with either.
//
// Grok's session transcripts are deliberately NOT read: they carry only
// a cumulative per-prompt context total, which is not billable tokens,
// and they are where all the corpus size is.
func ScanGrok(path string, now time.Time) ([]Gauge, error) {
	if path == "" {
		return nil, nil
	}
	fh, err := os.Open(path)
	if err != nil {
		return nil, nil // absent log is a normal state, not a failure
	}
	defer fh.Close()

	var newest *Gauge
	var newestAt time.Time

	sc := bufio.NewScanner(fh)
	sc.Buffer(make([]byte, 0, 256*1024), 4*1024*1024)
	for sc.Scan() {
		raw := sc.Text()
		// Substring reject first: only ~105 of many thousands of lines
		// are billing lines, so this avoids parsing almost all of them.
		if !strings.Contains(raw, grokBillingMarker) {
			continue
		}
		var l grokLine
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			continue
		}
		if l.Msg != grokBillingMarker {
			continue
		}
		obs, err := time.Parse(time.RFC3339, l.TS)
		if err != nil {
			continue
		}
		if newest != nil && !obs.After(newestAt) {
			continue
		}
		end, err := time.Parse(time.RFC3339, l.Ctx.Config.CurrentPeriod.End)
		if err != nil {
			continue
		}
		newestAt = obs
		newest = &Gauge{
			Vendor:    "grok",
			WindowLbl: "wk",
			Pct:       l.Ctx.Config.CreditUsagePercent,
			ResetsAt:  end,
			Observed:  obs,
			Stale:     end.Before(now),
			Plan:      l.Ctx.SubscriptionTier,
		}
	}
	if newest == nil {
		return nil, nil
	}
	return []Gauge{*newest}, nil
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && TZ=UTC go test ./internal/planlimits/ -v`
Expected: PASS — 8 tests total across both scanners.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/planlimits/grok.go tui/internal/planlimits/grok_test.go tui/internal/planlimits/testdata/grok_unified.jsonl
git commit -m "feat(planlimits): Grok weekly utilisation from unified.jsonl

Reads creditUsagePercent from the newest 'billing: fetched credits
config' line. The billing period is vendor-anchored (Thu 20:00 UTC) so a
closed period is marked stale rather than shown as current. Grok session
transcripts are not read at all - they hold no billable-token signal."
```

---

### Task 5: Renderer — row construction and the two gauge groups

**Files:**
- Create: `tui/internal/ui/gauges.go`
- Test: `tui/internal/ui/gauges_test.go`

**Interfaces:**
- Consumes: `limits.Status`, `limits.StateUnset`, `limits.WindowDay`, `limits.WindowWeek` (Task 2); `planlimits.Gauge` (Tasks 3–4); existing `ui.FormatUSD(float64) string` from `tui/internal/ui/format.go`.
- Produces: `ui.Band` (`BandShort`, `BandWeekly`); `ui.Segment{Label string; USD float64; Style lipgloss.Style}`; `ui.Row{Vendor, WindowLbl string; Budget *limits.Status; Segments []Segment; Plan *planlimits.Gauge; NotApplicable string}`; `ui.BuildRows(band Band, st []limits.Status, gs []planlimits.Gauge) []Row`; `ui.RenderGauges(st []limits.Status, gs []planlimits.Gauge) string`; `ui.WorstPct(st []limits.Status, gs []planlimits.Gauge) float64`.

- [ ] **Step 1: Write the failing test**

```go
package ui

import (
	"strings"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/planlimits"
)

func statuses() []limits.Status {
	return []limits.Status{
		{Window: limits.WindowDay, SpentUSD: 39, LimitUSD: 50, Pct: 78, State: limits.StateOK},
		{Window: limits.WindowWeek, SpentUSD: 130, LimitUSD: 250, Pct: 52, State: limits.StateOK},
	}
}

func gauges() []planlimits.Gauge {
	return []planlimits.Gauge{
		{Vendor: "codex", WindowLbl: "5h", Pct: 92, ResetsAt: time.Now().Add(2 * time.Hour)},
		{Vendor: "codex", WindowLbl: "7d", Pct: 100, ResetsAt: time.Now().Add(48 * time.Hour)},
		{Vendor: "grok", WindowLbl: "wk", Pct: 14, ResetsAt: time.Now().Add(6 * time.Hour)},
	}
}

func vendors(rows []Row) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.Vendor
	}
	return out
}

// Display order is fixed regardless of value, so a vendor never moves
// between refreshes and the popover cannot disagree with the TUI.
func TestBuildRowsFixedDisplayOrder(t *testing.T) {
	rows := BuildRows(BandShort, statuses(), gauges())
	got := strings.Join(vendors(rows), ",")
	if got != "claude,codex,grok" {
		t.Fatalf("order = %q, want claude,codex,grok", got)
	}
}

// Grok reports no short window. That gap must be visible, not an absent
// row that reads as "no usage".
func TestBuildRowsSynthesisesNotApplicable(t *testing.T) {
	rows := BuildRows(BandShort, statuses(), gauges())
	last := rows[len(rows)-1]
	if last.Vendor != "grok" || last.NotApplicable == "" {
		t.Fatalf("grok short-window row must be n/a, got %+v", last)
	}
	if last.Plan != nil {
		t.Fatal("an n/a row must carry no gauge")
	}
}

// A vendor that is not installed at all is omitted entirely — only a
// vendor present in another band gets the n/a placeholder.
func TestBuildRowsOmitsAbsentVendor(t *testing.T) {
	only := []planlimits.Gauge{{Vendor: "codex", WindowLbl: "5h", Pct: 10, ResetsAt: time.Now().Add(time.Hour)}}
	rows := BuildRows(BandShort, statuses(), only)
	if got := strings.Join(vendors(rows), ","); got != "claude,codex" {
		t.Fatalf("order = %q, want claude,codex (grok not installed)", got)
	}
}

func TestBuildRowsOmitsUnsetBudget(t *testing.T) {
	unset := []limits.Status{
		{Window: limits.WindowDay, State: limits.StateUnset},
		{Window: limits.WindowWeek, State: limits.StateUnset},
	}
	rows := BuildRows(BandShort, unset, gauges())
	if got := strings.Join(vendors(rows), ","); got != "codex,grok" {
		t.Fatalf("order = %q, want codex,grok (no budget configured)", got)
	}
}

// The band title groups by rough duration; each row still carries its
// own window label, because the weekly band mixes an ISO week, a 7-day
// rolling window and a Thu-Thu billing period.
func TestRenderGaugesAlwaysLabelsWindows(t *testing.T) {
	out := RenderGauges(statuses(), gauges())
	for _, want := range []string{"short window", "weekly", "daily", "5h", "7d", "wk", "$39", "$50"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

// Escalation is value-ordered over non-stale rows only. A stale 100%
// must never win, or an expired window paints the menu bar red.
func TestWorstPctIgnoresStale(t *testing.T) {
	gs := []planlimits.Gauge{
		{Vendor: "codex", WindowLbl: "7d", Pct: 100, Stale: true},
		{Vendor: "grok", WindowLbl: "wk", Pct: 14},
	}
	if got := WorstPct(statuses(), gs); got != 78 {
		t.Fatalf("WorstPct = %v, want 78 (stale 100 excluded, day budget wins)", got)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./internal/ui/ -run 'TestBuildRows|TestRenderGauges|TestWorstPct' -v`
Expected: FAIL — `undefined: BuildRows`, `undefined: BandShort`, `undefined: RenderGauges`, `undefined: WorstPct`.

- [ ] **Step 3: Write minimal implementation**

```go
package ui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"

	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/planlimits"
)

// Band groups rows by rough duration. A band title is NOT an assertion
// that its rows share a window definition: the weekly band holds an ISO
// week, Codex's 7-day rolling window and Grok's Thursday-anchored
// billing period. Each row therefore always renders its own window
// label, which is what stops the grouping reading as "these numbers
// disagree, it's a bug".
type Band int

const (
	BandShort Band = iota
	BandWeekly
)

// displayOrder is the fixed vendor order within every band. It does not
// depend on values, so rows never reorder between refreshes. Glyph
// escalation uses a different, value-dependent order — see WorstPct.
var displayOrder = []string{"claude", "codex", "grok"}

const gaugeCells = 10

var (
	styleBarFill = lipgloss.NewStyle().Foreground(lipgloss.Color("10"))
	styleBarWarn = lipgloss.NewStyle().Foreground(lipgloss.Color("11"))
	styleBarOver = lipgloss.NewStyle().Foreground(lipgloss.Color("9"))
	styleStale   = lipgloss.NewStyle().Foreground(lipgloss.Color("240"))
)

// Segment is one stacked slice of a budget bar. Spec 1 emits a single
// Claude segment; the Codex USD segment is added later without changing
// the renderer.
type Segment struct {
	Label string
	USD   float64
	Style lipgloss.Style
}

// Row is one rendered line. Exactly one of Budget, Plan or NotApplicable
// is meaningful.
type Row struct {
	Vendor        string
	WindowLbl     string
	Budget        *limits.Status
	Segments      []Segment
	Plan          *planlimits.Gauge
	NotApplicable string
}

// BuildRows assembles one band's rows in fixed display order,
// synthesising an "n/a" placeholder for a vendor that is installed but
// reports nothing in this band. A vendor absent altogether is omitted:
// showing n/a for a tool you do not use would be noise, while hiding a
// real gap would read as zero usage.
func BuildRows(band Band, st []limits.Status, gs []planlimits.Gauge) []Row {
	installed := map[string]bool{}
	for _, g := range gs {
		installed[g.Vendor] = true
	}

	var rows []Row
	for _, vendor := range displayOrder {
		if vendor == "claude" {
			if s := budgetFor(band, st); s != nil {
				rows = append(rows, Row{
					Vendor:    "claude",
					WindowLbl: s.Window.String(),
					Budget:    s,
					Segments:  []Segment{{Label: "claude", USD: s.SpentUSD, Style: styleBarFill}},
				})
			}
			continue
		}
		if !installed[vendor] {
			continue
		}
		matched := false
		for i := range gs {
			g := gs[i]
			if g.Vendor != vendor || bandOf(g) != band {
				continue
			}
			rows = append(rows, Row{Vendor: vendor, WindowLbl: g.WindowLbl, Plan: &gs[i]})
			matched = true
		}
		if !matched {
			rows = append(rows, Row{
				Vendor:        vendor,
				WindowLbl:     "—",
				NotApplicable: naReason(band),
			})
		}
	}
	return rows
}

func naReason(band Band) string {
	if band == BandShort {
		return "weekly only"
	}
	return "no weekly window"
}

// bandOf places a gauge by its label: anything measured in hours is a
// short window, anything in days is weekly.
func bandOf(g planlimits.Gauge) Band {
	if strings.HasSuffix(g.WindowLbl, "h") {
		return BandShort
	}
	return BandWeekly
}

func budgetFor(band Band, st []limits.Status) *limits.Status {
	want := limits.WindowDay
	if band == BandWeekly {
		want = limits.WindowWeek
	}
	for i := range st {
		if st[i].Window == want && st[i].State != limits.StateUnset {
			return &st[i]
		}
	}
	return nil
}

// RenderGauges draws both bands. Rows are grouped by duration because
// "how close am I to a wall in the next few hours" spans both budget and
// plan numbers.
func RenderGauges(st []limits.Status, gs []planlimits.Gauge) string {
	var b strings.Builder
	b.WriteString(renderGaugeGroup("short window", BuildRows(BandShort, st, gs)))
	b.WriteString(renderGaugeGroup("weekly", BuildRows(BandWeekly, st, gs)))
	return b.String()
}

func renderGaugeGroup(title string, rows []Row) string {
	if len(rows) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString(styleDim.Render("── "+title+" ") + "\n")
	for _, r := range rows {
		b.WriteString(renderRow(r) + "\n")
	}
	return b.String()
}

func renderRow(r Row) string {
	label := fmt.Sprintf(" %-7s %-5s", r.Vendor, r.WindowLbl)

	if r.NotApplicable != "" {
		return styleStale.Render(label + " n/a (" + r.NotApplicable + ")")
	}

	var pct float64
	var detail string
	var stale bool
	switch {
	case r.Budget != nil:
		pct = r.Budget.Pct
		// The detail column is what distinguishes a budget percentage
		// from a plan percentage: money on one, a reset clock on the other.
		detail = fmt.Sprintf("%s/%s", FormatUSD(r.Budget.SpentUSD), FormatUSD(r.Budget.LimitUSD))
	case r.Plan != nil:
		pct = r.Plan.Pct
		stale = r.Plan.Stale
		if stale {
			detail = "stale · ended " + shortWhen(r.Plan.ResetsAt)
		} else {
			detail = "↻ " + shortWhen(r.Plan.ResetsAt)
		}
	default:
		return label
	}

	line := label + " " + bar(pct, stale) + fmt.Sprintf(" %3.0f%%  %s", pct, detail)
	if stale {
		return styleStale.Render(label + " " + plainBar(pct) + fmt.Sprintf(" %3.0f%%  %s", pct, detail))
	}
	if pct >= 100 {
		line += " ⚠"
	}
	return line
}

func bar(pct float64, stale bool) string {
	s := plainBar(pct)
	switch {
	case stale:
		return styleStale.Render(s)
	case pct >= 100:
		return styleBarOver.Render(s)
	case pct >= 80:
		return styleBarWarn.Render(s)
	default:
		return styleBarFill.Render(s)
	}
}

func plainBar(pct float64) string {
	filled := int(pct/100*gaugeCells + 0.5)
	if filled < 0 {
		filled = 0
	}
	if filled > gaugeCells {
		filled = gaugeCells
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", gaugeCells-filled)
}

func shortWhen(t time.Time) string {
	d := time.Until(t)
	switch {
	case d <= 0:
		return t.Local().Format("Mon")
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	default:
		return t.Local().Format("Mon")
	}
}

// WorstPct is the highest utilisation across every non-stale row in both
// bands. This drives menu bar escalation, and it is deliberately a
// different ordering from displayOrder: an expired window must never
// paint the menu bar red.
func WorstPct(st []limits.Status, gs []planlimits.Gauge) float64 {
	worst := 0.0
	for _, s := range st {
		if s.State != limits.StateUnset && s.Pct > worst {
			worst = s.Pct
		}
	}
	for _, g := range gs {
		if !g.Stale && g.Pct > worst {
			worst = g.Pct
		}
	}
	return worst
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd tui && TZ=UTC go test ./internal/ui/ -v`
Expected: PASS — the new tests plus all pre-existing `ui` tests.

- [ ] **Step 5: Commit**

```bash
git add tui/internal/ui/gauges.go tui/internal/ui/gauges_test.go
git commit -m "feat(ui): two-band gauge renderer with fixed row order

Rows group by duration band, not by budget-vs-plan, because 'how close am
I to a wall right now' spans both. Every row renders its own window label
since a band title is not a shared window definition. Display order is
fixed; WorstPct is separately value-ordered over non-stale rows only."
```

---

### Task 6: TUI wiring and the `--limits` flag

**Files:**
- Create: `tui/cmd/claudecounter/limits_cli.go`
- Modify: `tui/cmd/claudecounter/main.go:44-57` (flag block), the one-shot dispatch block at `main.go:65-86`, and `runOnce` at `main.go:101-131` (extract `scanSnapshot`)
- Modify: `tui/internal/ui/view_minimal.go:41-66` (`viewMinimal`)
- Modify: `tui/internal/ui/model.go` (carry gauge data on the model)
- Test: `tui/cmd/claudecounter/limits_cli_test.go`

**Interfaces:**
- Consumes: `limits.Load`, `limits.DefaultConfigPath`, `limits.Evaluate` (Tasks 1–2); `planlimits.ScanCodex`, `planlimits.ScanGrok`, `planlimits.DefaultCodexRoot`, `planlimits.DefaultGrokLog` (Tasks 3–4); `ui.RenderGauges` (Task 5); existing `agg.Totals.Daily`.
- Produces: `gatherGauges(cfgPath string, daily []agg.DailyTotal, now time.Time) (string, error)` and `scanSnapshot(root string, table pricing.Table) agg.Totals` in package `main`; `--limits` and `--limits-config` flags.

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

func TestGatherGaugesRendersConfiguredBudget(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "limits.toml")
	if err := os.WriteFile(cfg, []byte("[limits]\ndaily = 50.0\nweekly = 250.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 7, 12, 0, 0, 0, time.UTC)
	daily := []agg.DailyTotal{{Day: "2026-08-07", USD: 39}}

	out, err := gatherGauges(cfg, daily, now)
	if err != nil {
		t.Fatalf("gatherGauges: %v", err)
	}
	for _, want := range []string{"short window", "claude", "daily", "78%"} {
		if !strings.Contains(out, want) {
			t.Errorf("output missing %q:\n%s", want, out)
		}
	}
}

// With no config and no vendor logs there is nothing to draw. The caller
// must get empty output rather than an error or an empty-looking gauge.
func TestGatherGaugesUnconfiguredIsEmpty(t *testing.T) {
	out, err := gatherGauges(filepath.Join(t.TempDir(), "absent.toml"), nil, time.Now())
	if err != nil {
		t.Fatalf("unconfigured must not error, got %v", err)
	}
	if strings.TrimSpace(out) != "" {
		t.Fatalf("unconfigured must render nothing, got:\n%s", out)
	}
}

// A malformed config must not take the gauge down silently AND must not
// break the caller: it reports the error, and the caller decides.
func TestGatherGaugesMalformedConfigErrors(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "limits.toml")
	if err := os.WriteFile(cfg, []byte("[limits]\ndaily = = =\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := gatherGauges(cfg, nil, time.Now()); err == nil {
		t.Fatal("malformed config must return an error")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd tui && TZ=UTC go test ./cmd/claudecounter/ -run TestGatherGauges -v`
Expected: FAIL — `undefined: gatherGauges`.

- [ ] **Step 3: Write minimal implementation**

Create `tui/cmd/claudecounter/limits_cli.go`:

```go
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
	"github.com/jverhoeks/claudecounter/tui/internal/limits"
	"github.com/jverhoeks/claudecounter/tui/internal/planlimits"
	"github.com/jverhoeks/claudecounter/tui/internal/ui"
)

// gatherGauges evaluates budgets and scans the vendor logs, returning the
// rendered gauge block. Vendor scans never fail the call — an absent CLI
// is the common case — but a malformed config does surface, so a typo in
// limits.toml is not mistaken for "no limits set".
func gatherGauges(cfgPath string, daily []agg.DailyTotal, now time.Time) (string, error) {
	cfg, err := limits.Load(cfgPath)
	if err != nil {
		return "", fmt.Errorf("limits config: %w", err)
	}
	st := limits.Evaluate(daily, cfg, now)

	var gs []planlimits.Gauge
	if codex, err := planlimits.ScanCodex(planlimits.DefaultCodexRoot(), now); err == nil {
		gs = append(gs, codex...)
	}
	if grok, err := planlimits.ScanGrok(planlimits.DefaultGrokLog(), now); err == nil {
		gs = append(gs, grok...)
	}
	return ui.RenderGauges(st, gs), nil
}

// runLimits is the --limits one-shot: scan, print the gauges, exit.
func runLimits(root string, table pricing.Table, cfgPath string) {
	snap := scanSnapshot(root, table)
	out, err := gatherGauges(cfgPath, snap.Daily, time.Now())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if out == "" {
		fmt.Println("No limits configured and no vendor plan data found.")
		fmt.Println("Set limits in " + limits.DefaultConfigPath())
		return
	}
	fmt.Print(out)
}
```

> **Required refactor first — there is no existing helper to reuse.** `runOnce` (`tui/cmd/claudecounter/main.go:101-131`) inlines its scan. Extract lines 105–126 (channel setup, `reader.New`, `agg.New`, the apply goroutine, `InitialScan` with `scanCutoff`, `close`/wait, `a.Snapshot()`) into a named helper in `main.go`, with no behaviour change:
>
> ```go
> // scanSnapshot does a single full scan and returns the aggregated
> // totals. Shared by --once and --limits so both see identical numbers.
> func scanSnapshot(root string, table pricing.Table) agg.Totals {
> 	evCh := make(chan reader.Event, 1024)
> 	r := reader.New(evCh)
> 	a := agg.New(table)
>
> 	done := make(chan struct{})
> 	go func() {
> 		defer close(done)
> 		for e := range evCh {
> 			a.Apply(e)
> 		}
> 	}()
>
> 	notBefore := scanCutoff(time.Now().Local())
> 	if err := r.InitialScan(root, notBefore); err != nil {
> 		log.Fatalf("initial scan: %v", err)
> 	}
> 	close(evCh)
> 	<-done
> 	return a.Snapshot()
> }
> ```
>
> Then rewrite `runOnce` to call it, keeping its own stderr progress lines, `a.Dupes()` and `r.ParseErrors()` reporting. Since `Dupes`/`ParseErrors` live on the aggregator and reader, `runOnce` needs those values too — either widen the helper's return to `(agg.Totals, int, int)` and have `runLimits` ignore the last two, or leave `runOnce` as-is and have `scanSnapshot` be the shared core it delegates to. Pick one and keep `--once` output byte-identical; verify with `go test ./cmd/claudecounter/` (there is an existing `integration_test.go`).

In `main.go`, add to the flag block after `phasesFlag` (`main.go:56`):

```go
	limitsFlag := flag.Bool("limits", false, "scan once, print budget and plan-limit gauges, and exit")
	limitsPath := flag.String("limits-config", limits.DefaultConfigPath(), "path to limits.toml")
```

And in the one-shot dispatch block, alongside the existing `*phasesFlag` / `*safetyFlag` branches:

```go
	if *limitsFlag {
		runLimits(*root, table, *limitsPath)
		return
	}
```

In `tui/internal/ui/view_minimal.go`, render the gauges under the two headline lines. Change `viewMinimal(t agg.Totals) string` to `viewMinimal(t agg.Totals, gauges string) string` and insert after the Month line:

```go
	if gauges != "" {
		b.WriteString(gauges)
	}
```

In `tui/internal/ui/model.go`, add a `Gauges string` field to the model struct, set it wherever the model refreshes its snapshot, and pass it through at the `viewMinimal(...)` and `viewSplit(...)` call sites.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tui && TZ=UTC go test ./... && go vet ./...`
Expected: PASS — all packages; `go vet` clean. Existing `viewMinimal` tests will need their call sites updated to pass `""`.

Then verify the flag end-to-end:

Run: `cd tui && go build -o /tmp/cc ./cmd/claudecounter && /tmp/cc --limits`
Expected: either a rendered gauge block, or the "No limits configured…" message if you have no `limits.toml` — both are correct outcomes.

- [ ] **Step 5: Commit**

```bash
git add tui/cmd/claudecounter/ tui/internal/ui/
git commit -m "feat(tui): --limits one-shot and in-view gauge block

Vendor scans never fail the call since an absent CLI is the common case,
but a malformed limits.toml does surface so a typo is not mistaken for
'no limits set'."
```

---

### Task 7: macapp — `Limits.swift`

**Files:**
- Create: `macapp/Sources/ClaudeCounterCore/Limits.swift`
- Test: `macapp/Tests/ClaudeCounterCoreTests/LimitsTests.swift`

**Interfaces:**
- Consumes: nothing from the Go tasks at runtime — this is an independent implementation whose behaviour is pinned to Go's by Task 10.
- Produces: `LimitsConfig{daily, weekly: Double; warnPct: Int}` with `static let defaultWarnPct = 80`; `LimitWindow` enum (`.day`, `.week`) with `label: String`; `LimitState` enum (`.unset`, `.ok`, `.warn`, `.over`) with `rawValue` strings matching Go's `State.String()`; `LimitStatus{window, spentUSD, limitUSD, pct, state, resetsAt}`; `Limits.load(path:) throws -> LimitsConfig`; `Limits.defaultConfigPath() -> String`; `Limits.evaluate(daily:config:now:calendar:) -> [LimitStatus]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeCounterCore

final class LimitsTests: XCTestCase {

    // Pin the calendar to UTC + ISO-8601 so week boundaries are
    // deterministic and match the Go implementation.
    private var utc: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: s)!
    }

    private var week: [DailyTotal] {
        [
            DailyTotal(day: "2026-08-03", usd: 10, tokens: 0),
            DailyTotal(day: "2026-08-06", usd: 20, tokens: 0),
            DailyTotal(day: "2026-08-07", usd: 39, tokens: 0),
            DailyTotal(day: "2026-08-02", usd: 99, tokens: 0), // previous ISO week
        ]
    }

    func test_evaluate_dayUsesCalendarDay() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[0].window, .day)
        XCTAssertEqual(got[0].spentUSD, 39, accuracy: 0.0001)
        XCTAssertEqual(got[0].pct, 78, accuracy: 0.0001)
        XCTAssertEqual(got[0].state, .ok)
    }

    func test_evaluate_weekExcludesPreviousISOWeek() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[1].spentUSD, 69, accuracy: 0.0001)
    }

    func test_evaluate_exactlyAtLimitIsOver() {
        let got = Limits.evaluate(daily: [DailyTotal(day: "2026-08-07", usd: 50, tokens: 0)],
                                  config: LimitsConfig(daily: 50, weekly: 0, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[0].state, .over)
    }

    func test_evaluate_unsetLimitYieldsNoPercentage() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 0, weekly: 250, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[0].state, .unset)
        XCTAssertEqual(got[0].pct, 0, accuracy: 0.0001)
        XCTAssertNotEqual(got[1].state, .unset)
    }

    func test_load_missingFileIsNotAnError() throws {
        let path = NSTemporaryDirectory() + "/absent-\(UUID().uuidString).toml"
        let cfg = try Limits.load(path: path)
        XCTAssertEqual(cfg.daily, 0)
        XCTAssertEqual(cfg.weekly, 0)
    }

    func test_load_parsesLimitsAndDefaultsWarnPct() throws {
        let path = NSTemporaryDirectory() + "/limits-\(UUID().uuidString).toml"
        try "[limits]\ndaily = 50.0\nweekly = 250.0\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = try Limits.load(path: path)
        XCTAssertEqual(cfg.daily, 50)
        XCTAssertEqual(cfg.weekly, 250)
        XCTAssertEqual(cfg.warnPct, LimitsConfig.defaultWarnPct)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make macapp-test`
Expected: FAIL — `cannot find 'Limits' in scope`, `cannot find type 'LimitsConfig' in scope`.

> **Verified:** `DailyTotal` exists at `macapp/Sources/ClaudeCounterCore/Aggregator.swift:71` with members `day: String`, `usd: Double`, `tokens: UInt64`, plus `usdByModel`, `tokensByModel` and `hourlyUSDByModel`. All three extra members have defaults in the memberwise init, so `DailyTotal(day:usd:tokens:)` as used above compiles unchanged.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Mirrors `tui/internal/limits` in Go. The two implementations are
/// independent but their behaviour is pinned together by the shared
/// parity fixture — see `LimitsParityTests`.
public struct LimitsConfig: Equatable, Sendable {
    public static let defaultWarnPct = 80

    public var daily: Double
    public var weekly: Double
    public var warnPct: Int

    public init(daily: Double = 0, weekly: Double = 0, warnPct: Int = LimitsConfig.defaultWarnPct) {
        self.daily = daily
        self.weekly = weekly
        self.warnPct = warnPct <= 0 ? LimitsConfig.defaultWarnPct : warnPct
    }
}

public enum LimitWindow: String, Sendable {
    case day, week
    /// Matches Go's `Window.String()` so rendered labels agree.
    public var label: String { self == .week ? "wk" : "daily" }
}

/// Raw values match Go's `State.String()` exactly — the parity fixture
/// compares them as strings.
public enum LimitState: String, Sendable {
    case unset, ok, warn, over
}

public struct LimitStatus: Equatable, Sendable {
    public var window: LimitWindow
    public var spentUSD: Double
    public var limitUSD: Double
    public var pct: Double
    public var state: LimitState
    public var resetsAt: Date
}

public enum Limits {

    public static func defaultConfigPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/claudecounter/limits.toml")
    }

    /// Reads limits.toml. A missing file yields zero limits and no error:
    /// that is the normal unconfigured state. Malformed content throws so
    /// the caller can surface it once.
    public static func load(path: String) throws -> LimitsConfig {
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            return LimitsConfig(daily: 0, weekly: 0)
        }
        var daily = 0.0, weekly = 0.0, warn = 0
        var inSection = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                inSection = (line == "[limits]")
                continue
            }
            guard inSection else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[1].isEmpty else {
                throw LimitsError.malformed(line)
            }
            switch parts[0] {
            case "daily":
                guard let v = Double(parts[1]) else { throw LimitsError.malformed(line) }
                daily = v
            case "weekly":
                guard let v = Double(parts[1]) else { throw LimitsError.malformed(line) }
                weekly = v
            case "warn_pct":
                guard let v = Int(parts[1]) else { throw LimitsError.malformed(line) }
                warn = v
            default:
                continue
            }
        }
        return LimitsConfig(daily: daily, weekly: weekly, warnPct: warn)
    }

    /// Pure evaluation, always returning exactly two statuses, day first.
    public static func evaluate(daily: [DailyTotal],
                                config: LimitsConfig,
                                now: Date,
                                calendar: Calendar) -> [LimitStatus] {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"

        let todayKey = f.string(from: now)
        let nowWeek = calendar.component(.weekOfYear, from: now)
        let nowYear = calendar.component(.yearForWeekOfYear, from: now)

        var daySpent = 0.0, weekSpent = 0.0
        for d in daily {
            if d.day == todayKey { daySpent += d.usd }
            guard let t = f.date(from: d.day) else { continue }
            // Compare ISO week AND the ISO week-year: a week straddling
            // 31 Dec belongs to one bucket, not two.
            if calendar.component(.weekOfYear, from: t) == nowWeek,
               calendar.component(.yearForWeekOfYear, from: t) == nowYear {
                weekSpent += d.usd
            }
        }

        return [
            build(.day, daySpent, config.daily, config.warnPct, nextMidnight(now, calendar)),
            build(.week, weekSpent, config.weekly, config.warnPct, nextWeekStart(now, calendar)),
        ]
    }

    private static func build(_ window: LimitWindow,
                              _ spent: Double,
                              _ limit: Double,
                              _ warnPct: Int,
                              _ resets: Date) -> LimitStatus {
        guard limit > 0 else {
            return LimitStatus(window: window, spentUSD: spent, limitUSD: limit,
                               pct: 0, state: .unset, resetsAt: resets)
        }
        let pct = 100 * spent / limit
        let state: LimitState = pct >= 100 ? .over : (pct >= Double(warnPct) ? .warn : .ok)
        return LimitStatus(window: window, spentUSD: spent, limitUSD: limit,
                           pct: pct, state: state, resetsAt: resets)
    }

    private static func nextMidnight(_ now: Date, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
    }

    private static func nextWeekStart(_ now: Date, _ cal: Calendar) -> Date {
        var c = cal
        c.firstWeekday = 2 // Monday, matching ISO-8601 and Go's ISOWeek
        let startOfWeek = c.dateInterval(of: .weekOfYear, for: now)?.start ?? c.startOfDay(for: now)
        return c.date(byAdding: .day, value: 7, to: startOfWeek) ?? now
    }
}

public enum LimitsError: Error, Equatable {
    case malformed(String)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make macapp-test`
Expected: PASS — 6 new tests plus the existing suite.

- [ ] **Step 5: Commit**

```bash
git add macapp/Sources/ClaudeCounterCore/Limits.swift macapp/Tests/ClaudeCounterCoreTests/LimitsTests.swift
git commit -m "feat(macapp): Limits.swift mirroring the Go limits engine

LimitState raw values match Go's State.String() so the shared parity
fixture can compare them as strings. Week grouping compares ISO week and
ISO week-year, matching Go's ISOWeek."
```

---

### Task 8: macapp — `PlanLimits.swift`

**Files:**
- Create: `macapp/Sources/ClaudeCounterCore/PlanLimits.swift`
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/codex_old_layout.jsonl` (copy of Task 3's fixture)
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/grok_unified.jsonl` (copy of Task 4's fixture)
- Test: `macapp/Tests/ClaudeCounterCoreTests/PlanLimitsTests.swift`

**Interfaces:**
- Consumes: nothing from earlier Swift tasks.
- Produces: `PlanGauge{vendor, windowLabel: String; pct: Double; resetsAt, observed: Date; stale: Bool; plan: String}`; `PlanLimits.windowLabel(minutes:) -> String`; `PlanLimits.scanCodex(root:now:) -> [PlanGauge]`; `PlanLimits.scanGrok(path:now:) -> [PlanGauge]`; `PlanLimits.defaultCodexRoot() -> String`; `PlanLimits.defaultGrokLog() -> String`.

- [ ] **Step 1: Write the failing test**

Copy the two Go fixtures verbatim so both languages parse byte-identical input:

```bash
cp tui/internal/planlimits/testdata/codex_old_layout.jsonl macapp/Tests/ClaudeCounterCoreTests/Fixtures/
cp tui/internal/planlimits/testdata/grok_unified.jsonl macapp/Tests/ClaudeCounterCoreTests/Fixtures/
```

Create `macapp/Tests/ClaudeCounterCoreTests/PlanLimitsTests.swift`:

```swift
import XCTest
@testable import ClaudeCounterCore

final class PlanLimitsTests: XCTestCase {

    private func fixtureURL(_ named: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: named, withExtension: nil, subdirectory: "Fixtures") else {
            throw XCTSkip("fixture \(named) not found")
        }
        return url
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: s)!
    }

    // Codex slot names vary by CLI version; the reader must key on
    // window_minutes. The old layout has 5h in primary, weekly in secondary.
    func test_scanCodex_oldLayoutKeysOnWindowMinutes() throws {
        let src = try fixtureURL("codex_old_layout.jsonl")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)/2026/08/07")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: root.appendingPathComponent("rollout-a.jsonl"))
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let gs = PlanLimits.scanCodex(root: root.deletingLastPathComponent().deletingLastPathComponent().path,
                                      now: date("2026-08-07T13:00:00Z"))
        let byLabel = Dictionary(uniqueKeysWithValues: gs.map { ($0.windowLabel, $0) })
        XCTAssertEqual(byLabel.count, 2)
        XCTAssertEqual(byLabel["5h"]?.pct, 92)
        XCTAssertEqual(byLabel["7d"]?.pct, 30)
        XCTAssertEqual(byLabel["5h"]?.plan, "plus")
    }

    func test_scanGrok_takesNewestBillingLine() throws {
        let url = try fixtureURL("grok_unified.jsonl")
        let gs = PlanLimits.scanGrok(path: url.path, now: date("2026-08-07T19:00:00Z"))
        XCTAssertEqual(gs.count, 1)
        XCTAssertEqual(gs[0].pct, 14)
        XCTAssertEqual(gs[0].vendor, "grok")
        XCTAssertEqual(gs[0].windowLabel, "wk")
        XCTAssertEqual(gs[0].plan, "SuperGrok")
        XCTAssertFalse(gs[0].stale)
    }

    func test_scanGrok_closedPeriodIsStale() throws {
        let url = try fixtureURL("grok_unified.jsonl")
        let gs = PlanLimits.scanGrok(path: url.path, now: date("2026-08-08T09:00:00Z"))
        XCTAssertEqual(gs.count, 1)
        XCTAssertTrue(gs[0].stale)
    }

    func test_missingSourcesYieldNothing() {
        XCTAssertTrue(PlanLimits.scanCodex(root: "/nonexistent-\(UUID().uuidString)", now: Date()).isEmpty)
        XCTAssertTrue(PlanLimits.scanGrok(path: "/nonexistent-\(UUID().uuidString)", now: Date()).isEmpty)
    }

    func test_windowLabel() {
        XCTAssertEqual(PlanLimits.windowLabel(minutes: 300), "5h")
        XCTAssertEqual(PlanLimits.windowLabel(minutes: 10080), "7d")
        XCTAssertEqual(PlanLimits.windowLabel(minutes: 1440), "24h")
    }
}
```

Register the new fixtures in `macapp/Package.swift` — the test target already uses `.copy("Fixtures")`, so no change is needed if the files sit inside that directory. Verify by running the tests.

- [ ] **Step 2: Run test to verify it fails**

Run: `make macapp-test`
Expected: FAIL — `cannot find 'PlanLimits' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One vendor's utilisation of one of its own windows. Mirrors
/// `planlimits.Gauge` in Go.
public struct PlanGauge: Equatable, Sendable {
    public var vendor: String
    public var windowLabel: String
    public var pct: Double
    public var resetsAt: Date
    public var observed: Date
    public var stale: Bool
    public var plan: String
}

public enum PlanLimits {

    private static let shortWindowCutoffMinutes = 1440
    private static let codexScanMaxAge: TimeInterval = 8 * 24 * 3600
    private static let codexScanMaxFiles = 50
    private static let grokBillingMarker = "billing: fetched credits config"

    public static func defaultCodexRoot() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

    public static func defaultGrokLog() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".grok/logs/unified.jsonl")
    }

    public static func windowLabel(minutes: Int) -> String {
        if minutes < shortWindowCutoffMinutes { return "\(minutes / 60)h" }
        if minutes == shortWindowCutoffMinutes { return "24h" }
        return "\(minutes / shortWindowCutoffMinutes)d"
    }

    /// Most recent observation per Codex window.
    ///
    /// Codex slot names are NOT stable across CLI versions: older builds
    /// put the 5-hour window in `primary` and the weekly in `secondary`;
    /// newer ones put the weekly in `primary`. Keying on window_minutes
    /// is the only reliable identity.
    public static func scanCodex(root: String, now: Date) -> [PlanGauge] {
        var best: [Int: PlanGauge] = [:]
        var bestAt: [Int: Date] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for file in codexFiles(root: root, now: now) {
            guard let body = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for rawLine in body.split(separator: "\n") {
                guard rawLine.contains("\"rate_limits\"") else { continue }
                guard let data = String(rawLine).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let rl = payload["rate_limits"] as? [String: Any],
                      let ts = obj["timestamp"] as? String,
                      let observed = iso.date(from: ts) ?? isoPlain.date(from: ts)
                else { continue }

                let planType = rl["plan_type"] as? String ?? ""
                for slotKey in ["primary", "secondary"] {
                    guard let slot = rl[slotKey] as? [String: Any],
                          let minutes = slot["window_minutes"] as? Int, minutes > 0,
                          let used = slot["used_percent"] as? Double
                    else { continue }
                    if let prev = bestAt[minutes], observed <= prev { continue }
                    let resetsUnix = (slot["resets_at"] as? Double) ?? 0
                    let resets = Date(timeIntervalSince1970: resetsUnix)
                    bestAt[minutes] = observed
                    best[minutes] = PlanGauge(vendor: "codex",
                                              windowLabel: windowLabel(minutes: minutes),
                                              pct: used,
                                              resetsAt: resets,
                                              observed: observed,
                                              stale: resets < now,
                                              plan: planType)
                }
            }
        }
        return best.keys.sorted().compactMap { best[$0] }
    }

    /// Grok's weekly utilisation, or nothing. Grok session transcripts
    /// are deliberately not read — they carry only a cumulative context
    /// total, which is not billable tokens.
    public static func scanGrok(path: String, now: Date) -> [PlanGauge] {
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var newest: PlanGauge?
        var newestAt = Date.distantPast

        for rawLine in body.split(separator: "\n") {
            guard rawLine.contains(grokBillingMarker) else { continue }
            guard let data = String(rawLine).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["msg"] as? String == grokBillingMarker,
                  let ts = obj["ts"] as? String,
                  let observed = iso.date(from: ts) ?? isoPlain.date(from: ts),
                  observed > newestAt,
                  let ctx = obj["ctx"] as? [String: Any],
                  let config = ctx["config"] as? [String: Any],
                  let pct = config["creditUsagePercent"] as? Double,
                  let period = config["currentPeriod"] as? [String: Any],
                  let endStr = period["end"] as? String,
                  let end = iso.date(from: endStr) ?? isoPlain.date(from: endStr)
            else { continue }

            newestAt = observed
            newest = PlanGauge(vendor: "grok",
                               windowLabel: "wk",
                               pct: pct,
                               resetsAt: end,
                               observed: observed,
                               stale: end < now,
                               plan: ctx["subscriptionTier"] as? String ?? "")
        }
        return newest.map { [$0] } ?? []
    }

    /// Session transcripts newest-first, dropping anything older than the
    /// longest window Codex reports.
    private static func codexFiles(root: String, now: Date) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = now.addingTimeInterval(-codexScanMaxAge)
        var found: [(path: String, mod: Date)] = []
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard mod >= cutoff else { continue }
            found.append((url.path, mod))
        }
        return found.sorted { $0.mod > $1.mod }.prefix(codexScanMaxFiles).map(\.path)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make macapp-test`
Expected: PASS — 5 new tests plus the existing suite.

- [ ] **Step 5: Commit**

```bash
git add macapp/Sources/ClaudeCounterCore/PlanLimits.swift macapp/Tests/ClaudeCounterCoreTests/PlanLimitsTests.swift macapp/Tests/ClaudeCounterCoreTests/Fixtures/
git commit -m "feat(macapp): PlanLimits.swift scanners for Codex and Grok

Parses the same fixture bytes as the Go tests, including the old Codex
layout where the 5h window sits in the secondary slot."
```

---

### Task 9: macapp — popover gauges and menu bar escalation

**Files:**
- Create: `macapp/Sources/ClaudeCounterBar/GaugesView.swift`
- Modify: `macapp/Sources/ClaudeCounterCore/AppState.swift` (add published gauge state + a refresh path)
- Modify: `macapp/Sources/ClaudeCounterBar/PopoverView.swift` (mount `GaugesView`)
- Modify: `macapp/Sources/ClaudeCounterBar/MenuBarLabel.swift:26,43,53` (escalate on worst row)
- Test: `macapp/Tests/ClaudeCounterCoreTests/GaugeRowsTests.swift`

**Interfaces:**
- Consumes: `LimitStatus`, `LimitState`, `LimitWindow` (Task 7); `PlanGauge` (Task 8).
- Produces: `GaugeBand` enum (`.short`, `.weekly`) with `title: String`; `GaugeRow{vendor, windowLabel: String; budget: LimitStatus?; plan: PlanGauge?; notApplicable: String?}`; `GaugeRows.build(band:statuses:gauges:) -> [GaugeRow]`; `GaugeRows.worstPct(statuses:gauges:) -> Double`; `AppState.limitStatuses: [LimitStatus]`, `AppState.planGauges: [PlanGauge]`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import ClaudeCounterCore

final class GaugeRowsTests: XCTestCase {

    private var statuses: [LimitStatus] {
        [
            LimitStatus(window: .day, spentUSD: 39, limitUSD: 50, pct: 78, state: .ok, resetsAt: Date()),
            LimitStatus(window: .week, spentUSD: 130, limitUSD: 250, pct: 52, state: .ok, resetsAt: Date()),
        ]
    }

    private var gauges: [PlanGauge] {
        [
            PlanGauge(vendor: "codex", windowLabel: "5h", pct: 92, resetsAt: Date().addingTimeInterval(7200),
                      observed: Date(), stale: false, plan: "plus"),
            PlanGauge(vendor: "codex", windowLabel: "7d", pct: 100, resetsAt: Date().addingTimeInterval(172800),
                      observed: Date(), stale: false, plan: "plus"),
            PlanGauge(vendor: "grok", windowLabel: "wk", pct: 14, resetsAt: Date().addingTimeInterval(21600),
                      observed: Date(), stale: false, plan: "SuperGrok"),
        ]
    }

    // Display order must match Go's exactly, or the popover and the TUI
    // disagree about which row is which.
    func test_build_fixedDisplayOrder() {
        let rows = GaugeRows.build(band: .short, statuses: statuses, gauges: gauges)
        XCTAssertEqual(rows.map(\.vendor), ["claude", "codex", "grok"])
    }

    func test_build_grokShortWindowIsNotApplicable() {
        let rows = GaugeRows.build(band: .short, statuses: statuses, gauges: gauges)
        XCTAssertEqual(rows.last?.vendor, "grok")
        XCTAssertNotNil(rows.last?.notApplicable)
        XCTAssertNil(rows.last?.plan)
    }

    func test_build_omitsVendorThatIsNotInstalled() {
        let onlyCodex = [gauges[0]]
        let rows = GaugeRows.build(band: .short, statuses: statuses, gauges: onlyCodex)
        XCTAssertEqual(rows.map(\.vendor), ["claude", "codex"])
    }

    func test_build_omitsUnsetBudget() {
        let unset = [
            LimitStatus(window: .day, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: Date()),
            LimitStatus(window: .week, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: Date()),
        ]
        let rows = GaugeRows.build(band: .short, statuses: unset, gauges: gauges)
        XCTAssertEqual(rows.map(\.vendor), ["codex", "grok"])
    }

    // A stale 100% must never drive the menu bar red.
    func test_worstPct_ignoresStaleRows() {
        let stale = [
            PlanGauge(vendor: "codex", windowLabel: "7d", pct: 100, resetsAt: Date(),
                      observed: Date(), stale: true, plan: "plus"),
            PlanGauge(vendor: "grok", windowLabel: "wk", pct: 14, resetsAt: Date().addingTimeInterval(3600),
                      observed: Date(), stale: false, plan: "SuperGrok"),
        ]
        XCTAssertEqual(GaugeRows.worstPct(statuses: statuses, gauges: stale), 78, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make macapp-test`
Expected: FAIL — `cannot find 'GaugeRows' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `macapp/Sources/ClaudeCounterCore/GaugeRows.swift` (row construction lives in Core so it is testable and shared):

```swift
import Foundation

/// Groups rows by rough duration. A band title is NOT an assertion that
/// its rows share a window definition — the weekly band holds an ISO
/// week, Codex's 7-day rolling window and Grok's Thursday-anchored
/// billing period. Every row therefore renders its own window label.
public enum GaugeBand: Sendable {
    case short, weekly
    public var title: String { self == .short ? "short window" : "weekly" }
}

public struct GaugeRow: Equatable, Sendable, Identifiable {
    public var vendor: String
    public var windowLabel: String
    public var budget: LimitStatus?
    public var plan: PlanGauge?
    public var notApplicable: String?

    /// SwiftUI requires this to be unique within a rendered band, or
    /// ForEach misbehaves. It holds because a vendor contributes at most
    /// one row per distinct window label, and labels are derived from
    /// distinct window_minutes values.
    public var id: String { vendor + "/" + windowLabel }

    /// The percentage this row displays, whatever its source.
    public var pct: Double { budget?.pct ?? plan?.pct ?? 0 }
    public var isStale: Bool { plan?.stale ?? false }
}

public enum GaugeRows {

    /// Fixed vendor order within every band, matching Go's displayOrder.
    private static let displayOrder = ["claude", "codex", "grok"]

    public static func build(band: GaugeBand,
                             statuses: [LimitStatus],
                             gauges: [PlanGauge]) -> [GaugeRow] {
        let installed = Set(gauges.map(\.vendor))
        var rows: [GaugeRow] = []

        for vendor in displayOrder {
            if vendor == "claude" {
                let want: LimitWindow = band == .weekly ? .week : .day
                if let s = statuses.first(where: { $0.window == want && $0.state != .unset }) {
                    rows.append(GaugeRow(vendor: "claude", windowLabel: s.window.label,
                                         budget: s, plan: nil, notApplicable: nil))
                }
                continue
            }
            guard installed.contains(vendor) else { continue }

            let matches = gauges.filter { $0.vendor == vendor && bandOf($0) == band }
            if matches.isEmpty {
                rows.append(GaugeRow(vendor: vendor, windowLabel: "—", budget: nil, plan: nil,
                                     notApplicable: band == .short ? "weekly only" : "no weekly window"))
            } else {
                rows.append(contentsOf: matches.map {
                    GaugeRow(vendor: vendor, windowLabel: $0.windowLabel,
                             budget: nil, plan: $0, notApplicable: nil)
                })
            }
        }
        return rows
    }

    private static func bandOf(_ g: PlanGauge) -> GaugeBand {
        g.windowLabel.hasSuffix("h") ? .short : .weekly
    }

    /// Highest utilisation across every non-stale row. Drives menu bar
    /// escalation — deliberately a different ordering from displayOrder.
    public static func worstPct(statuses: [LimitStatus], gauges: [PlanGauge]) -> Double {
        var worst = 0.0
        for s in statuses where s.state != .unset { worst = max(worst, s.pct) }
        for g in gauges where !g.stale { worst = max(worst, g.pct) }
        return worst
    }
}
```

In `AppState.swift`, add published state and a refresh that runs off the main thread:

```swift
    @Published public private(set) var limitStatuses: [LimitStatus] = []
    @Published public private(set) var planGauges: [PlanGauge] = []

    /// Highest non-stale utilisation, used for menu bar escalation.
    public var worstUtilisationPct: Double {
        GaugeRows.worstPct(statuses: limitStatuses, gauges: planGauges)
    }

    /// Re-evaluates budgets and rescans the vendor logs. Scanning walks
    /// the filesystem, so it stays off the main actor; only the assignment
    /// hops back. Any failure leaves the previous values in place — a
    /// gauge that vanishes on one bad refresh is worse than a stale one.
    public func refreshGauges(now: Date = Date()) async {
        let daily = totals.daily
        let statuses: [LimitStatus]
        if let cfg = try? Limits.load(path: Limits.defaultConfigPath()) {
            statuses = Limits.evaluate(daily: daily, config: cfg, now: now, calendar: .current)
        } else {
            statuses = []
        }
        let gauges = await Task.detached(priority: .utility) { () -> [PlanGauge] in
            PlanLimits.scanCodex(root: PlanLimits.defaultCodexRoot(), now: now)
                + PlanLimits.scanGrok(path: PlanLimits.defaultGrokLog(), now: now)
        }.value

        self.limitStatuses = statuses
        self.planGauges = gauges
    }
```

> **Note for the implementer:** `totals.daily` must be the macapp's equivalent of `agg.Totals.Daily`. Read `Aggregator.swift` / `AppState.swift` and use the real property name. Call `refreshGauges()` from the same place the popover refresh already happens; do not add a new timer.

Create `macapp/Sources/ClaudeCounterBar/GaugesView.swift`:

```swift
import SwiftUI
import ClaudeCounterCore

/// The popover's gauge block. Shows the same two bands, the same rows and
/// the same detail column as the TUI — a budget row shows $spent/$limit,
/// a plan row shows its reset time — so the two surfaces read alike.
struct GaugesView: View {
    let statuses: [LimitStatus]
    let gauges: [PlanGauge]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([GaugeBand.short, GaugeBand.weekly], id: \.title) { band in
                let rows = GaugeRows.build(band: band, statuses: statuses, gauges: gauges)
                if !rows.isEmpty {
                    Text(band.title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GaugeRowView(row: row)
                    }
                }
            }
        }
    }
}

private struct GaugeRowView: View {
    let row: GaugeRow

    var body: some View {
        HStack(spacing: 6) {
            Text(row.vendor).font(.system(size: 11)).frame(width: 48, alignment: .leading)
            // The window label is always shown, including on budget rows:
            // "daily" beside "5h" makes clear they are different windows.
            Text(row.windowLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            if let reason = row.notApplicable {
                Text("n/a (\(reason))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView(value: min(row.pct, 100), total: 100)
                    .progressViewStyle(.linear)
                    .tint(tint)
                    .frame(width: 90)
                Text(String(format: "%.0f%%", row.pct))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(row.isStale ? 0.45 : 1)
    }

    private var tint: Color {
        if row.isStale { return .gray }
        if row.pct >= 100 { return .red }
        if row.pct >= Double(LimitsConfig.defaultWarnPct) { return .orange }
        return .green
    }

    private var detail: String {
        if let b = row.budget {
            // formatUSD is the app's existing currency formatter, defined
            // at PopoverView.swift:1055 in this same target.
            return "\(formatUSD(b.spentUSD))/\(formatUSD(b.limitUSD))"
        }
        if let p = row.plan {
            return p.stale ? "stale" : "↻ " + Self.reset.localizedString(for: p.resetsAt, relativeTo: Date())
        }
        return ""
    }

    private static let reset: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
```

> **Verified symbols:** `formatUSD(_:)` is a free function at `macapp/Sources/ClaudeCounterBar/PopoverView.swift:1055`, in the same target as `GaugesView`, so it needs no import. `DailyTotal` (`Aggregator.swift:71`) has five more members than the three used here, but they all carry defaults, so `DailyTotal(day:usd:tokens:)` compiles as written in Tasks 7 and 10.

In `PopoverView.swift`, mount it below the existing totals block:

```swift
            GaugesView(statuses: state.limitStatuses, gauges: state.planGauges)
```

In `MenuBarLabel.swift`, extend the existing warning condition at line 26 so utilisation escalates the glyph too. Stale rows are already excluded by `worstUtilisationPct`:

```swift
        let worst = state.worstUtilisationPct
        let overLimit = worst >= 100
        let warned = state.hasActiveWarning || worst >= Double(LimitsConfig.defaultWarnPct)
```

and at line 53, prefer red when over:

```swift
        .foregroundStyle(overLimit ? AnyShapeStyle(Color.red)
                         : warned ? AnyShapeStyle(Color.orange)
                                  : AnyShapeStyle(.primary))
```

- [ ] **Step 4: Run tests and build to verify**

Run: `make macapp-test`
Expected: PASS — 5 new tests plus the existing suite.

Run: `make macapp-debug && open macapp/.build/debug/ClaudeCounterBar.app 2>/dev/null || make macapp-run`
Expected: the app launches and the popover shows both gauge bands (or only the plan band if you have no `limits.toml`).

- [ ] **Step 5: Commit**

```bash
git add macapp/Sources/ macapp/Tests/ClaudeCounterCoreTests/GaugeRowsTests.swift
git commit -m "feat(macapp): popover gauge bands and menu bar escalation

Row construction lives in Core so it is unit-testable and matches Go's
fixed display order. The menu bar escalates on the worst non-stale row,
so an expired window never paints it red."
```

---

### Task 10: Cross-language parity fixture and tests

**Files:**
- Create: `macapp/Tests/ClaudeCounterCoreTests/Fixtures/limits_parity.json`
- Test: `tui/internal/limits/parity_test.go`
- Test: `macapp/Tests/ClaudeCounterCoreTests/LimitsParityTests.swift`
- Modify: `Makefile` (`test-all` target comment noting parity coverage)

**Interfaces:**
- Consumes: `limits.Evaluate`, `limits.State.String()` (Task 2); `Limits.evaluate`, `LimitState.rawValue` (Task 7).
- Produces: a single fixture file both suites read. Go reads it at `../../../macapp/Tests/ClaudeCounterCoreTests/Fixtures/limits_parity.json`; Swift reads it from its test bundle. One file, no copying, so the two cannot drift.

- [ ] **Step 1: Write the fixture and both failing tests**

Create `macapp/Tests/ClaudeCounterCoreTests/Fixtures/limits_parity.json`:

```json
{
  "cases": [
    {
      "name": "typical day and week",
      "now": "2026-08-07T12:00:00Z",
      "dailyLimit": 50.0,
      "weeklyLimit": 250.0,
      "warnPct": 80,
      "daily": [
        {"day": "2026-08-02", "usd": 99.0},
        {"day": "2026-08-03", "usd": 10.0},
        {"day": "2026-08-06", "usd": 20.0},
        {"day": "2026-08-07", "usd": 39.0}
      ],
      "expect": [
        {"window": "day",  "spentUSD": 39.0, "pct": 78.0, "state": "ok"},
        {"window": "week", "spentUSD": 69.0, "pct": 27.6, "state": "ok"}
      ]
    },
    {
      "name": "exactly at the daily limit is over",
      "now": "2026-08-07T12:00:00Z",
      "dailyLimit": 50.0,
      "weeklyLimit": 250.0,
      "warnPct": 80,
      "daily": [{"day": "2026-08-07", "usd": 50.0}],
      "expect": [
        {"window": "day",  "spentUSD": 50.0, "pct": 100.0, "state": "over"},
        {"window": "week", "spentUSD": 50.0, "pct": 20.0,  "state": "ok"}
      ]
    },
    {
      "name": "exactly at warn_pct is warn",
      "now": "2026-08-07T12:00:00Z",
      "dailyLimit": 50.0,
      "weeklyLimit": 0.0,
      "warnPct": 80,
      "daily": [{"day": "2026-08-07", "usd": 40.0}],
      "expect": [
        {"window": "day",  "spentUSD": 40.0, "pct": 80.0, "state": "warn"},
        {"window": "week", "spentUSD": 40.0, "pct": 0.0,  "state": "unset"}
      ]
    },
    {
      "name": "week straddling the ISO year boundary stays one bucket",
      "now": "2027-01-01T12:00:00Z",
      "dailyLimit": 0.0,
      "weeklyLimit": 100.0,
      "warnPct": 80,
      "daily": [
        {"day": "2026-12-28", "usd": 5.0},
        {"day": "2027-01-01", "usd": 7.0},
        {"day": "2027-01-04", "usd": 9.0}
      ],
      "expect": [
        {"window": "day",  "spentUSD": 7.0,  "pct": 0.0,  "state": "unset"},
        {"window": "week", "spentUSD": 12.0, "pct": 12.0, "state": "ok"}
      ]
    },
    {
      "name": "no spend at all",
      "now": "2026-08-07T12:00:00Z",
      "dailyLimit": 50.0,
      "weeklyLimit": 250.0,
      "warnPct": 80,
      "daily": [],
      "expect": [
        {"window": "day",  "spentUSD": 0.0, "pct": 0.0, "state": "ok"},
        {"window": "week", "spentUSD": 0.0, "pct": 0.0, "state": "ok"}
      ]
    }
  ]
}
```

Create `tui/internal/limits/parity_test.go`:

```go
package limits

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jverhoeks/claudecounter/tui/internal/agg"
)

// parityFixture is shared verbatim with the Swift suite. It lives under
// the macapp test bundle because SwiftPM must copy it as a resource;
// Go reads the same bytes so the two implementations cannot drift.
const parityFixture = "../../../macapp/Tests/ClaudeCounterCoreTests/Fixtures/limits_parity.json"

type parityCase struct {
	Name        string  `json:"name"`
	Now         string  `json:"now"`
	DailyLimit  float64 `json:"dailyLimit"`
	WeeklyLimit float64 `json:"weeklyLimit"`
	WarnPct     int     `json:"warnPct"`
	Daily       []struct {
		Day string  `json:"day"`
		USD float64 `json:"usd"`
	} `json:"daily"`
	Expect []struct {
		Window   string  `json:"window"`
		SpentUSD float64 `json:"spentUSD"`
		Pct      float64 `json:"pct"`
		State    string  `json:"state"`
	} `json:"expect"`
}

func TestParityFixture(t *testing.T) {
	body, err := os.ReadFile(filepath.Clean(parityFixture))
	if err != nil {
		t.Fatalf("read parity fixture: %v", err)
	}
	var f struct {
		Cases []parityCase `json:"cases"`
	}
	if err := json.Unmarshal(body, &f); err != nil {
		t.Fatalf("parse parity fixture: %v", err)
	}
	if len(f.Cases) == 0 {
		t.Fatal("parity fixture has no cases")
	}

	for _, c := range f.Cases {
		t.Run(c.Name, func(t *testing.T) {
			now, err := time.Parse(time.RFC3339, c.Now)
			if err != nil {
				t.Fatalf("parse now: %v", err)
			}
			daily := make([]agg.DailyTotal, 0, len(c.Daily))
			for _, d := range c.Daily {
				daily = append(daily, agg.DailyTotal{Day: d.Day, USD: d.USD})
			}
			got := Evaluate(daily, Config{
				Daily:   c.DailyLimit,
				Weekly:  c.WeeklyLimit,
				WarnPct: c.WarnPct,
			}, now)

			if len(got) != len(c.Expect) {
				t.Fatalf("got %d statuses, want %d", len(got), len(c.Expect))
			}
			for i, want := range c.Expect {
				g := got[i]
				// Compare Key (identity), not String (display label), so
				// this asserts the same field Swift's rawValue does.
				if g.Window.Key() != want.Window {
					t.Errorf("[%d] window = %q, want %q", i, g.Window.Key(), want.Window)
				}
				if math.Abs(g.SpentUSD-want.SpentUSD) > 0.0001 {
					t.Errorf("[%d] SpentUSD = %v, want %v", i, g.SpentUSD, want.SpentUSD)
				}
				if math.Abs(g.Pct-want.Pct) > 0.0001 {
					t.Errorf("[%d] Pct = %v, want %v", i, g.Pct, want.Pct)
				}
				if g.State.String() != want.State {
					t.Errorf("[%d] State = %q, want %q", i, g.State.String(), want.State)
				}
			}
		})
	}
}
```

Create `macapp/Tests/ClaudeCounterCoreTests/LimitsParityTests.swift`:

```swift
import XCTest
@testable import ClaudeCounterCore

/// Reads the same fixture bytes as `tui/internal/limits/parity_test.go`.
/// If these two suites ever disagree, the TUI and the menu bar app are
/// showing different numbers for the same spend — which is exactly the
/// drift this file exists to prevent.
final class LimitsParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Day: Decodable { let day: String; let usd: Double }
        struct Expect: Decodable {
            let window: String
            let spentUSD: Double
            let pct: Double
            let state: String
        }
        struct Case: Decodable {
            let name: String
            let now: String
            let dailyLimit: Double
            let weeklyLimit: Double
            let warnPct: Int
            let daily: [Day]
            let expect: [Expect]
        }
        let cases: [Case]
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func test_parityFixture() throws {
        guard let url = Bundle.module.url(forResource: "limits_parity",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            return XCTFail("parity fixture not found in test bundle")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.cases.isEmpty, "parity fixture has no cases")

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")!

        for c in fixture.cases {
            guard let now = iso.date(from: c.now) else {
                XCTFail("\(c.name): bad now")
                continue
            }
            let daily = c.daily.map { DailyTotal(day: $0.day, usd: $0.usd, tokens: 0) }
            let got = Limits.evaluate(daily: daily,
                                      config: LimitsConfig(daily: c.dailyLimit,
                                                           weekly: c.weeklyLimit,
                                                           warnPct: c.warnPct),
                                      now: now,
                                      calendar: utc)

            XCTAssertEqual(got.count, c.expect.count, "\(c.name): status count")
            for (i, want) in c.expect.enumerated() where i < got.count {
                let g = got[i]
                XCTAssertEqual(g.window.rawValue, want.window, "\(c.name)[\(i)]: window")
                XCTAssertEqual(g.spentUSD, want.spentUSD, accuracy: 0.0001, "\(c.name)[\(i)]: spentUSD")
                XCTAssertEqual(g.pct, want.pct, accuracy: 0.0001, "\(c.name)[\(i)]: pct")
                XCTAssertEqual(g.state.rawValue, want.state, "\(c.name)[\(i)]: state")
            }
        }
    }
}
```

- [ ] **Step 2: Run both suites to verify they fail**

Run: `cd tui && TZ=UTC go test ./internal/limits/ -run TestParityFixture -v`
Expected: FAIL if the fixture path is wrong or any value disagrees. If Task 2 is correct, this may PASS immediately — that is a valid outcome for a parity test written against an already-correct implementation.

Run: `make macapp-test 2>&1 | grep -i parity`
Expected: FAIL — `parity fixture not found in test bundle` until `Package.swift`'s `.copy("Fixtures")` picks up the new file (it will, since the file sits inside `Fixtures/`); then any genuine numeric disagreement fails loudly.

- [ ] **Step 3: Reconcile any disagreement**

If the two suites disagree, the most likely causes, in order:

1. **Week-year mismatch** — Swift must use `.yearForWeekOfYear`, not `.year`. Using `.year` splits a week straddling 31 Dec, which is exactly what the fourth fixture case catches.
2. **First weekday** — Swift's default calendar starts weeks on Sunday in many locales. `Calendar(identifier: .iso8601)` fixes this; verify the test passes `utc` through.
3. **Timezone** — Go's test must run under `TZ=UTC`; Swift must pin `TimeZone(identifier: "UTC")`.

Fix whichever implementation is wrong against the spec (local calendar day, ISO week), not whichever is easier to change.

- [ ] **Step 4: Run the full suite**

Run: `make test-all`
Expected: PASS — Go and Swift suites both green.

- [ ] **Step 5: Commit**

```bash
git add macapp/Tests/ClaudeCounterCoreTests/Fixtures/limits_parity.json \
        tui/internal/limits/parity_test.go \
        macapp/Tests/ClaudeCounterCoreTests/LimitsParityTests.swift
git commit -m "test: cross-language parity fixture for the limits engine

One fixture file, read by both suites, covering the ISO-year boundary,
exactly-at-limit, exactly-at-warn and unset-window cases. If these
disagree the TUI and menu bar app are showing different numbers for the
same spend."
```

---

### Task 11: Documentation

**Files:**
- Modify: `README.md` (add a limits section after the git-activity section, around line 120)
- Modify: `tui/README.md` (document `--limits` and `--limits-config`)
- Modify: `macapp/README.md` (document the popover gauges and glyph escalation)

**Interfaces:**
- Consumes: everything above. Produces no code.

- [ ] **Step 1: Write the README section**

Add to `README.md`:

````markdown
## 🚦 Limits & plan utilisation (TUI `--limits`)

Set a USD ceiling and see how close you are to it, alongside the plan
limits Codex and Grok report for themselves:

```toml
# ~/.config/claudecounter/limits.toml
[limits]
daily    = 50.0
weekly   = 250.0
warn_pct = 80
```

```
── short window
 claude  daily ███████░░░  78%  $39.00/$50.00
 codex   5h    █████████░  92%  ↻ 2h14m
 grok    —     n/a (weekly only)
── weekly
 claude  wk    █████░░░░░  52%  $130.00/$250.00
 codex   7d    ██████████ 100%  ↻ Mon ⚠
 grok    wk    █░░░░░░░░░  14%  ↻ Thu
```

Rows are grouped by rough duration, but **a group title is not a shared
window definition**. The weekly group holds three different weeks: an ISO
Monday–Sunday week for your USD budget, Codex's rolling 7-day window, and
Grok's Thursday-20:00-UTC billing period. Each row shows its own window,
and they will legitimately disagree.

Two kinds of number appear side by side, and the right-hand column tells
them apart — a budget row shows `$spent/$limit`, a plan row shows when it
resets:

| Source | Where it comes from | Unit |
|---|---|---|
| `claude` | your `limits.toml` and this tool's cost maths | USD |
| `codex` | `~/.codex/sessions/**/*.jsonl`, vendor-reported | % of plan |
| `grok` | `~/.grok/logs/unified.jsonl`, vendor-reported | % of plan |

Grok reports no short window, so that row reads `n/a` rather than
vanishing. Grok also gets no dollar figure at all: its transcripts log
cumulative context size, not billable tokens, so any USD number would be
invented. Claude is the reverse — it has a dollar figure but publishes no
utilisation percentage locally.

A window whose reset time has passed renders dimmed and labelled stale,
and never colours the menu bar.

```bash
claudecounter --limits                        # one-shot gauge block
claudecounter --limits --limits-config PATH   # non-default config
```
````

- [ ] **Step 2: Update the two sub-READMEs**

In `tui/README.md`, add `--limits` and `--limits-config` to the flag table alongside `--report` / `--safety`, with the same one-line descriptions used in `main.go`.

In `macapp/README.md`, add a short subsection: the popover shows the same two bands as the TUI; the menu bar glyph turns orange at `warn_pct` and red at 100% on the worst non-stale row; limits are read from the same `~/.config/claudecounter/limits.toml` as the TUI, so the two apps always agree.

- [ ] **Step 3: Verify the documented commands actually work**

Run: `cd tui && go build -o /tmp/cc ./cmd/claudecounter && /tmp/cc --limits && /tmp/cc --help 2>&1 | grep -A1 limits`
Expected: the gauge block (or the "No limits configured" message) prints, and both flags appear in `--help`.

- [ ] **Step 4: Commit**

```bash
git add README.md tui/README.md macapp/README.md
git commit -m "docs: limits and plan-utilisation gauges

Documents that a group title is a duration band, not a shared window
definition, and why Grok gets a percentage but never a dollar figure."
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Configuration (`limits.toml`) | 1, 7 |
| Window semantics (local day, ISO week) | 2, 7, 10 |
| `tui/internal/limits` | 1, 2 |
| `tui/internal/planlimits` — Codex | 3 |
| `tui/internal/planlimits` — Grok | 4 |
| Scan cost rules | 3 (`codexScanMaxAge`, `codexScanMaxFiles`), 4 (substring pre-filter) |
| Renderer, two bands, `BuildRows`, both orderings | 5, 9 |
| Grok `n/a` placeholder | 5, 9 |
| Staleness | 3, 4, 5, 9 |
| TUI surface + `--limits` | 6 |
| macapp surface + glyph escalation | 9 |
| Error handling table | 1 (missing/malformed), 3–4 (absent vendor), 6 (config error surfaces) |
| Cross-language parity | 10 |
| Claude/claude.ai endpoint out of scope | Global Constraints; no task reads it |

**Deviation from the spec, stated:** the spec says to read `unified.jsonl` tail-first. Task 4 scans forward and keeps the newest match, guarded by a substring pre-filter. On a 3 MB log with ~105 billing lines this parses well under 1% of lines and avoids reverse-seek complexity, satisfying the spec's intent (cheap scan, newest observation) without its exact mechanism.

**Placeholder scan:** no `TBD` / `TODO` / "handle edge cases" / "similar to Task N".

**Symbols verified against the codebase, not assumed:**

| Symbol | Reality | Effect on the plan |
|---|---|---|
| `scanOnce` | **does not exist** — `runOnce` (`main.go:101-131`) inlines its scan | Task 6 specifies extracting `scanSnapshot` first, with the code |
| `ui.FormatUSD` | exists, `tui/internal/ui/format.go:9` | used as-is in Task 5 |
| `formatUSD` (Swift) | free function, `PopoverView.swift:1055`, same target as `GaugesView` | Task 9 uses the lowercase name, no import |
| `DailyTotal` (Swift) | `Aggregator.swift:71`; 3 extra members, all defaulted | `DailyTotal(day:usd:tokens:)` compiles in Tasks 7 and 10 |
| `BurntSushi/toml` | already in `tui/go.mod` v1.6.0 | Task 1 adds no dependency |
| `.copy("Fixtures")` | already in `Package.swift` test target | Tasks 8 and 10 need no manifest change |

**Type consistency:** `Gauge`/`PlanGauge` fields align (`Vendor`/`vendor`, `WindowLbl`/`windowLabel`, `Stale`/`stale`). `Row`/`GaugeRow` align. `limits.State.String()` and `LimitState.rawValue` both produce `unset|ok|warn|over`, which Task 10 compares as strings. `Window.String()` returns `daily`/`wk`; the Go parity test maps the fixture's `day`/`week` via `windowKey`, while Swift's `LimitWindow.rawValue` is `day`/`week` directly — both compared against the same fixture field.

---

**Plan complete and saved to `docs/superpowers/plans/2026-08-07-usage-limits.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
