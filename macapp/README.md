# 🍎 ClaudeCounterBar

> A native macOS menu bar app that shows your Claude Code spend in
> (near) real time.

```
 💵 $35
    ↑ click for the dashboard popover
```

The menu bar item shows a cash-register-style banknote glyph plus
today's running total in whole dollars. Click for a popover with hero
today/month numbers, an hourly chart, a 30-day chart, by-model and
by-project tables (these *do* keep cents precision), and a live tail
of recent events.

For the shared philosophy, math, "missing files" calibration story,
and pricing source see the [root README](../README.md).

## ✨ What it shows

**Menu bar item (always visible):**
- Hand-drawn cash-register glyph (drawer body + display housing) with
  the Claude 6-petal asterisk cut out of the display via even-odd fill
  — a SwiftUI `Shape` so it renders crisp at any pixel density and
  inherits the menu bar's foreground color
- `$today` rounded to whole dollars (e.g. `$35` / `$1234`) — decimals
  are noisy at menu-bar size, the popover keeps the cents precision
- Glyph pulses softly while the initial scan runs, snaps to solid once
  numbers are live
- `—` when `~/.claude/projects` is missing

**Popover (~520×440px, on click):**
- Hero today + month numbers
- 24-bar hourly chart for today (future hours dimmed)
- "By model · month" table with USD and %
- "By project · month" table with main / subagent split
- Live tail — last 8 events as they arrive
- Footer: "Updated Xs ago" · Refresh button · ⚙ menu

**⚙ menu:**
- **Launch at login** toggle (uses `SMAppService.mainApp` — macOS may
  ask for one-time approval in System Settings → General → Login Items
  the first time you enable it; the menu shows a hint when the state
  is `requiresApproval`)
- **Show dock icon with spend** toggle — adds a Dock icon (a white
  squircle with an orange dollar-bill graphic in the lower half,
  rendered at runtime from SwiftUI; the upper-right stays clear so
  the system-drawn red badge has clean space) carrying today's
  running spend in whole dollars (e.g. `$35`). Badge updates on every
  snapshot tick (≤250 ms after a new event). **On by default**; turn
  it off if you'd rather keep the Dock free of an extra icon.
- Refresh pricing (fetches from LiteLLM and writes to the in-app override)
- Quit

## 📦 Install (release build)

The menu bar app is published on each
[joint release](https://github.com/jverhoeks/claudecounter/releases)
(tags shaped `vX.Y.Z`). Out-of-cycle macapp-only patches also appear
under `macapp-vX.Y.Z` tags — both work.

```bash
# 1. Pick a version. Replace v1.0.0 with the tag on the Releases page.
VERSION=v1.0.0
ZIP="ClaudeCounterBar-${VERSION}-macos-arm64.zip"

# 2. Download
curl -LO "https://github.com/jverhoeks/claudecounter/releases/download/${VERSION}/${ZIP}"

# 3. Verify the checksum (optional)
curl -LO "https://github.com/jverhoeks/claudecounter/releases/download/${VERSION}/${ZIP}.sha256"
shasum -a 256 -c "${ZIP}.sha256"

# 4. Unzip into Applications (ditto preserves the bundle structure)
ditto -xk "${ZIP}" /Applications/

# 5. Strip the Gatekeeper quarantine flag.
#    The release is ad-hoc signed but not notarized (see "About signing"
#    below). Without this step, macOS refuses to launch the app on first
#    open with a "cannot be opened because it is from an unidentified
#    developer" dialog.
xattr -dr com.apple.quarantine /Applications/ClaudeCounterBar.app

# 5. Launch
open /Applications/ClaudeCounterBar.app
```

The bundle is `LSUIElement = YES` so the app boots into the menu bar
only — but if you leave the **Show dock icon with spend** toggle on
(default), it also flips the activation policy at runtime to add a
Dock icon with a red `$today` badge. Disable the toggle in the ⚙ menu
to get the pure menu-bar-only experience. Quit via the ⚙ menu inside
the popover or
`osascript -e 'tell application "ClaudeCounterBar" to quit'`.

**Requirements:** macOS 13+ on Apple Silicon (arm64). Intel build on
request — open an issue.

### About signing

The release `.app` is signed with an **ad-hoc** signature, which lets
the bundle launch and stops Gatekeeper from refusing the executable
outright, but is not the same as a notarized Developer ID signature.
Without notarization, macOS marks any downloaded `.app` with a
quarantine extended attribute that triggers the "unidentified
developer" dialog on first launch. The `xattr -dr com.apple.quarantine`
step above removes that attribute.

Notarization (which would eliminate this step) requires a paid
[Apple Developer Program](https://developer.apple.com/programs/)
membership ($99/year). Once that's in place, the release workflow
gains a `xcrun notarytool submit` + `xcrun stapler staple` pair and
this section goes away.

## 🛠️ Build from source

### From the repo root

```bash
git clone https://github.com/jverhoeks/claudecounter
cd claudecounter
make macapp
open dist/ClaudeCounterBar.app
```

### From this directory

```bash
cd macapp
./scripts/build-app.sh release   # → ../dist/ClaudeCounterBar.app
swift test                       # 99 unit tests
```

### Requirements

- macOS 13+ (uses `MenuBarExtra` and `SMAppService`)
- Xcode 15+ / Swift 5.9+ (Swift 6 mode is fine)
- No third-party dependencies — everything is in-tree

## 🧠 Architecture

Same layered design as the [Go TUI](../tui), ported to Swift:

```
┌──────────────────────────────────────────────────────────────────┐
│  SwiftUI layer (MenuBarExtra + Popover)                          │
└────────────────▲─────────────────────────────────────────────────┘
                 │ @Published Snapshot
┌────────────────┴─────────────────────────────────────────────────┐
│  AppState     coordinates Watcher → Reader → Aggregator →        │
│                 Snapshot, debounces UI updates to 250ms          │
└────────────────▲─────────────────────────────────────────────────┘
                 │
┌────────────────┴─────────────────────────────────────────────────┐
│  Aggregator   actor; cells keyed by (day, project, model, isSub) │
│                 holds Tokens(in,out,cacheCreate,cacheRead)       │
│                 snapshot() applies Pricing → Totals              │
└────────────────▲─────────────────────────────────────────────────┘
                 │ UsageEvent stream
┌────────────────┴─────────────────────────────────────────────────┐
│  Reader       actor; tails JSONL with byte offsets               │
│                 dedupes by messageId:requestId (first-seen)      │
│                 filters <synthetic>, attributes project/sub      │
└────────────────▲─────────────────────────────────────────────────┘
                 │ FileChange events
┌────────────────┴─────────────────────────────────────────────────┐
│  Watcher      FSEventStream on ~/.claude/projects (recursive)    │
└──────────────────────────────────────────────────────────────────┘

Side-attached:
  Pricing       LiteLLM table + TOML override layering + refresh
  Cache         persists aggregator state to ~/Library/Application
                Support/claudecounter-bar/cache.json
```

## 🎯 Algorithm parity with the Go TUI

The macapp's `ClaudeCounterCore` library is a byte-for-byte port of
the Go internal packages:

| Go (`tui/internal/`) | Swift (`macapp/Sources/ClaudeCounterCore/`) |
|---|---|
| `pricing/` | `Pricing.swift`, `PricingFetch.swift`, `TOML.swift` |
| `reader/` | `Reader.swift` |
| `agg/` | `Aggregator.swift` |
| `watcher/` (fsnotify) | `Watcher.swift` (FSEventStream) |
| (no equivalent) | `Cache.swift`, `AppState.swift`, `LiveEventBuffer.swift` |

The Swift test suite includes **cross-language conformance tests**
that load the same `session_normal.jsonl` and `session_malformed.jsonl`
fixtures the Go tests use, and assert identical token totals. That's
the regression net against algorithm drift.

The directory walk order is also matched to Go's `filepath.WalkDir`
(`Reader.walkDirLikeGo`) so first-seen-wins dedupe attributes shared
events between main / subagent files identically. See ["the missing
files" story in the root README](../README.md#-the-case-of-the-missing-files)
for the calibration history.

## 💾 Persistence

The aggregator state is persisted to:

```
~/Library/Application Support/claudecounter-bar/
  cache.json     ← aggregator cells + perMsg dedupe set + per-file offsets
  pricing.toml   ← in-app override (in-app refresh writes here)
```

Cache is written:
- Right after the initial scan completes (so the post-backfill state
  is durable even if the app crashes a moment later)
- Every 60s while running
- On `applicationWillTerminate` (best-effort during quit)

Read flow on launch: load cache → seed aggregator + reader offsets →
publish snapshot immediately (cached numbers visible within a frame
or two) → start FSEventStream → run incremental scan with
`notBefore = max(cache.writtenAt - 5min, min(firstOfMonth, now-35d))`
so we re-parse only the few KB modified since cache was written.

Manual **Refresh** in the popover invalidates the cache and rescans
from `min(firstOfMonth, now-35d)` — useful if you want to verify the
numbers from scratch.

## 🛠️ Pricing resolution

Order (first hit wins, falls back to bake-in defaults):

1. `~/Library/Application Support/claudecounter-bar/pricing.toml` —
   in-app override; the "⚙ → Refresh pricing" menu item writes here
2. `$XDG_CONFIG_HOME/claudecounter/pricing.toml` or
   `~/.config/claudecounter/pricing.toml` — shared with the Go TUI;
   if you've already configured pricing for the TUI, the menu bar
   app picks it up for free
3. Bake-in defaults (Swift port of the Go TUI's `pricing/defaults.go`)

The "Refresh pricing" menu item fetches LiteLLM's
`model_prices_and_context_window.json` (same source as `ccusage`),
filters Anthropic models, normalises any `anthropic/` prefix, converts
per-token → per-mtok, and writes the in-app override.

## 📁 Layout

```
Package.swift                         SPM manifest, macOS 13+, no deps
Sources/
  ClaudeCounterCore/                  headless library, all testable
    Pricing.swift                     Usage, ModelPrice, PricingTable, defaults
    PricingFetch.swift                LiteLLM JSON fetch + parse
    TOML.swift                        minimal TOML decode/encode + layering
    Reader.swift                      JSONL tail, parseLine, walkDirLikeGo
    Aggregator.swift                  TokenCounts, CivilDay, snapshot
    Watcher.swift                     FSEventStream wrapper
    Cache.swift                       JSON persist/restore
    LiveEventBuffer.swift             ring buffer for the popover live tail
    LaunchAtLogin.swift               SMAppService.mainApp seam + 4-state model
    DockIcon.swift                    NSApp activation policy + dock badge seam
    Settings.swift                    AppSettings + UserDefaults-backed store
    AppState.swift                    @MainActor coordinator + lifecycle
  ClaudeCounterBar/                   the macOS app target
    App.swift                         @main, AppDelegate, MenuBarExtra
    MenuBarLabel.swift                cash-register glyph + $today
                                              + ClaudeRegisterShape definition
    AppIcon.swift                     SwiftUI Dock icon, rendered at launch
                                              into NSApp.applicationIconImage
    PopoverView.swift                 hero, hourly chart, tables, live tail
    Resources/                        SPM-processed resources
Tests/ClaudeCounterCoreTests/         99 unit tests
  Fixtures/                           JSONL fixtures shared with Go tests
  PricingTests.swift                  9 tests
  ReaderTests.swift                   21 tests, incl. cross-language conformance
  AggregatorTests.swift               12 tests
  WatcherTests.swift                  7 tests, incl. live FSEvents smoke test
  CacheTests.swift                    8 tests, incl. cache-v2 hour-bucket round-trip
  PricingFetchAndTOMLTests.swift      10 tests, incl. mock URL session
  LaunchAtLoginTests.swift            6 tests, incl. SMAppService smoke test
  DockIconTests.swift                 10 tests, incl. NSApp smoke test +
                                              formatUSDWhole rules
  SettingsTests.swift                 6 tests, incl. UserDefaults first-run defaults
  AppStateTests.swift                 10 tests, incl. live pipeline + refresh
                                              + dock-icon visibility/badge wiring
Resources/Info.plist                  CFBundle*, LSUIElement = YES
scripts/build-app.sh                  bundle .app from `swift build`
scripts/release-macapp.sh             package .app into a .zip + .sha256
```

## 🧪 Tests

From the repo root:

```bash
make macapp-test     # cd macapp && swift test
make test-all        # Go + Swift suites
```

Or directly from `macapp/`:

```bash
swift test
```

What's covered:
- **Pricing math** — known/unknown models, all four token types, per-model defaults
- **Reader** — parse rules, dedupe-on-empty-keys, byte offsets, truncation,
  partial-line safety, project/subagent attribution, plus
  cross-language conformance against the Go fixtures
- **Aggregator** — dedupe (happy + empty-id paths), civil-day boundary,
  per-project main/sub split, multi-model per-project costing, daily
  window, hourly buckets
- **Watcher** — flag mapping (create/modify/remove/rename), live
  FSEvents smoke test (write a JSONL, assert event arrives within 5s)
- **Cache** — round-trip, missing-file (nil), corrupt-file (throws),
  invalidate, dedupe-survives-restart
- **TOML + Fetch** — decode/encode round-trip, resolution paths with
  and without `XDG_CONFIG_HOME`, mock-session fetch, non-200 raises
- **AppState** — live-buffer ordering + cap, scanCutoff in three modes,
  end-to-end FSEvents pipeline + refresh, dock-icon visibility/badge
  wiring and runtime toggle persistence
- **LaunchAtLogin** — protocol seam, 4-state enum visibility, error
  propagation, smoke test against `SMAppService.mainApp`
- **DockIcon** — protocol seam, in-memory test double behaviour, badge
  formatter rules ($12.34 / $123.4 / $1234), `NSApp` smoke test
- **Settings** — `dockIconEnabled` defaults to `true` (verified per
  user request), UserDefaults round-trip with isolated suite names

UI is intentionally not pixel-tested (thin SwiftUI layer; visual
verification via `make macapp-run`).

## 🛠️ Makefile targets (run from repo root)

| target | what |
|---|---|
| `make macapp` | Build `.app` bundle (release) → `dist/ClaudeCounterBar.app` |
| `make macapp-debug` | Build a debug `.app` for fast iteration |
| `make macapp-test` | Run the Swift unit tests |
| `make macapp-run` | Build and launch the menu bar app |
| `make macapp-release VERSION=v1.0.0` | Build + package as `.zip` + `.sha256` in `dist/` |
| `make macapp-publish VERSION=v1.0.0` | Tag `macapp-vX.Y.Z` + push (CI builds + creates a Release) |
| `make test-all` | Run Go + Swift suites |
| `make clean` | Remove `dist/`, `.build/`, `.swiftpm/`, etc. |

## 🚢 Cutting a release (maintainer)

There are two release lanes:

1. **Joint release** (preferred) — `vX.Y.Z` tag. Both apps ship
   together: TUI binaries for all 6 platforms + macapp `.zip`. Run
   from the repo root: `make release VERSION=v1.0.0`.
2. **Macapp-only patch** — `macapp-vX.Y.Z` tag. For UI fixes that
   don't justify rebuilding the Go TUI. Run: `make macapp-publish VERSION=v1.0.1`.

Both produce a Release with the macapp `.zip` + `.sha256` attached
and install instructions baked into the body.

**Local dry run** (no tag, no push):

```bash
make macapp-release VERSION=v1.0.0
```

Produces in `dist/`:

```
ClaudeCounterBar.app
ClaudeCounterBar-v1.0.0-macos-arm64.zip
ClaudeCounterBar-v1.0.0-macos-arm64.zip.sha256
```

Sanity-check the zip by unzipping it elsewhere and launching:

```bash
( cd /tmp && ditto -xk \
    /path/to/repo/dist/ClaudeCounterBar-v1.0.0-macos-arm64.zip ./test-install )
xattr -dr com.apple.quarantine /tmp/test-install/ClaudeCounterBar.app
open /tmp/test-install/ClaudeCounterBar.app
```

**Publish (joint):**

```bash
make release VERSION=v1.0.0
```

Tags `v1.0.0` and pushes. The
[`release.yml`](../.github/workflows/release.yml) workflow takes over:
runs the Go test suite + cross-builds 6 TUI platforms on
`ubuntu-latest`, runs the 99-test Swift suite + builds the macapp on
`macos-14`, then a third job creates the Release with all 8 assets
attached.

**Publish (macapp-only):**

```bash
make macapp-publish VERSION=v1.0.1
```

Tags `macapp-v1.0.1` and pushes;
[`release-macapp.yml`](../.github/workflows/release-macapp.yml)
handles the macapp-side-door build.

The workflow can also be triggered manually from the Actions tab via
`workflow_dispatch` — it'll run the build and upload the artifacts
to the run summary, but not create a Release. Useful for verifying
the build works before tagging.

**To revoke a release:** delete the GitHub Release + the tag (`git
tag -d macapp-v1.0.0 && git push --delete origin macapp-v1.0.0`).

## 🚧 Out of scope (v1)

Considered and deferred:

- **Notarization + Developer ID signing** (eliminates the `xattr`
  step on first launch) — needs a paid Apple Developer Program
  membership; the `release-macapp.yml` workflow is structured so the
  notarization steps can be added when that's available without
  reshaping anything.
- **Homebrew Cask** (`brew install --cask claudecounter-bar`) — most
  cask reviewers expect notarized bundles, so this naturally pairs
  with the previous bullet.
- **Universal binary** (Intel + Apple Silicon) — currently arm64-only.
  Open an issue if you want Intel and we'll add a second job to the
  release workflow.
- Budget alerts / red-tint when today exceeds a threshold.
- Per-day or per-week popover views.
- CSV export.
- Sparkle auto-update.

## 📜 License

MIT. See [root LICENSE info](../README.md#-license).
