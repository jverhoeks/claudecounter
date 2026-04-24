# claudecounter TUI — Design

**Date:** 2026-04-24
**Author:** jjverhoeks (brainstormed with Claude)
**Status:** Draft — awaiting review

## Goal

A cross-platform (Mac-first) terminal UI written in Go that watches Claude Code's
session JSONL files in realtime and displays **current Claude Code spend** for
today and this month, total and per-model.

This is the first of two planned apps. The second — a macOS menubar app — is
out of scope for this spec but will reuse the same watcher/reader/aggregator/pricing
packages, replacing only the UI layer.

## Hypothesis being tested

Parsing the local JSONL session files in realtime is a cheap and reliable
mechanism for a cost dashboard that a user would keep running on-screen.

## Non-goals

- Historical analytics / charts over weeks or years.
- Retention of old data across runs (no DB, no cache file). Cold start re-scans.
- Filtering to a single project or session (scope is all projects, aggregated).
- A scheduled/cron pricing refresh. The TUI fetches on-demand when the pricing
  file is missing or when `--refresh-pricing` is passed. A scheduled refresh is
  a separate tool/launchd plist, designed later.
- Bubble Tea view-layer tests. View is thin; manual verification is sufficient.

## Data source

`~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`

- One JSON object per line, appended as Claude Code runs.
- Assistant messages carry `message.usage` with `input_tokens`, `output_tokens`,
  `cache_creation_input_tokens`, `cache_read_input_tokens`, plus `model`,
  event `timestamp`, `sessionId`, `cwd`, `gitBranch`.
- Non-assistant lines (user messages, tool results, hook events, permission-mode
  markers) are skipped.
- Files are append-only in normal operation.

## Scope of aggregation

- All projects, all sessions, aggregated.
- Startup scan skips any JSONL whose file `mtime` is older than the start of the
  current local month (such files cannot contribute to today or this-month).
- Per-event filtering uses each event's own `timestamp` to bucket into a day.

## Time windows displayed

- **Today** (local midnight → now)
- **This month** (first of local month → now)

Both recomputed from the day-keyed totals map on each snapshot, so midnight and
month rollovers are automatic — no wall-clock timer in the aggregator.

## View modes

Three togglable layouts in one binary. Cycle with `Tab` or jump with `1` / `2` / `3`.

### Mode 1 — Minimal
```
┌──────────────────────────────┐
│ Today     $  4.27            │
│ Month     $132.80            │
│ Opus $3.90 · Sonnet $0.37    │
└──────────────────────────────┘
```

### Mode 2 — Split (headline + per-model breakdown)
```
┌──────────────────────────────┐
│ Today  $ 4.27   Month $132   │
├──────────────────────────────┤
│ opus-4-7      $  3.90   92%  │
│ sonnet-4-6    $  0.37    8%  │
│ haiku-4-5     $  0.00    0%  │
└──────────────────────────────┘
```

### Mode 3 — Full dashboard (headline + breakdown + live tail)
```
┌────────────────────────────────────────────────────────────┐
│ Today $ 4.27    Month $132.80                              │
├──────────────── by model ──────────────────────────────────┤
│ opus-4-7     $ 3.90    92%                                 │
│ sonnet-4-6   $ 0.37     8%                                 │
├──────────────── live tail ─────────────────────────────────┤
│ 16:11:23  claudecounter   opus    +$0.021  (1.2k out)      │
│ 16:11:19  mybrain         sonnet  +$0.003  (0.4k out)      │
└────────────────────────────────────────────────────────────┘
```

Footer, shared across all modes, shows warnings when present:
- `⚠ pricing: using built-in defaults from YYYY-MM-DD`
- `⚠ 3 events w/ unpriced model: claude-foo-x`
- `⚠ N parse errors` (never expected to be non-zero)

## Architecture

```
               ~/.claude/projects/**/*.jsonl
                         │
                         ▼
              ┌───────────────────────┐
              │       watcher         │  fsnotify on projects/ + each subdir
              │  internal/watcher     │  emits Change{Path, Kind}
              └───────────┬───────────┘
                          ▼
              ┌───────────────────────┐
              │        reader         │  holds fileOffset map
              │  internal/reader      │  seek → read new lines → parse
              └───────────┬───────────┘
                          ▼
              ┌───────────────────────┐
              │      aggregator       │  totals keyed by day × model
              │  internal/agg         │  today/month derived at snapshot
              └───────────┬───────────┘
                          ▼
              ┌───────────────────────┐
              │         ui            │  bubbletea, 3 view modes,
              │  internal/ui          │  re-renders on snapshot
              └───────────────────────┘

  pricing (internal/pricing): loads pricing.toml, Cost(model, usage) → $;
                               Fetch() scrapes Anthropic pricing page;
                               Defaults() returns baked-in fallback table.
```

## Components

### `internal/pricing`

```go
type ModelPrice struct {
    InputPerMTok         float64
    OutputPerMTok        float64
    CacheCreationPerMTok float64
    CacheReadPerMTok     float64
}
type Table map[string]ModelPrice

func Load(path string) (Table, error)
func (t Table) Cost(model string, u Usage) float64
func Fetch(ctx context.Context) (Table, error) // scrapes Anthropic pricing page
func Defaults() Table                           // baked-in fallback, dated
```

- `Usage` struct mirrors only the four numeric fields we consume.
- Unknown model → `Cost` returns 0 and increments the aggregator's unknown counter.
- `Fetch`: HTTP GET the Anthropic pricing page, parse via goquery or equivalent.
  Exact selectors are pinned during implementation, not here (they rot).
- `Defaults`: constant table in-source. Update in version bumps when prices change.

Pricing file location: `~/.config/claudecounter/pricing.toml` (override with
`--pricing <path>`).

### `internal/reader`

```go
type Event struct {
    Timestamp time.Time
    SessionID string
    Cwd       string
    Model     string
    Usage     Usage
}
type Reader struct {
    offsets map[string]int64
    out     chan<- Event
}

func (r *Reader) InitialScan(root string, notBefore time.Time) error
func (r *Reader) OnChange(path string) error
```

- `InitialScan` walks `root/*/*.jsonl`, skips files with `mtime < notBefore`,
  reads the rest fully, populates `offsets` to the final byte.
- `OnChange` is idempotent: opens the file, seeks to `offsets[path]`, reads
  complete `\n`-terminated lines only, advances offset only past complete lines.
- A partial last line stays unread until the next Change event appends the `\n`.
- Non-assistant lines and lines without `message.usage` are skipped.
- A JSON parse error on a complete line: skip the line, increment `parseErrors`,
  but **do** advance past it (otherwise it replays forever).

### `internal/agg`

```go
type TokenCounts struct { In, Out, CacheCreate, CacheRead uint64 }
type ModelDay struct { USD float64; Tokens TokenCounts }

type Totals struct {
    Day     map[string]ModelDay  // model → today's totals
    Month   map[string]ModelDay  // model → this month's totals
    Unknown int
    ParseErrors int
    AsOf    time.Time
}

type Aggregator struct {
    pricing     pricing.Table
    byDay       map[civilDay]map[string]ModelDay // internal storage
    unknown     int
    parseErrors int
}

func (a *Aggregator) Apply(e reader.Event)
func (a *Aggregator) Snapshot() Totals
```

- Storage: `map[civilDay]map[string]ModelDay`. On `Snapshot()`, pick today's
  day and sum this-month's days; this makes midnight/month rollover automatic.
- `civilDay` is a simple `{year, month, day}` value in the local timezone so
  DST transitions don't double-count.
- Snapshots are emitted on a debounced channel (~50 ms) — a burst of Writes
  produces one render.

### `internal/watcher`

```go
type ChangeKind int
const (
    Create ChangeKind = iota
    Write
    Remove
)
type Change struct { Path string; Kind ChangeKind }

func New() (*Watcher, error)
func (w *Watcher) AddTree(root string) error
func (w *Watcher) Events() <-chan Change
func (w *Watcher) Close() error
```

- Wraps `github.com/fsnotify/fsnotify`.
- `AddTree`: watches `root` and every existing subdir.
- On `Create` of a subdir: add watcher on it.
- On `Create` of a `.jsonl`: emit `Change{Path, Create}` — reader registers it
  with offset 0 and reads it.
- On `Write` of a `.jsonl`: emit `Change{Path, Write}`.
- On `Remove`/`Rename`: emit `Change{Path, Remove}` — reader drops it from the
  offset map.
- On fsnotify internal queue overflow: emit a synthetic batch of `Write` events
  for every known file so the reader re-tails from each stored offset.

### `internal/ui`

- Bubble Tea model: `{ totals agg.Totals; mode ViewMode; recent []reader.Event }`.
- `1` / `2` / `3` or `Tab` to switch view modes; `q` or `Ctrl+C` to quit.
- In Mode 3, the ring buffer holds the last ~20 events (configurable constant).
- Lipgloss for color; green for money, dim for sub-10% models, accent for Opus.
- Cost formatter: `$1,234.56` style with locale-independent commas.

### `cmd/claudecounter`

Flags:
- `--pricing <path>` (default: `$XDG_CONFIG_HOME/claudecounter/pricing.toml` or
  `~/.config/claudecounter/pricing.toml`)
- `--root <path>` (default: `~/.claude/projects`)
- `--refresh-pricing` (force Fetch → write file → load, even if file exists)

Startup:
1. Resolve paths. Ensure `--root` exists (error out if not).
2. Load pricing: `Load()` → on miss, `Fetch()` + write; on fetch fail, `Defaults()`.
3. `reader.InitialScan(root, firstOfCurrentMonth.Local())`.
4. `watcher.AddTree(root)`.
5. Run the event-processing goroutine: `watcher.Events()` → `reader.OnChange()` →
   `aggregator.Apply()` → debounced snapshot → `program.Send(snapshotMsg)`.
6. `ui.Run()` on the main goroutine.

## Data flow (a single event's journey)

```
1. Claude Code appends a line to a .jsonl
2. fsnotify Write event → watcher.Change{path, Write}
3. reader.OnChange(path): seek to offset, read new complete lines, parse
   assistant/usage, emit Event
4. aggregator.Apply(evt): day = evt.Timestamp.Local() civilDay;
   cost = pricing.Cost(model, usage); byDay[day][model] accumulates
5. aggregator debounces 50 ms, emits Snapshot
6. bubbletea receives snapshotMsg, View() re-renders active mode
```

## Invariants

- `offsets[path]` never advances past an incomplete line.
- Aggregator never forgets events; today/month are computed from `byDay` on each
  snapshot, so midnight and month-end rollover have no special code path.
- Snapshots are safe to drop/replace; the UI always shows the most recent.
- All times are local; event timestamps from JSONL are RFC3339 UTC and are
  converted to local before bucketing into a `civilDay`.

## Error handling

| Failure | Response |
|---|---|
| `pricing.toml` missing | Try `Fetch()` → write file → load. On fetch fail: `Defaults()` + footer warning. |
| `Fetch()` succeeds but parse shape is new | Log, keep existing file if present, else `Defaults()`. Never overwrite a good file with a bad parse. |
| `pricing.toml` malformed | Warn; fall through to Fetch/Defaults the same way. |
| Unknown model in event | Count toward tokens; cost 0; aggregator.Unknown++; footer warning lists models. |
| Malformed JSON line | Skip; parseErrors++; advance past it; footer warning if count > 0. |
| File shorter than stored offset | Reset offset to 0; log once. |
| fsnotify queue overflow | Re-trigger Write events for every known file. |
| fsnotify fails to add a subdir | Log path; continue; that dir won't live-tail but past events were counted at startup. |
| `~/.claude/projects/` missing | Friendly error, exit non-zero. |
| File deleted mid-read | EOF / ENOENT; drop from offset map; continue. |
| Clock / DST change | `time.Now().Local()` each snapshot recomputes today and this-month; civilDay avoids double-counting. |

Deliberate non-behavior:
- No retry/backoff on local FS operations — failures are bugs, not transients.
- No validation of Claude's JSON schema beyond `type=="assistant"` and
  `message.usage` presence; new fields are ignored, removed fields degrade visibly.
- No persistent cache of totals across runs.

## Testing

**Unit tests:**

| Package | Tests |
|---|---|
| `pricing` | `Load` parses sample TOML; `Cost` math for each of 4 usage fields; unknown model returns 0; `Defaults()` covers Opus/Sonnet/Haiku. |
| `pricing/fetch` | `parsePricingHTML` against `testdata/pricing-page.html`. No live network in tests. |
| `reader` | Table-driven against JSONL fixtures: normal assistant line, user line (skipped), hook event (skipped), malformed line (skipped + counter), partial last line (offset doesn't advance past it). |
| `agg` | Events in → Snapshot out; day boundary at 23:59:59 / 00:00:01 lands in different buckets; month boundary; faked-clock DST spring-forward. |
| `watcher` | Smoke: temp dir + file write emits Change within 1s. fsnotify itself is trusted. |

**Integration test (`cmd/claudecounter/integration_test.go`):**

1. Temp projects dir, 2 subdirs, 1 jsonl each (one old-mtime, one current-month).
2. Wire watcher + reader + aggregator (no TUI).
3. Assert initial totals count only current-month file.
4. Append an assistant line → within 500 ms, snapshot reflects it.
5. Create a new jsonl in a subdir, append a line → snapshot reflects it.

**Fixtures:**
- `internal/reader/testdata/session_normal.jsonl`
- `internal/reader/testdata/session_malformed.jsonl`
- `internal/pricing/fetch/testdata/pricing-page.html`

**Not tested:**
- Bubble Tea view layer (thin; manual verification).
- Live scrape against anthropic.com.

## Dependencies

- `github.com/charmbracelet/bubbletea`
- `github.com/charmbracelet/lipgloss`
- `github.com/fsnotify/fsnotify`
- `github.com/BurntSushi/toml` *(or `github.com/pelletier/go-toml/v2` — picked during implementation)*
- `github.com/PuerkitoBio/goquery` *(for pricing HTML scrape)*

Stdlib: `encoding/json`, `os`, `bufio`, `net/http`, `time`, `context`.

## Follow-ups (not in this spec)

- macOS menubar app (app #2 from the original request) — reuses
  `internal/{watcher,reader,agg,pricing}`, replaces `internal/ui` with a menubar
  UI (likely `github.com/caseymrm/menuet` or Swift via cgo).
- Scheduled pricing refresh (launchd / cron) running `claudecounter --refresh-pricing`.
- Per-project filter / drill-down inside the TUI (designed into the aggregator's
  shape but not surfaced in views yet).
- Rolling 5-hour window (the other candidate from brainstorming) if rate-limit
  visibility becomes important.
