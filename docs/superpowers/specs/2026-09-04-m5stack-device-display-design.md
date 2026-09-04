# M5Stack Core2 device display — design

Date: 2026-09-04

## Goal

Show the mac app's spend and usage figures on an M5Stack Core2 for AWS
sitting on the desk, without the device having to reach the laptop
directly. The mac app publishes a small JSON document to a Cloudflare
Worker backed by KV; the device polls the Worker over Wi-Fi and renders
it. When an active Claude session crosses the context-window warning
threshold the device alarms with its LED bar and speaker.

The Go TUI does not publish. Only the mac app does.

## Non-goals

- Publishing from the Go TUI.
- Any on-device configuration UI. Wi-Fi and Worker credentials are
  compiled in.
- HTTPS certificate pinning on the device. It uses the ESP32 root CA
  bundle.
- Claude subscription quota. The user is on Enterprise, which has none.
- Historical charts on the device.

## Components

```
mac app (ClaudeCounterBar)          Cloudflare                   M5Stack Core2
────────────────────────            ──────────                   ─────────────
AppState minute tick
  └─ DevicePayload.build ──JSON──▶ PUT /state ─▶ KV ─▶ GET /state ◀── poll 30 s
  └─ DevicePublisher (PUT)          (write token)     (read token)     └─ render
                                                                        └─ alarm
```

## 1. Payload

One JSON document, version-tagged. Every consumer must ignore unknown
keys and reject an unknown `v`.

```json
{
  "v": 1,
  "at": "2026-09-04T10:41:00Z",
  "spend": {
    "claude": {"day": 18.40, "week": 96.10, "month": 312.50},
    "codex":  {"day": 4.10,  "week": 22.00, "month": 61.20},
    "grok":   {"day": 0.90,  "week": 5.10,  "month": 12.70}
  },
  "models": [
    {"vendor": "claude", "model": "claude-opus-5",   "day": 12.10, "week": 60.00, "month": 201.30},
    {"vendor": "claude", "model": "claude-sonnet-5", "day": 6.30,  "week": 36.10, "month": 111.20},
    {"vendor": "codex",  "model": "gpt-5",           "day": 4.10,  "week": 22.00, "month": 61.20},
    {"vendor": "grok",   "model": "grok-4",          "day": 0.90,  "week": 5.10,  "month": 12.70}
  ],
  "usage": [
    {"vendor": "claude", "window": "daily", "pct": 62, "stale": false},
    {"vendor": "claude", "window": "wk",    "pct": 41, "stale": false},
    {"vendor": "codex",  "window": "5h",    "pct": 71, "stale": false},
    {"vendor": "codex",  "window": "7d",    "pct": 48, "stale": false},
    {"vendor": "grok",   "window": "wk",    "pct": 15, "stale": false}
  ],
  "warnPct": 80,
  "context": {"session": "claudecounter", "pct": 83, "warn": true}
}
```

Rules:

- `spend` has one entry per vendor with any spend in the month. Values
  are USD, rounded to cents. Sums over `Totals.day`, `.week`, `.month`
  by `SeriesKey.vendor`.
- `models` is every `SeriesKey` in `Totals.month` with positive month
  spend, sorted by month spend descending then by model name, capped at
  20 rows. `day` and `week` are looked up from the matching period maps
  and are 0 when absent. The device currently uses only `spend`; the
  per-model rows are there so a later firmware can show them without a
  mac-side change.
- `usage` is exactly what `GaugeRows.build` would render for both bands,
  in that order: Claude budget rows from `limits.toml` (only when the
  budget is set), then Codex, then Grok plan gauges. `pct` is an
  integer 0–999. `stale` mirrors `PlanGauge.stale`; budget rows are
  never stale.
- `warnPct` is the configured `LimitsConfig.warnPct` so the device
  colours bars with the same threshold as the app.
- `context` is the active session with the highest `contextPct`, or
  `null` when there is no active session. `session` is the session's
  display name as the popover shows it. `pct` is an integer. `warn` is
  true when that session carries the `.context` warning.
- `at` is when the payload was built, UTC, ISO 8601 to the second.

## 2. Mac app

### DevicePayload (ClaudeCounterCore, new file `DevicePayload.swift`)

A `Codable` struct tree matching the JSON above plus one pure builder:

```swift
public static func build(totals: Totals,
                         statuses: [LimitStatus],
                         gauges: [PlanGauge],
                         sessions: [SessionStat],
                         warnPct: Int,
                         now: Date) -> DevicePayload
```

Encoded with sorted keys and no pretty-printing so byte equality means
content equality. Tests: fixture `Totals` with three vendors and five
models, checks vendor sums, model ordering and cap, usage order matches
`GaugeRows`, `context` picks the highest session and is null when none
are active, encoding is deterministic.

### DevicePublisher (ClaudeCounterCore, new file `DevicePublisher.swift`)

An `actor` holding the last body sent. `publish(_ payload:, to url:,
token:, session: URLSessionProtocol)`:

- Encodes; if equal to the last sent body, returns `.unchanged` without
  a request.
- PUT with `Authorization: Bearer <token>` and
  `Content-Type: application/json`, 10 s timeout.
- On 2xx stores the body and returns `.sent`. Any other status or
  transport error returns `.failed(String)`; the last body is not
  updated so the next tick retries. No backoff beyond the tick itself.

Tests through the existing `URLSessionProtocol` mock: first send hits
the network, identical second send does not, changed payload sends
again, 401 reports failure and a later identical payload is retried.

### Wiring in AppState

- New settings: `deviceURL: String` in `AppSettings` (UserDefaults,
  default empty). Write token in the Keychain under service
  `ClaudeCounterBar.device`, account `writeToken`, through a small
  `DeviceSecret` helper with a protocol so tests never touch the real
  Keychain. Publishing is enabled iff `deviceURL` is non-empty.
- In `startPeriodicFlush`, after `refreshBudgets` on each tick and after
  `rescanPlanGauges` when it runs, call `publishDevice()`. Also call it
  once from `start()` after the first paint and from the popover's
  manual Refresh.
- `publishDevice()` builds the payload from current published state and
  awaits the publisher off the main actor. `.failed` sets `lastError`
  with the same set-and-clear discipline `refreshBudgets` uses for
  `lastLimitsError` (a `lastDeviceError` field), so a recovered Worker
  clears the banner.

### Popover UI (ClaudeCounterBar, new file `DeviceSettingsView.swift`)

A collapsible "Device" section following `SourcesEditorView`: URL text
field, secure field for the token, Save, and a "Send now" button that
calls `publishDevice()` and shows the result inline (`sent`, `unchanged`,
or the error). No test path, same as the rest of the Bar target.

## 3. Cloudflare Worker (`cloudflare/`)

Files: `wrangler.toml`, `src/index.ts`, `package.json`, `README.md`.

- KV namespace binding `STATE`. Key `state`. TTL 24 h so a dead
  publisher eventually yields 404 rather than a stale body forever.
- Secrets `WRITE_TOKEN` and `READ_TOKEN`, set with `wrangler secret put`.
- `PUT /state`: bearer must equal `WRITE_TOKEN` (constant-time compare),
  body must be ≤ 8 KB and parse as JSON with `v === 1`; stores the raw
  body; responds 204.
- `GET /state`: bearer must equal `READ_TOKEN`; responds 200 with the
  body and `Content-Type: application/json`, or 404 when the key is
  absent.
- Anything else: 404. Wrong or missing token: 401. Oversize or invalid
  body: 400.
- README: `npm install`, `wrangler login`, `wrangler kv namespace create
  STATE`, paste the id into `wrangler.toml`, set both secrets, `wrangler
  deploy`, then a curl PUT and GET round-trip to verify.

Free tier budget: one write per minute and one read every 30 s is
under 3 000 writes and 3 000 reads per day, inside the 1 000-writes/day
KV limit only if the publisher's unchanged-skip works. It does: spend
changes far less than once a minute outside active sessions, and the
Worker README states the assumption. If the limit is hit the mac app
sees 429 and reports it in `lastError`.

## 4. Firmware (`device/core2/`)

Files: `core2.ino`, `secrets.example.h`, `render.h/.cpp`, `net.h/.cpp`,
`alarm.h/.cpp`, `README.md`. `secrets.h` is gitignored.

Libraries, pinned in the README and in a `Makefile` target that drives
`arduino-cli`: M5Unified, ArduinoJson 7, FastLED (for the SK6812 bar on
GPIO 25). Board: `m5stack:esp32:m5stack_core2`.

Deployment must work two ways, both documented and both tried before the
work is called done:

1. **Arduino IDE 2.x**: open the `core2` folder, install the three
   libraries from Library Manager and the M5Stack board package, copy
   `secrets.example.h` to `secrets.h`, fill it in, Upload.
2. **`make device-build` / `make device-flash`** from the repo root:
   installs `arduino-cli` via Homebrew if absent, installs the core and
   libraries, compiles, flashes to the first detected serial port.

`secrets.h` holds `WIFI_SSID`, `WIFI_PASS`, `WORKER_URL`, `READ_TOKEN`.

Behaviour:

- Boot: show "connecting" with the SSID; connect Wi-Fi with a 20 s
  timeout, then retry forever with a 10 s pause. Sync NTP for the header
  clock.
- Every 30 s: HTTPS GET with the bearer token, 8 s timeout. Parse with
  a 4 KB `JsonDocument`. If `v != 1` show "unsupported payload". On
  network or HTTP error keep the last good screen and mark the header
  "offline" with the age of the last good fetch.
- Redraw only when the body's hash changes or the header state
  (clock minute, Wi-Fi bars, stale flag) changes.
- Staleness: if `at` is more than 10 minutes old, header shows "stale"
  and the backlight drops to 30 %. Restores on a fresh `at`.
- Layout (320×240): header row with title, clock and Wi-Fi bars; spend
  table with columns today / week / month per vendor plus a total row;
  usage strip with `vendor window pct` items, coloured green under
  `warnPct`, amber from `warnPct`, red at 100 or above, grey when
  stale; bottom row `ctx <session> <bar> <pct>` with a `!` when warn.
  Text uses the built-in fonts; no custom font files.
- Alarm: on `context.warn` rising edge, set all ten LEDs red and play
  one 200 ms 1 kHz tone. LEDs stay red while warn is true, off when it
  falls. Any touch clears the LEDs until the next rising edge. Touch
  does nothing else.

## Error handling summary

| Failure | Mac app | Worker | Device |
|---|---|---|---|
| Worker down / 5xx | `lastError`, retries next tick | — | keeps last screen, "offline" |
| Bad write token | `lastError` "401" | 401 | — |
| Bad read token | — | 401 | "unauthorised" screen |
| Mac app stopped | — | key expires after 24 h | "stale", then 404 → "no data" |
| Wi-Fi lost | — | — | "connecting", retries |
| Unknown `v` | — | 400 on PUT | "unsupported payload" |

## Testing

- Swift: payload builder and publisher unit tests as above; existing
  suite stays green. Run with `swift test` from `macapp/` (see memory:
  tests must not touch the real config paths).
- Worker: manual curl round-trip in the README; no test harness.
- Firmware: `make device-build` must compile cleanly. Runtime verified
  on the device against the deployed Worker, including forcing a
  context warning to see the LEDs and hear the beep.
