# M5Stack Core2 Device Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The mac app publishes spend and usage JSON to a Cloudflare Worker; an M5Stack Core2 for AWS polls it, renders three button-switched screens (overview, per-model spend, usage bars), and alarms on a context-window warning.

**Architecture:** A pure `DevicePayload.build` in ClaudeCounterCore turns AppState's existing `Totals`, `LimitStatus`, `PlanGauge` and `SessionStat` values into a versioned JSON document. A `DevicePublisher` actor PUTs it to the Worker on the existing 60 s tick, skipping unchanged bodies. The Worker stores the body in KV behind two bearer tokens. Arduino firmware on the Core2 GETs it every 30 s and redraws on change.

**Tech Stack:** Swift 5.9 / SwiftUI (macapp), Cloudflare Workers + KV via wrangler (TypeScript), Arduino for ESP32 with M5Unified, ArduinoJson 7, FastLED; arduino-cli for reproducible builds.

**Spec:** `docs/superpowers/specs/2026-09-04-m5stack-device-display-design.md`

## Global Constraints

- Payload version is `"v": 1`. Consumers ignore unknown keys and reject unknown `v`.
- USD values are rounded to cents. `pct` values are integers.
- `models` capped at 20 rows, sorted by month spend descending then model name.
- Publisher PUT timeout 10 s. Device GET every 30 s with 8 s timeout. Device marks payload stale when `at` is older than 10 minutes.
- KV key `state`, TTL 24 h. PUT body limit 8 KB.
- Three screens: BtnA Overview, BtnB Models (all rows, 8 fit), BtnC Usage bars. Tapping a vendor row on Overview opens Models filtered to that vendor; tapping Models returns to Overview. Starts on Overview, not persisted.
- Board FQBN `m5stack:esp32:m5stack_core2`. Libraries: M5Unified, ArduinoJson (7.x), FastLED. LED bar: 10 × SK6812 on GPIO 25.
- Swift tests run with `cd macapp && swift test`. Never point tests at real config paths under `~/.config/claudecounter` (they can corrupt the installed app's data).
- Commits are SSH-signed. Before each commit in this session run `export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"`.
- Branch: `feat/m5stack-device`.

## File Structure

| Path | Responsibility |
|---|---|
| `macapp/Sources/ClaudeCounterCore/DevicePayload.swift` | Codable payload types and the pure `build` function |
| `macapp/Sources/ClaudeCounterCore/DevicePublisher.swift` | Actor that PUTs the payload, dedupes unchanged bodies |
| `macapp/Sources/ClaudeCounterCore/DeviceSecret.swift` | `DeviceSecretStore` protocol, Keychain and in-memory implementations |
| `macapp/Sources/ClaudeCounterCore/PricingFetch.swift` | Gains a request-based method on `URLSessionProtocol` |
| `macapp/Sources/ClaudeCounterCore/Settings.swift` | Gains `deviceURL` |
| `macapp/Sources/ClaudeCounterCore/AppState.swift` | Gains `publishDevice()`, `setDeviceURL`, `setDeviceToken`, tick wiring |
| `macapp/Sources/ClaudeCounterBar/DeviceSettingsView.swift` | Collapsible "Device" section in the popover |
| `macapp/Sources/ClaudeCounterBar/PopoverView.swift` | Mounts the section, adds a gear-menu entry |
| `macapp/Tests/ClaudeCounterCoreTests/DevicePayloadTests.swift` | Builder tests |
| `macapp/Tests/ClaudeCounterCoreTests/DevicePublisherTests.swift` | Publisher tests |
| `macapp/Tests/ClaudeCounterCoreTests/DeviceSecretTests.swift` | In-memory secret store tests |
| `macapp/Tests/ClaudeCounterCoreTests/SettingsTests.swift` | Gains `deviceURL` round-trip |
| `macapp/Tests/ClaudeCounterCoreTests/AppStateTests.swift` | Gains publish wiring tests |
| `cloudflare/wrangler.toml`, `cloudflare/src/index.ts`, `cloudflare/package.json`, `cloudflare/tsconfig.json`, `cloudflare/README.md` | Worker |
| `device/core2/core2.ino` | Setup and loop |
| `device/core2/secrets.example.h` | Template for the gitignored `secrets.h` |
| `device/core2/net.h`, `device/core2/net.cpp` | Wi-Fi, NTP, HTTPS GET |
| `device/core2/model.h`, `device/core2/model.cpp` | Parsed payload struct and JSON parse |
| `device/core2/render.h`, `device/core2/render.cpp` | Screen drawing |
| `device/core2/alarm.h`, `device/core2/alarm.cpp` | LED bar and beep |
| `device/core2/README.md` | Both deployment paths |
| `Makefile` | `device-deps`, `device-build`, `device-flash` targets |
| `.gitignore` | `device/core2/secrets.h`, `cloudflare/node_modules`, `device/core2/build` |

---

### Task 1: DevicePayload types and builder

**Files:**
- Create: `macapp/Sources/ClaudeCounterCore/DevicePayload.swift`
- Test: `macapp/Tests/ClaudeCounterCoreTests/DevicePayloadTests.swift`

**Interfaces:**
- Consumes: `Totals`, `SeriesKey`, `ModelDay` (Aggregator.swift); `LimitStatus` (Limits.swift); `PlanGauge` (PlanLimits.swift); `SessionStat`, `SessionWarnings` (SessionTracker.swift); `GaugeRows.build(band:statuses:gauges:)`; `shortProjectName(_:)` (Notifications.swift).
- Produces: `public struct DevicePayload: Codable, Equatable, Sendable` with `static func build(totals:statuses:gauges:sessions:warnPct:now:) -> DevicePayload` and `func encoded() throws -> Data`.

- [ ] **Step 1: Write the failing tests**

```swift
// macapp/Tests/ClaudeCounterCoreTests/DevicePayloadTests.swift
import XCTest
@testable import ClaudeCounterCore

final class DevicePayloadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_982_460) // 2025-09-04T10:41:00Z

    private func key(_ vendor: String, _ model: String) -> SeriesKey {
        SeriesKey(source: "\(vendor)/\(vendor)", vendor: vendor, model: model)
    }

    private var totals: Totals {
        var t = Totals()
        t.day = [
            key("claude", "claude-opus-5"): ModelDay(usd: 12.104, tokens: .zero),
            key("claude", "claude-sonnet-5"): ModelDay(usd: 6.3, tokens: .zero),
            key("codex", "gpt-5"): ModelDay(usd: 4.1, tokens: .zero),
        ]
        t.week = [
            key("claude", "claude-opus-5"): ModelDay(usd: 60, tokens: .zero),
            key("codex", "gpt-5"): ModelDay(usd: 22, tokens: .zero),
        ]
        t.month = [
            key("claude", "claude-opus-5"): ModelDay(usd: 201.3, tokens: .zero),
            key("claude", "claude-sonnet-5"): ModelDay(usd: 111.2, tokens: .zero),
            key("codex", "gpt-5"): ModelDay(usd: 61.2, tokens: .zero),
            key("grok", "grok-4"): ModelDay(usd: 12.7, tokens: .zero),
            key("grok", "grok-free"): ModelDay(usd: 0, tokens: .zero),
        ]
        return t
    }

    private var statuses: [LimitStatus] {
        [
            LimitStatus(window: .day, spentUSD: 18.4, limitUSD: 30, pct: 61.3, state: .ok, resetsAt: now),
            LimitStatus(window: .week, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: now),
        ]
    }

    private var gauges: [PlanGauge] {
        [
            PlanGauge(vendor: "grok", windowLabel: "wk", pct: 15.4, resetsAt: now, observed: now, stale: false, plan: ""),
            PlanGauge(vendor: "codex", windowLabel: "7d", pct: 48, resetsAt: now, observed: now, stale: true, plan: "plus"),
            PlanGauge(vendor: "codex", windowLabel: "5h", pct: 71, resetsAt: now, observed: now, stale: false, plan: "plus"),
        ]
    }

    private func session(_ id: String, project: String, pct: Double, warn: Bool) -> SessionStat {
        SessionStat(sessionID: id, project: project, model: "claude-opus-5",
                    costUSD: 1, cost5mUSD: 0, cacheCreate5mUSD: 0,
                    contextTokens: 0, contextWindow: 200_000, contextPct: pct,
                    cacheCreateCostUSD: 0, turns: 3, ageSeconds: 10,
                    warnings: warn ? [.context] : [])
    }

    func test_build_vendorSpendSumsAndRoundsToCents() {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.v, 1)
        XCTAssertEqual(p.at, "2025-09-04T10:41:00Z")
        XCTAssertEqual(p.spend["claude"], DevicePayload.Spend(day: 18.4, week: 60, month: 312.5))
        XCTAssertEqual(p.spend["codex"], DevicePayload.Spend(day: 4.1, week: 22, month: 61.2))
        XCTAssertEqual(p.spend["grok"], DevicePayload.Spend(day: 0, week: 0, month: 12.7))
    }

    func test_build_modelsSortedByMonthThenNameAndZeroDropped() {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.models.map(\.model), ["claude-opus-5", "claude-sonnet-5", "gpt-5", "grok-4"])
        XCTAssertEqual(p.models[0], DevicePayload.ModelSpend(vendor: "claude", model: "claude-opus-5",
                                                             day: 12.1, week: 60, month: 201.3))
        XCTAssertEqual(p.models[3].day, 0)
    }

    func test_build_modelsCappedAtTwenty() {
        var t = Totals()
        for i in 0..<25 {
            t.month[key("claude", String(format: "m-%02d", i))] = ModelDay(usd: Double(100 - i), tokens: .zero)
        }
        let p = DevicePayload.build(totals: t, statuses: [], gauges: [], sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.models.count, 20)
        XCTAssertEqual(p.models.first?.model, "m-00")
        XCTAssertEqual(p.models.last?.model, "m-19")
    }

    func test_build_usageFollowsGaugeRowsOrderAndSkipsUnsetBudget() {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.usage, [
            DevicePayload.Usage(vendor: "claude", window: "daily", pct: 61, stale: false),
            DevicePayload.Usage(vendor: "codex", window: "5h", pct: 71, stale: false),
            DevicePayload.Usage(vendor: "codex", window: "7d", pct: 48, stale: true),
            DevicePayload.Usage(vendor: "grok", window: "wk", pct: 15, stale: false),
        ])
        XCTAssertEqual(p.warnPct, 80)
    }

    func test_build_contextPicksHighestSessionAndShortensProject() {
        let sessions = [
            session("a", project: "-Users-me-src-tries-foo", pct: 0.42, warn: false),
            session("b", project: "-Users-me-src-tries-claudecounter", pct: 0.834, warn: true),
        ]
        let p = DevicePayload.build(totals: totals, statuses: [], gauges: [],
                                    sessions: sessions, warnPct: 80, now: now)
        XCTAssertEqual(p.context, DevicePayload.Context(session: "claudecounter", pct: 83, warn: true))
    }

    func test_build_contextNilWithoutSessions() {
        let p = DevicePayload.build(totals: totals, statuses: [], gauges: [],
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertNil(p.context)
    }

    func test_encoded_isDeterministicAndCompact() throws {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        let a = try p.encoded()
        let b = try p.encoded()
        XCTAssertEqual(a, b)
        let s = String(decoding: a, as: UTF8.self)
        XCTAssertFalse(s.contains("\n"))
        XCTAssertTrue(s.hasPrefix("{\"at\":"), "keys must be sorted so byte equality means content equality")
        XCTAssertTrue(s.contains("\"context\":null"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macapp && swift test --filter DevicePayloadTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'DevicePayload' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// macapp/Sources/ClaudeCounterCore/DevicePayload.swift
import Foundation

/// The document the mac app publishes for the desk device. Version 1.
/// Built only from values `AppState` already holds; see the design at
/// docs/superpowers/specs/2026-09-04-m5stack-device-display-design.md.
///
/// The device reads `spend`, `usage`, `warnPct` and `context`. `models`
/// is published so a later firmware can show per-model rows without a
/// mac-side change.
public struct DevicePayload: Codable, Equatable, Sendable {

    public struct Spend: Codable, Equatable, Sendable {
        public var day: Double
        public var week: Double
        public var month: Double
        public init(day: Double, week: Double, month: Double) {
            self.day = day; self.week = week; self.month = month
        }
    }

    public struct ModelSpend: Codable, Equatable, Sendable {
        public var vendor: String
        public var model: String
        public var day: Double
        public var week: Double
        public var month: Double
        public init(vendor: String, model: String, day: Double, week: Double, month: Double) {
            self.vendor = vendor; self.model = model
            self.day = day; self.week = week; self.month = month
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var vendor: String
        public var window: String
        public var pct: Int
        public var stale: Bool
        public init(vendor: String, window: String, pct: Int, stale: Bool) {
            self.vendor = vendor; self.window = window; self.pct = pct; self.stale = stale
        }
    }

    public struct Context: Codable, Equatable, Sendable {
        public var session: String
        public var pct: Int
        public var warn: Bool
        public init(session: String, pct: Int, warn: Bool) {
            self.session = session; self.pct = pct; self.warn = warn
        }
    }

    public static let currentVersion = 1
    public static let maxModels = 20

    public var v: Int
    public var at: String
    public var spend: [String: Spend]
    public var models: [ModelSpend]
    public var usage: [Usage]
    public var warnPct: Int
    /// Highest-context active session, or nil when none is active.
    /// Encoded as an explicit `null` so the device can distinguish
    /// "no session" from a malformed body.
    public var context: Context?

    enum CodingKeys: String, CodingKey { case v, at, spend, models, usage, warnPct, context }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(at, forKey: .at)
        try c.encode(spend, forKey: .spend)
        try c.encode(models, forKey: .models)
        try c.encode(usage, forKey: .usage)
        try c.encode(warnPct, forKey: .warnPct)
        try c.encode(context, forKey: .context) // encodes nil as null
    }

    /// Compact, sorted-key JSON so two payloads with equal content
    /// produce byte-equal bodies. `DevicePublisher` relies on that to
    /// skip unchanged sends.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func build(totals: Totals,
                             statuses: [LimitStatus],
                             gauges: [PlanGauge],
                             sessions: [SessionStat],
                             warnPct: Int,
                             now: Date) -> DevicePayload {
        // Vendor sums over each period. A vendor appears if it has any
        // spend in the month; day/week default to 0.
        var spend: [String: Spend] = [:]
        for (k, v) in totals.month where v.usd > 0 {
            spend[k.vendor, default: Spend(day: 0, week: 0, month: 0)].month += v.usd
        }
        for (k, v) in totals.day where spend[k.vendor] != nil { spend[k.vendor]!.day += v.usd }
        for (k, v) in totals.week where spend[k.vendor] != nil { spend[k.vendor]!.week += v.usd }
        for (vendor, s) in spend {
            spend[vendor] = Spend(day: cents(s.day), week: cents(s.week), month: cents(s.month))
        }

        // Per-model rows: positive month spend only, then day/week
        // looked up by the same key.
        var models: [ModelSpend] = []
        for (k, v) in totals.month where v.usd > 0 {
            models.append(ModelSpend(vendor: k.vendor, model: k.model,
                                     day: cents(totals.day[k]?.usd ?? 0),
                                     week: cents(totals.week[k]?.usd ?? 0),
                                     month: cents(v.usd)))
        }
        models.sort { a, b in
            if a.month != b.month { return a.month > b.month }
            return a.model < b.model
        }
        if models.count > maxModels { models.removeSubrange(maxModels...) }

        // Usage rows in exactly the order the popover renders them:
        // short band then weekly band, GaugeRows' vendor order inside.
        var usage: [Usage] = []
        for band in [GaugeBand.short, .weekly] {
            for row in GaugeRows.build(band: band, statuses: statuses, gauges: gauges) {
                usage.append(Usage(vendor: row.vendor, window: row.windowLabel,
                                   pct: Int(row.pct.rounded()), stale: row.isStale))
            }
        }

        let top = sessions.max { $0.contextPct < $1.contextPct }
        let context = top.map {
            Context(session: shortProjectName($0.project),
                    pct: Int(($0.contextPct * 100).rounded()),
                    warn: $0.warnings.contains(.context))
        }

        return DevicePayload(v: currentVersion, at: iso(now), spend: spend, models: models,
                             usage: usage, warnPct: warnPct, context: context)
    }

    private static func cents(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macapp && swift test --filter DevicePayloadTests 2>&1 | tail -5`
Expected: `Executed 7 tests, with 0 failures`.

If `test_build_usageFollowsGaugeRowsOrderAndSkipsUnsetBudget` fails on order, check `GaugeRows.build` for `.short`: it returns Claude's `.day` status (window label `daily`) and Codex `5h`; `.weekly` returns Codex `7d` and Grok `wk`, and skips Claude because the week status is `.unset`.

- [ ] **Step 5: Commit**

```bash
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add macapp/Sources/ClaudeCounterCore/DevicePayload.swift macapp/Tests/ClaudeCounterCoreTests/DevicePayloadTests.swift
git commit -m "feat(device): DevicePayload v1 builder and encoder"
```

---

### Task 2: URLSessionProtocol request seam and DevicePublisher

**Files:**
- Modify: `macapp/Sources/ClaudeCounterCore/PricingFetch.swift:108-115`
- Create: `macapp/Sources/ClaudeCounterCore/DevicePublisher.swift`
- Test: `macapp/Tests/ClaudeCounterCoreTests/DevicePublisherTests.swift`

**Interfaces:**
- Consumes: `DevicePayload.encoded()` from Task 1.
- Produces: `URLSessionProtocol.dataReturning(for request: URLRequest)`; `public actor DevicePublisher` with `func publish(_ payload: DevicePayload, to url: URL, token: String, session: URLSessionProtocol) async -> DevicePublisher.Outcome` where `Outcome` is `.sent`, `.unchanged`, `.failed(String)`.

- [ ] **Step 1: Write the failing tests**

```swift
// macapp/Tests/ClaudeCounterCoreTests/DevicePublisherTests.swift
import XCTest
@testable import ClaudeCounterCore

final class DevicePublisherTests: XCTestCase {

    private let url = URL(string: "https://example.workers.dev/state")!

    private func payload(day: Double) -> DevicePayload {
        var t = Totals()
        let k = SeriesKey(source: "claude/claude", vendor: "claude", model: "claude-opus-5")
        t.day[k] = ModelDay(usd: day, tokens: .zero)
        t.month[k] = ModelDay(usd: 100, tokens: .zero)
        return DevicePayload.build(totals: t, statuses: [], gauges: [], sessions: [], warnPct: 80,
                                   now: Date(timeIntervalSince1970: 0))
    }

    func test_publish_sendsPutWithBearerAndJSON() async throws {
        let mock = RecordingSession(status: 204)
        let pub = DevicePublisher()
        let out = await pub.publish(payload(day: 1), to: url, token: "w-secret", session: mock)
        XCTAssertEqual(out, .sent)
        let reqs = await mock.requests
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs[0].httpMethod, "PUT")
        XCTAssertEqual(reqs[0].url, url)
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "Authorization"), "Bearer w-secret")
        XCTAssertEqual(reqs[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(reqs[0].httpBody, try payload(day: 1).encoded())
        XCTAssertEqual(reqs[0].timeoutInterval, 10)
    }

    func test_publish_skipsIdenticalBody() async {
        let mock = RecordingSession(status: 204)
        let pub = DevicePublisher()
        _ = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        let second = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        XCTAssertEqual(second, .unchanged)
        let count = await mock.requests.count
        XCTAssertEqual(count, 1)
    }

    func test_publish_sendsAgainWhenBodyChanges() async {
        let mock = RecordingSession(status: 204)
        let pub = DevicePublisher()
        _ = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        let out = await pub.publish(payload(day: 2), to: url, token: "t", session: mock)
        XCTAssertEqual(out, .sent)
        let count = await mock.requests.count
        XCTAssertEqual(count, 2)
    }

    func test_publish_httpErrorReportsAndRetriesNextTime() async {
        let mock = RecordingSession(status: 401)
        let pub = DevicePublisher()
        let first = await pub.publish(payload(day: 1), to: url, token: "bad", session: mock)
        XCTAssertEqual(first, .failed("HTTP 401"))
        await mock.setStatus(204)
        let second = await pub.publish(payload(day: 1), to: url, token: "bad", session: mock)
        XCTAssertEqual(second, .sent, "a failed send must not be remembered as sent")
    }

    func test_publish_transportErrorReportsMessage() async {
        let mock = RecordingSession(status: 204, error: URLError(.notConnectedToInternet))
        let pub = DevicePublisher()
        let out = await pub.publish(payload(day: 1), to: url, token: "t", session: mock)
        guard case .failed(let msg) = out else { return XCTFail("expected .failed") }
        XCTAssertTrue(msg.contains("offline") || msg.contains("Internet"), msg)
    }
}

/// Records every request; answers with a fixed status or throws.
actor RecordingSession: URLSessionProtocol {
    private(set) var requests: [URLRequest] = []
    private var status: Int
    private let error: Error?

    init(status: Int, error: Error? = nil) {
        self.status = status
        self.error = error
    }

    func setStatus(_ s: Int) { status = s }

    func dataReturning(from url: URL) async throws -> (Data, URLResponse) {
        try await dataReturning(for: URLRequest(url: url))
    }

    func dataReturning(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if let error { throw error }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(), resp)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macapp && swift test --filter DevicePublisherTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'DevicePublisher' in scope`.

- [ ] **Step 3: Extend the URLSessionProtocol seam**

Replace lines 108–115 of `macapp/Sources/ClaudeCounterCore/PricingFetch.swift` with:

```swift
/// Test seam over URLSession. The request-based method has a default
/// so the existing GET-only mocks keep compiling; `DevicePublisher`
/// needs it for PUT with headers and body.
public protocol URLSessionProtocol: Sendable {
    func dataReturning(from url: URL) async throws -> (Data, URLResponse)
    func dataReturning(for request: URLRequest) async throws -> (Data, URLResponse)
}

public extension URLSessionProtocol {
    func dataReturning(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        return try await dataReturning(from: url)
    }
}

extension URLSession: URLSessionProtocol {
    public func dataReturning(from url: URL) async throws -> (Data, URLResponse) {
        try await self.data(from: url)
    }
    public func dataReturning(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.data(for: request)
    }
}
```

- [ ] **Step 4: Write the publisher**

```swift
// macapp/Sources/ClaudeCounterCore/DevicePublisher.swift
import Foundation

/// PUTs a `DevicePayload` to the Cloudflare Worker. Remembers the last
/// body it successfully sent and skips a send whose body is byte-equal,
/// which is what keeps the app inside KV's daily write quota: spend
/// changes far less than once a minute outside an active session.
///
/// No retry or backoff of its own: the caller runs on a 60 s tick, and
/// a failed send is not remembered, so the next tick retries.
public actor DevicePublisher {

    public enum Outcome: Equatable, Sendable {
        case sent
        case unchanged
        case failed(String)
    }

    public static let timeout: TimeInterval = 10

    private var lastSent: Data?

    public init() {}

    public func publish(_ payload: DevicePayload,
                        to url: URL,
                        token: String,
                        session: URLSessionProtocol) async -> Outcome {
        let body: Data
        do { body = try payload.encoded() } catch { return .failed("encode: \(error)") }
        if body == lastSent { return .unchanged }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = Self.timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        do {
            let (_, resp) = try await session.dataReturning(for: req)
            guard let http = resp as? HTTPURLResponse else { return .failed("non-HTTP response") }
            guard (200..<300).contains(http.statusCode) else { return .failed("HTTP \(http.statusCode)") }
            lastSent = body
            return .sent
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Forget the last body so the next `publish` always sends. Used by
    /// the popover's "Send now" so the user gets a real round-trip.
    public func reset() { lastSent = nil }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd macapp && swift test --filter "DevicePublisherTests|PricingFetchAndTOMLTests" 2>&1 | tail -5`
Expected: all pass, including the existing pricing fetch tests whose `MockSession` did not implement the new method.

- [ ] **Step 6: Commit**

```bash
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add macapp/Sources/ClaudeCounterCore/PricingFetch.swift macapp/Sources/ClaudeCounterCore/DevicePublisher.swift macapp/Tests/ClaudeCounterCoreTests/DevicePublisherTests.swift
git commit -m "feat(device): DevicePublisher with unchanged-body skip"
```

---

### Task 3: Device settings: URL in AppSettings, token in Keychain

**Files:**
- Modify: `macapp/Sources/ClaudeCounterCore/Settings.swift`
- Create: `macapp/Sources/ClaudeCounterCore/DeviceSecret.swift`
- Test: `macapp/Tests/ClaudeCounterCoreTests/SettingsTests.swift` (append), `macapp/Tests/ClaudeCounterCoreTests/DeviceSecretTests.swift`

**Interfaces:**
- Produces: `AppSettings.deviceURL: String` (default `""`); `public protocol DeviceSecretStore: Sendable { func readWriteToken() -> String?; func saveWriteToken(_ token: String) throws; func deleteWriteToken() throws }`; `KeychainDeviceSecretStore`; `InMemoryDeviceSecretStore`.

- [ ] **Step 1: Write the failing tests**

Append inside `final class SettingsTests` in `macapp/Tests/ClaudeCounterCoreTests/SettingsTests.swift`:

```swift
    // MARK: - deviceURL

    func test_appSettings_defaults_deviceURLEmpty() {
        XCTAssertEqual(AppSettings.defaults.deviceURL, "", "publishing must be off until the user sets a URL")
    }

    func test_userDefaultsStore_deviceURLRoundTrip() {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let store = UserDefaultsSettingsStore(defaults: ud)
        var s = AppSettings.defaults
        s.deviceURL = "https://x.workers.dev/state"
        store.save(s)
        XCTAssertEqual(store.load().deviceURL, "https://x.workers.dev/state")
    }
```

Create `macapp/Tests/ClaudeCounterCoreTests/DeviceSecretTests.swift`:

```swift
import XCTest
@testable import ClaudeCounterCore

final class DeviceSecretTests: XCTestCase {

    func test_inMemory_roundTripAndDelete() throws {
        let s = InMemoryDeviceSecretStore()
        XCTAssertNil(s.readWriteToken())
        try s.saveWriteToken("abc")
        XCTAssertEqual(s.readWriteToken(), "abc")
        try s.saveWriteToken("def")
        XCTAssertEqual(s.readWriteToken(), "def")
        try s.deleteWriteToken()
        XCTAssertNil(s.readWriteToken())
    }

    // The Keychain store is deliberately NOT exercised here: the test
    // runner would write into the developer's real login keychain.
    // It is verified manually through the popover in Task 5.
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macapp && swift test --filter "SettingsTests|DeviceSecretTests" 2>&1 | tail -5`
Expected: compile errors for `deviceURL` and `InMemoryDeviceSecretStore`.

- [ ] **Step 3: Add deviceURL to AppSettings**

In `macapp/Sources/ClaudeCounterCore/Settings.swift`:

After the `activeWindowMinutes` property doc, add:

```swift
    /// Cloudflare Worker URL the desk device payload is PUT to, e.g.
    /// `https://claudecounter.<account>.workers.dev/state`. Empty means
    /// publishing is off. Default: empty.
    public var deviceURL: String
```

Change `defaults` to include `deviceURL: ""`, and the `init` to take `deviceURL: String = ""` as its last parameter and assign `self.deviceURL = deviceURL`.

In `UserDefaultsSettingsStore` add:

```swift
    static let deviceURLKey = "ClaudeCounterBar.AppSettings.deviceURL"
```

In `load()` add the argument `deviceURL: (defaults.object(forKey: Self.deviceURLKey) as? String) ?? d.deviceURL`. In `save(_:)` add `defaults.set(settings.deviceURL, forKey: Self.deviceURLKey)`.

- [ ] **Step 4: Write DeviceSecret.swift**

```swift
// macapp/Sources/ClaudeCounterCore/DeviceSecret.swift
import Foundation
import Security

/// Where the Worker write token lives. It is a credential, so it stays
/// out of UserDefaults (plaintext plist) and goes in the Keychain.
public protocol DeviceSecretStore: Sendable {
    func readWriteToken() -> String?
    func saveWriteToken(_ token: String) throws
    func deleteWriteToken() throws
}

public enum DeviceSecretError: Error, Equatable {
    case keychain(OSStatus)
}

/// Generic-password item, service `ClaudeCounterBar.device`, account
/// `writeToken`. Never used from tests.
public final class KeychainDeviceSecretStore: DeviceSecretStore {
    static let service = "ClaudeCounterBar.device"
    static let account = "writeToken"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    public func readWriteToken() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveWriteToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeviceSecretError.keychain(status) }
    }

    public func deleteWriteToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceSecretError.keychain(status)
        }
    }
}

/// Test double.
public final class InMemoryDeviceSecretStore: DeviceSecretStore, @unchecked Sendable {
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func readWriteToken() -> String? { token }
    public func saveWriteToken(_ token: String) throws { self.token = token }
    public func deleteWriteToken() throws { token = nil }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd macapp && swift test --filter "SettingsTests|DeviceSecretTests" 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add macapp/Sources/ClaudeCounterCore/Settings.swift macapp/Sources/ClaudeCounterCore/DeviceSecret.swift macapp/Tests/ClaudeCounterCoreTests/SettingsTests.swift macapp/Tests/ClaudeCounterCoreTests/DeviceSecretTests.swift
git commit -m "feat(device): deviceURL setting and Keychain-backed write token"
```

---

### Task 4: Wire publishing into AppState

**Files:**
- Modify: `macapp/Sources/ClaudeCounterCore/AppState.swift` (init around line 131, `start()` after `startPeriodicFlush()`, `refresh()`, `startPeriodicFlush()` around line 903, setters around line 897)
- Test: `macapp/Tests/ClaudeCounterCoreTests/AppStateTests.swift` (append)

**Interfaces:**
- Consumes: `DevicePayload.build`, `DevicePublisher`, `DeviceSecretStore`, `AppSettings.deviceURL`.
- Produces: `AppState.init(..., deviceSession: URLSessionProtocol = URLSession.shared, deviceSecret: DeviceSecretStore? = nil)`; `public func publishDevice(force: Bool = false) async -> DevicePublisher.Outcome?` (nil when publishing is off); `public func setDeviceURL(_:)`; `public func setDeviceToken(_:) throws`; `public var deviceToken: String? { get }`; `@Published public private(set) var lastDeviceOutcome: DevicePublisher.Outcome?`.

- [ ] **Step 1: Write the failing tests**

Append to `macapp/Tests/ClaudeCounterCoreTests/AppStateTests.swift` (inside the file, as a new test class so the flaky incremental test is untouched):

```swift
final class AppStateDevicePublishTests: XCTestCase {

    private func makeApp(deviceURL: String, token: String?, session: URLSessionProtocol) -> (AppState, String) {
        let root = NSTemporaryDirectory() + "asd-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root + "/projects", withIntermediateDirectories: true)
        let cacheURL = URL(fileURLWithPath: root).appendingPathComponent("cache.json")
        var settings = AppSettings.defaults
        settings.deviceURL = deviceURL
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: Aggregator(pricing: .defaults, now: Date.init),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(initial: settings),
            sourcesConfigPath: root + "/nosrc.toml",
            home: root,
            deviceSession: session,
            deviceSecret: InMemoryDeviceSecretStore(token: token)
        )
        return (app, root)
    }

    @MainActor
    func test_publishDevice_offWhenURLEmpty() async {
        let mock = RecordingSession(status: 204)
        let (app, root) = makeApp(deviceURL: "", token: "t", session: mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let out = await app.publishDevice()
        XCTAssertNil(out)
        let n = await mock.requests.count
        XCTAssertEqual(n, 0)
    }

    @MainActor
    func test_publishDevice_sendsOnceThenUnchanged() async {
        let mock = RecordingSession(status: 204)
        let (app, root) = makeApp(deviceURL: "https://x.workers.dev/state", token: "t", session: mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let first = await app.publishDevice()
        XCTAssertEqual(first, .sent)
        let second = await app.publishDevice()
        XCTAssertEqual(second, .unchanged)
        let n = await mock.requests.count
        XCTAssertEqual(n, 1)
        XCTAssertNil(app.lastError)
    }

    @MainActor
    func test_publishDevice_forceResends() async {
        let mock = RecordingSession(status: 204)
        let (app, root) = makeApp(deviceURL: "https://x.workers.dev/state", token: "t", session: mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = await app.publishDevice()
        let out = await app.publishDevice(force: true)
        XCTAssertEqual(out, .sent)
        let n = await mock.requests.count
        XCTAssertEqual(n, 2)
    }

    @MainActor
    func test_publishDevice_missingTokenIsFailure() async {
        let mock = RecordingSession(status: 204)
        let (app, root) = makeApp(deviceURL: "https://x.workers.dev/state", token: nil, session: mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let out = await app.publishDevice()
        XCTAssertEqual(out, .failed("no write token set"))
        XCTAssertEqual(app.lastError, "Device publish failed: no write token set")
    }

    @MainActor
    func test_publishDevice_errorSetsThenClearsLastError() async {
        let mock = RecordingSession(status: 500)
        let (app, root) = makeApp(deviceURL: "https://x.workers.dev/state", token: "t", session: mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        _ = await app.publishDevice()
        XCTAssertEqual(app.lastError, "Device publish failed: HTTP 500")
        await mock.setStatus(204)
        let out = await app.publishDevice()
        XCTAssertEqual(out, .sent)
        XCTAssertNil(app.lastError, "a recovered publish clears the error it set")
    }

    @MainActor
    func test_setDeviceURL_persistsAndSetDeviceToken_stores() throws {
        let mock = RecordingSession(status: 204)
        let (app, root) = makeApp(deviceURL: "", token: nil, session: mock)
        defer { try? FileManager.default.removeItem(atPath: root) }
        app.setDeviceURL("https://y.workers.dev/state")
        XCTAssertEqual(app.settings.deviceURL, "https://y.workers.dev/state")
        try app.setDeviceToken("zzz")
        XCTAssertEqual(app.deviceToken, "zzz")
    }
}
```

`RecordingSession` is defined in `DevicePublisherTests.swift` at module scope (not `private`), so it is visible here.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macapp && swift test --filter AppStateDevicePublishTests 2>&1 | tail -5`
Expected: compile error, extra arguments `deviceSession`/`deviceSecret` in call.

- [ ] **Step 3: Add the stored properties and init parameters**

In `AppState.swift`, next to `private let notifier: SessionNotifier` add:

```swift
    private let deviceSession: URLSessionProtocol
    private let deviceSecret: DeviceSecretStore
    private let devicePublisher = DevicePublisher()
    /// Mirrors whatever `lastError` `publishDevice` most recently set,
    /// same pattern as `lastLimitsError`, so a later successful publish
    /// clears exactly the error it set and nothing else.
    private var lastDeviceError: String? = nil
```

Next to the other `@Published` properties add:

```swift
    /// Result of the most recent `publishDevice`, nil while publishing is
    /// off. The popover's Device section shows it inline.
    @Published public private(set) var lastDeviceOutcome: DevicePublisher.Outcome? = nil
```

Add two init parameters after `pricingOverrideURL: URL? = nil`:

```swift
                deviceSession: URLSessionProtocol = URLSession.shared,
                deviceSecret: DeviceSecretStore? = nil) {
```

and in the body:

```swift
        self.deviceSession = deviceSession
        self.deviceSecret = deviceSecret ?? KeychainDeviceSecretStore()
```

- [ ] **Step 4: Add publishDevice and the setters**

Below `setNotificationsEnabled`:

```swift
    // MARK: Device publishing

    /// The Worker write token, read from the secret store each time so
    /// the popover reflects what is actually stored.
    public var deviceToken: String? { deviceSecret.readWriteToken() }

    public func setDeviceURL(_ url: String) {
        settings.deviceURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsStore.save(settings)
    }

    public func setDeviceToken(_ token: String) throws {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { try deviceSecret.deleteWriteToken() } else { try deviceSecret.saveWriteToken(t) }
    }

    /// Builds the current payload and PUTs it to the configured Worker.
    /// Returns nil when `settings.deviceURL` is empty (publishing off).
    /// `force` bypasses the publisher's unchanged-body skip; the popover's
    /// "Send now" uses it so the user sees a real round-trip.
    ///
    /// Failures land in `lastError` with the set-and-clear discipline
    /// `refreshBudgets` uses: only the error this method set is cleared
    /// on recovery.
    @discardableResult
    public func publishDevice(force: Bool = false) async -> DevicePublisher.Outcome? {
        let urlString = settings.deviceURL
        guard !urlString.isEmpty else { return nil }

        let outcome: DevicePublisher.Outcome
        if let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
            if let token = deviceSecret.readWriteToken(), !token.isEmpty {
                let payload = DevicePayload.build(totals: totals,
                                                  statuses: limitStatuses,
                                                  gauges: planGauges,
                                                  sessions: activeSessions,
                                                  warnPct: warnPct,
                                                  now: now())
                if force { await devicePublisher.reset() }
                outcome = await devicePublisher.publish(payload, to: url, token: token, session: deviceSession)
            } else {
                outcome = .failed("no write token set")
            }
        } else {
            outcome = .failed("invalid URL")
        }

        switch outcome {
        case .failed(let msg):
            let message = "Device publish failed: \(msg)"
            lastError = message
            lastDeviceError = message
        case .sent, .unchanged:
            if lastError != nil && lastError == lastDeviceError { lastError = nil }
            lastDeviceError = nil
        }
        lastDeviceOutcome = outcome
        return outcome
    }
```

- [ ] **Step 5: Hook it into the lifecycle**

In `startPeriodicFlush()`, after the `if self.gaugeRescanTickCount >= ...` block and before `await self.flushCache()`, add:

```swift
                // Publish after budgets (and possibly gauges) refreshed so
                // the device sees this tick's numbers. Cheap when nothing
                // changed: the publisher skips byte-equal bodies.
                await self.publishDevice()
```

In `start()`, immediately after `startPeriodicFlush()`, add `await publishDevice()`.

In `refresh()` (line ~280), after its `await publishSnapshot()` and gauge refresh, add `await publishDevice()`.

- [ ] **Step 6: Run the tests**

Run: `cd macapp && swift test --filter "AppStateDevicePublishTests|DevicePublisherTests" 2>&1 | tail -5`
Expected: all pass.

Then run the full suite once: `cd macapp && swift test 2>&1 | tail -3`. Expected: 0 failures, except `AppStateTests.test_appState_picksUpNewEventLive` which is known flaky; rerun once if only that fails.

- [ ] **Step 7: Commit**

```bash
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add macapp/Sources/ClaudeCounterCore/AppState.swift macapp/Tests/ClaudeCounterCoreTests/AppStateTests.swift
git commit -m "feat(device): publish payload on tick, start and refresh"
```

---

### Task 5: Popover "Device" section

**Files:**
- Create: `macapp/Sources/ClaudeCounterBar/DeviceSettingsView.swift`
- Modify: `macapp/Sources/ClaudeCounterBar/PopoverView.swift` (mount near line 128; gear menu near line 1257)

**Interfaces:**
- Consumes: `AppState.settings.deviceURL`, `deviceToken`, `setDeviceURL`, `setDeviceToken`, `publishDevice(force:)`, `lastDeviceOutcome`.

No unit test path exists for the Bar target. Verification is `swift build` plus a manual check.

- [ ] **Step 1: Write the view**

```swift
// macapp/Sources/ClaudeCounterBar/DeviceSettingsView.swift
import SwiftUI
import ClaudeCounterCore

/// Inline, collapsible editor for the desk-device publisher, mounted in
/// `PopoverView`'s scroll area the same way `SourcesEditorView` is.
/// URL persists via `AppSettings`; the write token goes to the Keychain
/// through `AppState.setDeviceToken`.
struct DeviceSettingsView: View {
    @ObservedObject var state: AppState
    @Binding var isExpanded: Bool

    @State private var url: String
    @State private var token: String
    @State private var message: String?
    @State private var sending = false

    init(state: AppState, isExpanded: Binding<Bool>) {
        self.state = state
        self._isExpanded = isExpanded
        _url = State(initialValue: state.settings.deviceURL)
        _token = State(initialValue: state.deviceToken ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Device")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { isExpanded = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            Text("Publishes spend and usage to a Cloudflare Worker for the desk display. Empty URL turns publishing off. See cloudflare/README.md.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("https://claudecounter.<account>.workers.dev/state", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            SecureField("Write token", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(message.hasPrefix("Error") ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    save()
                    Task {
                        sending = true
                        let out = await state.publishDevice(force: true)
                        sending = false
                        switch out {
                        case .none: message = "Publishing is off (empty URL)."
                        case .sent: message = "Sent."
                        case .unchanged: message = "Unchanged."
                        case .failed(let m): message = "Error: \(m)"
                        }
                    }
                } label: {
                    Text(sending ? "Sending…" : "Send now").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .disabled(sending)
                Spacer()
                Button {
                    save()
                } label: {
                    Text("Save").font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func save() {
        state.setDeviceURL(url)
        do {
            try state.setDeviceToken(token)
            message = "Saved."
        } catch {
            message = "Error: could not store token in Keychain (\(error))"
        }
    }
}
```

- [ ] **Step 2: Mount it in PopoverView**

Find the `@State` that backs `showSettings` in `PopoverView` and add beside it:

```swift
    @State private var showDevice = false
```

In the scroll area, directly after the `if showSettings { SourcesEditorView(...) }` block (line ~130), add:

```swift
                    if showDevice {
                        DeviceSettingsView(state: state, isExpanded: $showDevice)
                    }
```

`FooterRow` receives `showSettings` as a binding; add `@Binding var showDevice: Bool` to it, pass `showDevice: $showDevice` where `FooterRow` is constructed, and in the gear `Menu` after `Button("Edit sources…") { showSettings = true }` add:

```swift
                Button("Device display…") { showDevice = true }
```

- [ ] **Step 3: Build**

Run: `cd macapp && swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 4: Manual check**

Run: `make macapp-debug && open dist/ClaudeCounterBar.app`. Open the popover, gear menu, "Device display…". Enter a bogus URL like `https://127.0.0.1:1/state` and any token, Save, Send now. Expected: an `Error:` line appears and the footer status shows `Device publish failed: …`. Clear the URL, Save, Send now. Expected: "Publishing is off (empty URL)." and the footer error clears. Quit the debug app.

- [ ] **Step 5: Commit**

```bash
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add macapp/Sources/ClaudeCounterBar/DeviceSettingsView.swift macapp/Sources/ClaudeCounterBar/PopoverView.swift
git commit -m "feat(macapp): Device section in popover for Worker URL and token"
```

---

### Task 6: Cloudflare Worker

**Files:**
- Create: `cloudflare/wrangler.toml`, `cloudflare/package.json`, `cloudflare/tsconfig.json`, `cloudflare/src/index.ts`, `cloudflare/README.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: payload shape from Task 1 (only checks `v === 1`).
- Produces: `PUT /state` (Bearer `WRITE_TOKEN`) and `GET /state` (Bearer `READ_TOKEN`) on the deployed Worker URL.

- [ ] **Step 1: Write the config files**

`cloudflare/wrangler.toml`:

```toml
name = "claudecounter"
main = "src/index.ts"
compatibility_date = "2026-09-01"

# Created with: npx wrangler kv namespace create STATE
# Paste the printed id below.
[[kv_namespaces]]
binding = "STATE"
id = "REPLACE_WITH_NAMESPACE_ID"
```

`cloudflare/package.json`:

```json
{
  "name": "claudecounter-worker",
  "private": true,
  "scripts": {
    "deploy": "wrangler deploy",
    "dev": "wrangler dev"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.20250801.0",
    "typescript": "^5.6.0",
    "wrangler": "^4.30.0"
  }
}
```

`cloudflare/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "es2022",
    "module": "es2022",
    "lib": ["es2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noEmit": true,
    "moduleResolution": "bundler"
  },
  "include": ["src"]
}
```

Append to `.gitignore`:

```
# cloudflare worker
cloudflare/node_modules/
cloudflare/.wrangler/
```

- [ ] **Step 2: Write the Worker**

```ts
// cloudflare/src/index.ts
export interface Env {
  STATE: KVNamespace;
  WRITE_TOKEN: string;
  READ_TOKEN: string;
}

const KEY = "state";
const TTL_SECONDS = 24 * 60 * 60;
const MAX_BODY = 8 * 1024;

function bearer(req: Request): string {
  const h = req.headers.get("Authorization") ?? "";
  return h.startsWith("Bearer ") ? h.slice(7) : "";
}

// Constant-time compare so a token can't be guessed byte by byte from
// response timing.
function equal(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  if (ea.length !== eb.length) return false;
  let diff = 0;
  for (let i = 0; i < ea.length; i++) diff |= ea[i] ^ eb[i];
  return diff === 0;
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/state") return new Response("not found", { status: 404 });

    if (req.method === "PUT") {
      if (!env.WRITE_TOKEN || !equal(bearer(req), env.WRITE_TOKEN)) {
        return new Response("unauthorized", { status: 401 });
      }
      const body = await req.text();
      if (body.length > MAX_BODY) return new Response("too large", { status: 400 });
      let parsed: unknown;
      try {
        parsed = JSON.parse(body);
      } catch {
        return new Response("invalid json", { status: 400 });
      }
      if (typeof parsed !== "object" || parsed === null || (parsed as { v?: unknown }).v !== 1) {
        return new Response("unsupported payload version", { status: 400 });
      }
      await env.STATE.put(KEY, body, { expirationTtl: TTL_SECONDS });
      return new Response(null, { status: 204 });
    }

    if (req.method === "GET") {
      if (!env.READ_TOKEN || !equal(bearer(req), env.READ_TOKEN)) {
        return new Response("unauthorized", { status: 401 });
      }
      const body = await env.STATE.get(KEY);
      if (body === null) return new Response("no data", { status: 404 });
      return new Response(body, {
        status: 200,
        headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
      });
    }

    return new Response("not found", { status: 404 });
  },
};
```

- [ ] **Step 3: Type-check**

Run: `cd cloudflare && npm install && npx tsc -p . 2>&1 | tail -3`
Expected: no output (clean).

- [ ] **Step 4: Write the README**

```markdown
# claudecounter Worker

Stores the mac app's device payload in KV and serves it to the M5Stack.

## One-time setup

    cd cloudflare
    npm install
    npx wrangler login
    npx wrangler kv namespace create STATE
    # paste the printed id into wrangler.toml under [[kv_namespaces]]
    openssl rand -hex 24   # write token
    openssl rand -hex 24   # read token
    npx wrangler secret put WRITE_TOKEN
    npx wrangler secret put READ_TOKEN
    npx wrangler deploy

`wrangler deploy` prints the Worker URL, e.g.
`https://claudecounter.<account>.workers.dev`. The app and the device use
`<that URL>/state`.

## Verify

    URL=https://claudecounter.<account>.workers.dev/state
    curl -sS -X PUT "$URL" -H "Authorization: Bearer $WRITE" \
      -H 'Content-Type: application/json' -d '{"v":1,"spend":{}}' -w '%{http_code}\n'   # 204
    curl -sS "$URL" -H "Authorization: Bearer $READ"                                     # echoes the body
    curl -sS "$URL" -H "Authorization: Bearer wrong" -w '%{http_code}\n'                 # 401

## Wire it up

- Mac app: gear menu → Device display… → paste the URL and the write
  token → Save → Send now.
- Device: put the URL and the read token in `device/core2/secrets.h`.

## Quota

Free-tier KV allows 1 000 writes per day. The mac app only PUTs when the
payload's bytes changed, which is well under that in normal use. If the
Worker returns 429 the app shows `Device publish failed: HTTP 429` in
the popover footer. Reads are one per 30 s from the device, about 2 900
per day, under the 100 000 free reads.

The stored value expires 24 h after the last PUT, so a stopped mac app
eventually yields 404 and the device shows "no data" rather than a
day-old number forever.
```

- [ ] **Step 5: Deploy and round-trip**

Follow the README's one-time setup on the user's Cloudflare account, then run the three `curl` lines. Expected: `204`, the echoed JSON, `401`. Record the Worker URL for Task 8. If `wrangler login` needs a browser, ask the user to run `! npx wrangler login` in `cloudflare/`.

- [ ] **Step 6: Commit**

```bash
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add cloudflare .gitignore
git commit -m "feat(cloudflare): Worker storing device payload in KV behind bearer tokens"
```

---

### Task 7: Firmware

**Files:**
- Create: `device/core2/core2.ino`, `device/core2/secrets.example.h`, `device/core2/net.h`, `device/core2/net.cpp`, `device/core2/model.h`, `device/core2/model.cpp`, `device/core2/render.h`, `device/core2/render.cpp`, `device/core2/alarm.h`, `device/core2/alarm.cpp`, `device/core2/README.md`
- Modify: `Makefile`, `.gitignore`

**Interfaces:**
- Consumes: `GET /state` from Task 6, payload v1 from Task 1.
- Produces: a flashable sketch. Internal interfaces are given in each header below.

- [ ] **Step 1: Makefile targets and gitignore**

Append to `.gitignore`:

```
# device firmware
device/core2/secrets.h
device/core2/build/
```

Append to `Makefile` before the `# ─── meta ───` section:

```make
# ────────────────────── M5Stack Core2 firmware (Arduino) ──────────────────────

DEVICE_DIR  := device/core2
DEVICE_FQBN := m5stack:esp32:m5stack_core2
M5_INDEX    := https://static-cdn.m5stack.com/resource/arduino/package_m5stack_index.json
DEVICE_PORT ?= $(shell ls /dev/cu.usbserial-* /dev/cu.wchusbserial* 2>/dev/null | head -1)

.PHONY: device-deps
device-deps: ## Install arduino-cli (brew), the M5Stack core and the sketch's libraries
	@command -v arduino-cli >/dev/null || brew install arduino-cli
	arduino-cli config init --overwrite --additional-urls $(M5_INDEX)
	arduino-cli core update-index
	arduino-cli core install m5stack:esp32
	arduino-cli lib install "M5Unified" "ArduinoJson" "FastLED"

.PHONY: device-build
device-build: ## Compile the Core2 sketch (needs device/core2/secrets.h)
	@test -f $(DEVICE_DIR)/secrets.h || { echo "copy $(DEVICE_DIR)/secrets.example.h to secrets.h and fill it in"; exit 1; }
	arduino-cli compile --fqbn $(DEVICE_FQBN) --output-dir $(DEVICE_DIR)/build $(DEVICE_DIR)

.PHONY: device-flash
device-flash: device-build ## Compile and upload to the first USB serial port (override with DEVICE_PORT=)
	@test -n "$(DEVICE_PORT)" || { echo "no serial port found; plug in the Core2 or set DEVICE_PORT="; exit 1; }
	arduino-cli upload --fqbn $(DEVICE_FQBN) --port $(DEVICE_PORT) --input-dir $(DEVICE_DIR)/build

.PHONY: device-monitor
device-monitor: ## Serial monitor at 115200
	arduino-cli monitor --port $(DEVICE_PORT) --config baudrate=115200
```

- [ ] **Step 2: secrets template**

```cpp
// device/core2/secrets.example.h
// Copy to secrets.h (gitignored) and fill in.
#pragma once

#define WIFI_SSID   "your-wifi"
#define WIFI_PASS   "your-password"
// Worker URL including the /state path.
#define WORKER_URL  "https://claudecounter.<account>.workers.dev/state"
// The READ token from `wrangler secret put READ_TOKEN`, never the write token.
#define READ_TOKEN  "replace-me"
```

- [ ] **Step 3: model.h / model.cpp**

```cpp
// device/core2/model.h
#pragma once
#include <Arduino.h>

struct VendorSpend { String vendor; float day; float week; float month; };
struct ModelRow    { String vendor; String model; float day; float month; };
struct UsageRow    { String vendor; String window; int pct; bool stale; };

struct Payload {
  bool valid = false;
  int version = 0;
  time_t at = 0;               // parsed from "at", UTC
  VendorSpend spend[4]; int spendCount = 0;
  ModelRow models[20];  int modelCount = 0;   // payload order (sorted by month spend)
  UsageRow usage[8];    int usageCount = 0;
  int warnPct = 80;
  bool hasContext = false;
  String ctxSession; int ctxPct = 0; bool ctxWarn = false;
};

// Parses a v1 body. Returns false (and sets valid=false) on malformed
// JSON or a version other than 1.
bool parsePayload(const String& body, Payload& out);

// Parses "2026-09-04T10:41:00Z" into a UTC time_t; 0 on failure.
time_t parseIso8601Utc(const char* s);
```

```cpp
// device/core2/model.cpp
#include "model.h"
#include <ArduinoJson.h>
#include <time.h>

time_t parseIso8601Utc(const char* s) {
  struct tm t = {};
  if (!s || sscanf(s, "%4d-%2d-%2dT%2d:%2d:%2d", &t.tm_year, &t.tm_mon, &t.tm_mday,
                   &t.tm_hour, &t.tm_min, &t.tm_sec) != 6) return 0;
  t.tm_year -= 1900;
  t.tm_mon -= 1;
  // timegm is not in the ESP32 libc; mktime assumes local time, but we
  // configure the device clock with TZ=UTC (see net.cpp) so they agree.
  return mktime(&t);
}

static const char* VENDOR_ORDER[] = {"claude", "codex", "grok"};

bool parsePayload(const String& body, Payload& out) {
  out = Payload();
  JsonDocument doc;
  if (deserializeJson(doc, body)) return false;
  out.version = doc["v"] | 0;
  if (out.version != 1) return false;
  out.at = parseIso8601Utc(doc["at"] | "");
  out.warnPct = doc["warnPct"] | 80;

  // Fixed vendor order so rows never reshuffle between polls.
  JsonObject spend = doc["spend"];
  for (const char* v : VENDOR_ORDER) {
    if (!spend[v].is<JsonObject>()) continue;
    if (out.spendCount >= 4) break;
    VendorSpend& s = out.spend[out.spendCount++];
    s.vendor = v;
    s.day = spend[v]["day"] | 0.0f;
    s.week = spend[v]["week"] | 0.0f;
    s.month = spend[v]["month"] | 0.0f;
  }

  for (JsonObject m : doc["models"].as<JsonArray>()) {
    if (out.modelCount >= 20) break;
    ModelRow& r = out.models[out.modelCount++];
    r.vendor = (const char*)(m["vendor"] | "");
    r.model = (const char*)(m["model"] | "");
    r.day = m["day"] | 0.0f;
    r.month = m["month"] | 0.0f;
  }

  for (JsonObject u : doc["usage"].as<JsonArray>()) {
    if (out.usageCount >= 8) break;
    UsageRow& r = out.usage[out.usageCount++];
    r.vendor = (const char*)(u["vendor"] | "");
    r.window = (const char*)(u["window"] | "");
    r.pct = u["pct"] | 0;
    r.stale = u["stale"] | false;
  }

  if (doc["context"].is<JsonObject>()) {
    out.hasContext = true;
    out.ctxSession = (const char*)(doc["context"]["session"] | "");
    out.ctxPct = doc["context"]["pct"] | 0;
    out.ctxWarn = doc["context"]["warn"] | false;
  }
  out.valid = true;
  return true;
}
```

- [ ] **Step 4: net.h / net.cpp**

```cpp
// device/core2/net.h
#pragma once
#include <Arduino.h>

enum class FetchStatus { Ok, Unauthorized, NoData, HttpError, NetworkError };

// Blocks until connected or timeoutMs elapses. Returns connection state.
bool wifiConnect(uint32_t timeoutMs);
bool wifiUp();
int  wifiBars();                 // 0..4 from RSSI
void ntpStart();                 // configTime with TZ=UTC
bool clockValid();               // true once NTP has set the clock

// GET WORKER_URL with the read token. On Ok, body holds the response.
FetchStatus fetchState(String& body, int& httpCode);
```

```cpp
// device/core2/net.cpp
#include "net.h"
#include "secrets.h"
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <time.h>

bool wifiConnect(uint32_t timeoutMs) {
  if (WiFi.status() == WL_CONNECTED) return true;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < timeoutMs) delay(250);
  return WiFi.status() == WL_CONNECTED;
}

bool wifiUp() { return WiFi.status() == WL_CONNECTED; }

int wifiBars() {
  if (!wifiUp()) return 0;
  int rssi = WiFi.RSSI();
  if (rssi > -55) return 4;
  if (rssi > -65) return 3;
  if (rssi > -75) return 2;
  return 1;
}

void ntpStart() {
  // UTC everywhere on the device; parseIso8601Utc relies on mktime
  // being UTC. The header clock is rendered in UTC too — see README.
  configTzTime("UTC0", "pool.ntp.org", "time.cloudflare.com");
}

bool clockValid() { return time(nullptr) > 1700000000; }

FetchStatus fetchState(String& body, int& httpCode) {
  httpCode = 0;
  if (!wifiUp()) return FetchStatus::NetworkError;
  WiFiClientSecure client;
  // No certificate verification: the ESP32 Arduino core ships no root
  // bundle reachable from HTTPClient without embedding a cert file.
  // The only secret at risk to a MITM on this Wi-Fi is the read-only
  // token. Documented in README.md.
  client.setInsecure();
  HTTPClient http;
  http.setTimeout(8000);
  http.setConnectTimeout(8000);
  if (!http.begin(client, WORKER_URL)) return FetchStatus::NetworkError;
  http.addHeader("Authorization", String("Bearer ") + READ_TOKEN);
  httpCode = http.GET();
  FetchStatus st;
  if (httpCode == 200) { body = http.getString(); st = FetchStatus::Ok; }
  else if (httpCode == 401) st = FetchStatus::Unauthorized;
  else if (httpCode == 404) st = FetchStatus::NoData;
  else if (httpCode > 0) st = FetchStatus::HttpError;
  else st = FetchStatus::NetworkError;
  http.end();
  return st;
}
```

- [ ] **Step 5: alarm.h / alarm.cpp**

```cpp
// device/core2/alarm.h
#pragma once

void alarmInit();
// Call every loop with the current warn flag and whether the screen was
// touched this iteration. Handles the rising edge (LEDs red + one beep),
// steady state (LEDs stay red), touch silence, and falling edge (off).
void alarmUpdate(bool warn, bool touched);
```

```cpp
// device/core2/alarm.cpp
#include "alarm.h"
#include <M5Unified.h>
#include <FastLED.h>

static const int LED_PIN = 25;   // SK6812 bar on Core2 for AWS
static const int LED_COUNT = 10;
static CRGB leds[LED_COUNT];
static bool wasWarn = false;
static bool silenced = false;

static void setBar(CRGB c) {
  for (int i = 0; i < LED_COUNT; i++) leds[i] = c;
  FastLED.show();
}

void alarmInit() {
  FastLED.addLeds<SK6812, LED_PIN, GRB>(leds, LED_COUNT);
  FastLED.setBrightness(40);
  setBar(CRGB::Black);
}

void alarmUpdate(bool warn, bool touched) {
  if (warn && !wasWarn) {
    silenced = false;
    setBar(CRGB::Red);
    M5.Speaker.tone(1000, 200);   // one 200 ms beep at 1 kHz
  } else if (!warn && wasWarn) {
    setBar(CRGB::Black);
  } else if (warn && touched && !silenced) {
    silenced = true;
    setBar(CRGB::Black);
  }
  wasWarn = warn;
}
```

- [ ] **Step 6: render.h / render.cpp**

```cpp
// device/core2/render.h
#pragma once
#include "model.h"

struct HeaderState {
  int hour = -1, minute = -1;  // -1 until the clock is valid
  int wifiBars = 0;
  bool stale = false;          // payload older than 10 min
  bool offline = false;        // last fetch failed
  int offlineMinutes = 0;      // age of last good fetch when offline
};

enum class Screen { Overview = 0, Models = 1, Usage = 2 };

void renderInit();
void renderMessage(const char* line1, const char* line2);   // full-screen status
// vendorFilter is empty for "all vendors" (Models screen only).
void renderPayload(const Payload& p, const HeaderState& h, Screen screen, const String& vendorFilter);
void renderSetDim(bool dim);                                 // 30 % backlight when true

// Overview spend rows occupy y in [SPEND_Y0, SPEND_Y0 + n*SPEND_ROW_H).
// Returns the vendor whose row contains y, or "" if none.
String vendorAtY(const Payload& p, int y);
```

```cpp
// device/core2/render.cpp
#include "render.h"
#include <M5Unified.h>

static const int W = 320, H = 240;
static const uint16_t BG = TFT_BLACK, FG = TFT_WHITE, DIM = 0x7BEF;
static const uint16_t OK_C = 0x07E0, WARN_C = 0xFD20, OVER_C = 0xF800, STALE_C = DIM;

void renderInit() {
  M5.Display.setRotation(1);
  M5.Display.fillScreen(BG);
  M5.Display.setTextDatum(top_left);
  M5.Display.setBrightness(200);
}

void renderSetDim(bool dim) { M5.Display.setBrightness(dim ? 60 : 200); }

void renderMessage(const char* line1, const char* line2) {
  M5.Display.fillScreen(BG);
  M5.Display.setTextColor(FG, BG);
  M5.Display.setTextSize(2);
  M5.Display.drawString(line1, 12, 90);
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString(line2, 12, 120);
}

static uint16_t pctColor(int pct, int warnPct, bool stale) {
  if (stale) return STALE_C;
  if (pct >= 100) return OVER_C;
  if (pct >= warnPct) return WARN_C;
  return OK_C;
}

static String usd(float v) {
  char buf[16];
  if (v >= 1000) snprintf(buf, sizeof buf, "$%.0f", v);
  else snprintf(buf, sizeof buf, "$%.2f", v);
  return String(buf);
}

static void drawHeader(const HeaderState& h) {
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString("claudecounter", 8, 6);
  char clock[8] = "--:--";
  if (h.hour >= 0) snprintf(clock, sizeof clock, "%02d:%02d", h.hour, h.minute);
  M5.Display.drawString(clock, 200, 6);
  if (h.offline) {
    char msg[24]; snprintf(msg, sizeof msg, "offline %dm", h.offlineMinutes);
    M5.Display.setTextColor(WARN_C, BG); M5.Display.drawString(msg, 120, 6);
  } else if (h.stale) {
    M5.Display.setTextColor(WARN_C, BG); M5.Display.drawString("stale", 140, 6);
  }
  for (int i = 0; i < 4; i++) {
    int bh = 3 + i * 3;
    M5.Display.fillRect(288 + i * 6, 16 - bh, 4, bh, i < h.wifiBars ? FG : 0x2104);
  }
  M5.Display.drawFastHLine(0, 22, W, DIM);
}

// Tab strip under the header; the active screen is bright and underlined.
// Positioned over the three touch buttons' columns so the mapping is obvious.
static void drawTabs(Screen active, const String& vendorFilter) {
  String modelsName = vendorFilter.length() ? "models: " + vendorFilter : String("models");
  const char* names[3] = {"overview", modelsName.c_str(), "usage"};
  const int centers[3] = {64, 160, 256};
  M5.Display.setTextSize(1);
  M5.Display.setTextDatum(top_center);
  for (int i = 0; i < 3; i++) {
    bool on = (int)active == i;
    M5.Display.setTextColor(on ? FG : DIM, BG);
    M5.Display.drawString(names[i], centers[i], 26);
    if (on) M5.Display.drawFastHLine(centers[i] - 24, 36, 48, FG);
  }
  M5.Display.setTextDatum(top_left);
}

static String shortModel(const String& id) {
  // Drop the "claude-" prefix and truncate so a row fits.
  String m = id;
  if (m.startsWith("claude-")) m = m.substring(7);
  if (m.length() > 14) m = m.substring(0, 14);
  return m;
}

static void drawContextRow(const Payload& p) {
  const int cy = 212;
  M5.Display.setTextSize(2);
  if (p.hasContext) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("ctx", 8, cy);
    String name = p.ctxSession;
    if (name.length() > 12) name = name.substring(0, 12);
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(name.c_str(), 52, cy);
    const int bx = 206, bw = 100, bh = 12;
    uint16_t c = p.ctxWarn ? OVER_C : (p.ctxPct >= p.warnPct ? WARN_C : OK_C);
    M5.Display.drawRect(bx, cy + 2, bw, bh, DIM);
    M5.Display.fillRect(bx + 1, cy + 3, (bw - 2) * min(p.ctxPct, 100) / 100, bh - 2, c);
    M5.Display.setTextSize(1);
    M5.Display.setTextColor(c, BG);
    char pct[8]; snprintf(pct, sizeof pct, "%d%%%s", p.ctxPct, p.ctxWarn ? " !" : "");
    M5.Display.drawString(pct, bx, cy + 16);
  } else {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no active session", 8, cy);
  }
}

static void drawModels(const Payload& p, const String& vendorFilter) {
  const int y0 = 44, rowH = 18;
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.setTextDatum(top_right);
  M5.Display.drawString("today", 230, y0);
  M5.Display.drawString("month", 310, y0);
  M5.Display.setTextDatum(top_left);
  int y = y0 + 12;
  int shown = 0;
  for (int i = 0; i < p.modelCount && y + rowH <= 204; i++) {
    const ModelRow& m = p.models[i];
    if (vendorFilter.length() && m.vendor != vendorFilter) continue;
    shown++;
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString(m.vendor.c_str(), 8, y);
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(shortModel(m.model).c_str(), 56, y);
    M5.Display.setTextDatum(top_right);
    M5.Display.drawString(usd(m.day).c_str(), 230, y);
    M5.Display.drawString(usd(m.month).c_str(), 310, y);
    M5.Display.setTextDatum(top_left);
    y += rowH;
  }
  if (shown == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no model spend this month", 8, y);
  }
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString("tap to return", 8, 196);
}

static void drawUsageBars(const Payload& p) {
  const int y0 = 46, rowH = 26, bx = 120, bw = 120, bh = 12;
  M5.Display.setTextSize(1);
  int y = y0;
  for (int i = 0; i < p.usageCount && y + rowH <= 204; i++) {
    const UsageRow& u = p.usage[i];
    uint16_t c = pctColor(u.pct, p.warnPct, u.stale);
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(u.vendor.c_str(), 8, y + 2);
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString(u.window.c_str(), 70, y + 2);
    M5.Display.drawRect(bx, y, bw, bh, DIM);
    M5.Display.fillRect(bx + 1, y + 1, (bw - 2) * min(u.pct, 100) / 100, bh - 2, c);
    M5.Display.setTextColor(c, BG);
    char pct[12]; snprintf(pct, sizeof pct, "%d%%%s", u.pct, u.stale ? " stale" : "");
    M5.Display.drawString(pct, bx + bw + 8, y + 2);
    y += rowH;
  }
  if (p.usageCount == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no usage windows reported", 8, y);
  }
}

static const int SPEND_Y0 = 58, SPEND_ROW_H = 22;

String vendorAtY(const Payload& p, int y) {
  int idx = (y - SPEND_Y0) / SPEND_ROW_H;
  if (y < SPEND_Y0 || idx < 0 || idx >= p.spendCount) return "";
  return p.spend[idx].vendor;
}

static void drawOverview(const Payload& p) {
  // Spend table: vendor | today | week | month, right-aligned numbers.
  // Row geometry is shared with vendorAtY so taps land on the right row.
  const int y0 = SPEND_Y0 - 14, rowH = SPEND_ROW_H;
  M5.Display.setTextSize(1);
  M5.Display.setTextColor(DIM, BG);
  M5.Display.setTextDatum(top_right);
  M5.Display.drawString("today", 150, y0);
  M5.Display.drawString("week", 230, y0);
  M5.Display.drawString("month", 310, y0);
  M5.Display.setTextDatum(top_left);

  float td = 0, tw = 0, tm = 0;
  int y = y0 + 14;
  M5.Display.setTextSize(2);
  for (int i = 0; i < p.spendCount; i++) {
    const VendorSpend& s = p.spend[i];
    M5.Display.setTextColor(FG, BG);
    M5.Display.drawString(s.vendor.c_str(), 8, y);
    M5.Display.setTextDatum(top_right);
    M5.Display.drawString(usd(s.day).c_str(), 150, y);
    M5.Display.drawString(usd(s.week).c_str(), 230, y);
    M5.Display.drawString(usd(s.month).c_str(), 310, y);
    M5.Display.setTextDatum(top_left);
    td += s.day; tw += s.week; tm += s.month;
    y += rowH;
  }
  if (p.spendCount == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no spend this month", 8, y);
    y += rowH;
  }
  M5.Display.drawFastHLine(8, y, W - 16, DIM);
  y += 4;
  M5.Display.setTextColor(DIM, BG);
  M5.Display.drawString("total", 8, y);
  M5.Display.setTextDatum(top_right);
  M5.Display.drawString(usd(td).c_str(), 150, y);
  M5.Display.drawString(usd(tw).c_str(), 230, y);
  M5.Display.drawString(usd(tm).c_str(), 310, y);
  M5.Display.setTextDatum(top_left);

  // Usage strip: one line, wraps to a second if needed.
  int uy = 182;
  M5.Display.drawFastHLine(0, uy - 6, W, DIM);
  M5.Display.setTextSize(1);
  int x = 8;
  for (int i = 0; i < p.usageCount; i++) {
    const UsageRow& u = p.usage[i];
    String label = u.vendor + " " + u.window + " ";
    char pct[8]; snprintf(pct, sizeof pct, "%d%%", u.pct);
    int wLabel = M5.Display.textWidth(label.c_str());
    int wPct = M5.Display.textWidth(pct);
    if (x + wLabel + wPct + 12 > W) { x = 8; uy += 12; }
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString(label.c_str(), x, uy);
    M5.Display.setTextColor(pctColor(u.pct, p.warnPct, u.stale), BG);
    M5.Display.drawString(pct, x + wLabel, uy);
    x += wLabel + wPct + 12;
  }
  if (p.usageCount == 0) {
    M5.Display.setTextColor(DIM, BG);
    M5.Display.drawString("no usage windows reported", 8, uy);
  }
}

void renderPayload(const Payload& p, const HeaderState& h, Screen screen, const String& vendorFilter) {
  M5.Display.startWrite();
  M5.Display.fillScreen(BG);
  drawHeader(h);
  drawTabs(screen, vendorFilter);
  switch (screen) {
    case Screen::Overview: drawOverview(p); break;
    case Screen::Models:   drawModels(p, vendorFilter); break;
    case Screen::Usage:    drawUsageBars(p); break;
  }
  drawContextRow(p);
  M5.Display.endWrite();
}
```

- [ ] **Step 7: core2.ino**

```cpp
// device/core2/core2.ino
// M5Stack Core2 for AWS desk display for claudecounter.
// Polls the Cloudflare Worker (see ../../cloudflare/README.md) every
// 30 s and renders spend + usage. Alarms on a context-window warning.
#include <M5Unified.h>
#include <time.h>
#include "secrets.h"
#include "model.h"
#include "net.h"
#include "render.h"
#include "alarm.h"

static const uint32_t POLL_MS = 30000;
static const uint32_t WIFI_TIMEOUT_MS = 20000;
static const uint32_t WIFI_RETRY_MS = 10000;
static const time_t STALE_AFTER_S = 10 * 60;

static Payload payload;
static String lastBody;
static HeaderState header;
static HeaderState drawnHeader;
static bool havePayload = false;
static uint32_t lastPollMs = 0;
static time_t lastGoodFetch = 0;
static bool bodyChanged = false;
static Screen screen = Screen::Overview;
static Screen drawnScreen = Screen::Overview;
static String vendorFilter;        // Models screen filter, "" = all
static String drawnVendorFilter;

static void connectWifiBlocking() {
  while (!wifiConnect(WIFI_TIMEOUT_MS)) {
    renderMessage("connecting", WIFI_SSID);
    delay(WIFI_RETRY_MS);
  }
}

static void poll() {
  String body; int code;
  FetchStatus st = fetchState(body, code);
  time_t now = time(nullptr);
  switch (st) {
    case FetchStatus::Ok:
      lastGoodFetch = now;
      header.offline = false;
      if (body != lastBody) {
        Payload p;
        if (parsePayload(body, p)) { payload = p; havePayload = true; lastBody = body; bodyChanged = true; }
        else { renderMessage("unsupported payload", "expected v=1; update firmware"); havePayload = false; }
      }
      break;
    case FetchStatus::Unauthorized:
      renderMessage("unauthorised", "check READ_TOKEN in secrets.h"); havePayload = false; break;
    case FetchStatus::NoData:
      renderMessage("no data", "mac app has not published yet"); havePayload = false; break;
    default:
      header.offline = true;
      header.offlineMinutes = lastGoodFetch ? (int)((now - lastGoodFetch) / 60) : 0;
      if (!havePayload) { char msg[32]; snprintf(msg, sizeof msg, "HTTP %d", code); renderMessage("offline", msg); }
      break;
  }
}

void setup() {
  auto cfg = M5.config();
  M5.begin(cfg);
  Serial.begin(115200);
  renderInit();
  alarmInit();
  connectWifiBlocking();
  ntpStart();
  renderMessage("connected", "fetching...");
  lastPollMs = millis() - POLL_MS;  // poll immediately
}

void loop() {
  M5.update();
  // The three touch buttons under the display switch screens; any touch,
  // including those, also silences the alarm.
  if (M5.BtnA.wasPressed()) { screen = Screen::Overview; }
  if (M5.BtnB.wasPressed()) { screen = Screen::Models; vendorFilter = ""; }
  if (M5.BtnC.wasPressed()) { screen = Screen::Usage; }
  bool screenTap = M5.Touch.getCount() > 0 && M5.Touch.getDetail(0).wasPressed();
  if (screenTap && havePayload) {
    auto t = M5.Touch.getDetail(0);
    if (screen == Screen::Overview) {
      // Tap a vendor's spend row → that vendor's models.
      String v = vendorAtY(payload, t.y);
      if (v.length()) { screen = Screen::Models; vendorFilter = v; }
    } else if (screen == Screen::Models) {
      screen = Screen::Overview;
    }
  }
  bool touched = screenTap || M5.BtnA.wasPressed() || M5.BtnB.wasPressed() || M5.BtnC.wasPressed();

  if (!wifiUp()) { connectWifiBlocking(); lastPollMs = millis() - POLL_MS; }

  if (millis() - lastPollMs >= POLL_MS) { lastPollMs = millis(); poll(); }

  // Header state that changes without a new body.
  time_t now = time(nullptr);
  if (clockValid()) { struct tm t; gmtime_r(&now, &t); header.hour = t.tm_hour; header.minute = t.tm_min; }
  header.wifiBars = wifiBars();
  header.stale = havePayload && payload.at > 0 && clockValid() && (now - payload.at) > STALE_AFTER_S;
  renderSetDim(header.stale);

  bool headerChanged = header.hour != drawnHeader.hour || header.minute != drawnHeader.minute ||
                       header.wifiBars != drawnHeader.wifiBars || header.stale != drawnHeader.stale ||
                       header.offline != drawnHeader.offline || header.offlineMinutes != drawnHeader.offlineMinutes;
  if (havePayload && (bodyChanged || headerChanged || screen != drawnScreen || vendorFilter != drawnVendorFilter)) {
    renderPayload(payload, header, screen, vendorFilter);
    drawnHeader = header;
    drawnScreen = screen;
    drawnVendorFilter = vendorFilter;
    bodyChanged = false;
  }

  alarmUpdate(havePayload && payload.hasContext && payload.ctxWarn, touched);
  delay(50);
}
```

- [ ] **Step 8: README**

```markdown
# Core2 desk display

Shows the mac app's spend and usage on an M5Stack Core2 for AWS. Reads
`GET /state` from the Cloudflare Worker in `../../cloudflare`.

## Configure

    cp secrets.example.h secrets.h
    # edit: WIFI_SSID, WIFI_PASS, WORKER_URL (with /state), READ_TOKEN

`secrets.h` is gitignored. Use the READ token only; the write token
never goes on the device.

## Build and flash, option A: make + arduino-cli

    make device-deps      # once: installs arduino-cli, the M5Stack core and libraries
    make device-build
    make device-flash     # plug in over USB-C first; DEVICE_PORT=/dev/cu.xxx to override
    make device-monitor   # optional serial log

## Build and flash, option B: Arduino IDE 2.x

1. Preferences → Additional boards manager URLs, add
   `https://static-cdn.m5stack.com/resource/arduino/package_m5stack_index.json`.
2. Boards Manager → install "M5Stack".
3. Library Manager → install M5Unified, ArduinoJson (7.x), FastLED.
4. Tools → Board → M5Stack → M5Core2. Tools → Port → the Core2's port.
5. File → Open → `device/core2/core2.ino`. Upload.

## What it shows

Three screens, switched with the three touch buttons under the display
(left, middle, right). The header and the context row are on all three.

- Header: title, UTC clock, Wi-Fi bars. "stale" and a dimmed backlight
  when the payload is older than 10 minutes; "offline Nm" when the last
  fetch failed. A tab strip shows which screen is active.
- Overview (left button): spend table per vendor with today, this ISO
  week and this month, plus a total row, and a usage strip with each
  reported window as `vendor window pct`.
- Models (middle button): models by month spend with today and month
  columns. Tap a vendor's row on Overview to see only that vendor's
  models; tap the Models screen to go back.
- Usage (right button): one bar per reported window.
- Context row: the active session with the highest context use, with a
  bar and `!` when it is over the warning threshold.
- Colours: green below the app's warn percentage, amber above it, red at
  100, grey if stale.

## Alarm

When the context warning turns on, the LED bar goes red and the speaker
beeps once. LEDs stay red while the warning holds. Touch the screen or
any button to turn the LEDs off until the next new warning.

## Security note

The device does not verify the Worker's TLS certificate (`setInsecure`):
the ESP32 Arduino core has no built-in root bundle reachable from
HTTPClient. A man-in-the-middle on your Wi-Fi could read the read-only
token, which grants nothing but reading the same JSON. Rotate it with
`wrangler secret put READ_TOKEN` if that matters.

## Troubleshooting

- "unauthorised": READ_TOKEN does not match the Worker secret.
- "no data": the mac app has not published, or the key expired after 24 h.
- "unsupported payload": the mac app publishes a newer `v`; update the firmware.
- Clock shows `--:--`: NTP not synced yet, or UDP 123 blocked.
```

- [ ] **Step 9: Compile**

Run:

```bash
cp device/core2/secrets.example.h device/core2/secrets.h
make device-deps
make device-build 2>&1 | tail -15
```

Expected: `Sketch uses N bytes` with no errors. Fix compile errors in place. Known risks to check first if it fails:

- `JsonDocument` requires ArduinoJson 7; if 6 got installed, run `arduino-cli lib install "ArduinoJson@7.4.1"`.
- `M5.Touch.getDetail(0).wasPressed()` exists in M5Unified ≥ 0.1.x.
- If FastLED complains about the ESP32 RMT driver on core 3.x, add `#define FASTLED_RMT5 1` above the FastLED include, or pin the core with `arduino-cli core install m5stack:esp32@2.1.4`.

- [ ] **Step 10: Flash and verify on the device**

Fill in the real `secrets.h`, then `make device-flash`. Expected on screen within a minute: "connecting" → "connected / fetching..." → the spend table with live numbers from the Worker. Check:

1. Header clock appears within 30 s of connecting.
2. The usage strip shows the Codex and Grok windows the popover shows.
3. Quit the mac app for 11 minutes: header shows "stale", backlight dims. Relaunch: clears.
4. Press the middle and right buttons: the Models and Usage screens
   appear with the tab strip moving; the left button returns to Overview.
   Tap the "codex" row on Overview: the Models screen shows only Codex
   models and the tab reads "models: codex". Tap it again to return.
5. Trigger a context warning: in the mac app gear menu lower the context warn threshold (or open a long Claude session). The LED bar goes red and one beep sounds. Touch the screen: LEDs off. When the warning clears in the app, the `!` disappears.

If the device is not on hand, complete Step 9 and mark Step 10 as not verified in the final report.

- [ ] **Step 11: Commit**

```bash
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add device Makefile .gitignore
git status --short   # secrets.h must NOT appear
git commit -m "feat(device): Core2 firmware polling the Worker, spend table, usage strip, context alarm"
```

---

### Task 8: End-to-end check and docs

**Files:**
- Modify: `README.md` (root)

- [ ] **Step 1: Point the mac app at the deployed Worker**

`make macapp-debug && open dist/ClaudeCounterBar.app`. Gear → Device display… → paste the Worker URL and the write token → Save → Send now. Expected: "Sent." Then `curl -sS "$URL" -H "Authorization: Bearer $READ" | head -c 300` shows the live payload with `"v":1`.

- [ ] **Step 2: Confirm the device reflects a change**

Run a short Claude turn so today's spend changes. Within about 90 s (60 s tick plus 30 s poll) the device's today column updates.

- [ ] **Step 3: Add a section to the root README**

After the existing macapp section, add:

```markdown
## Desk display (M5Stack Core2)

The menu bar app can publish its spend and usage to a Cloudflare Worker,
and an M5Stack Core2 for AWS shows them on your desk with an LED alarm
when a session's context window runs hot.

- Worker: `cloudflare/README.md`
- Firmware: `device/core2/README.md`
- Mac app: gear menu → Device display…
```

- [ ] **Step 4: Full test run and commit**

```bash
cd macapp && swift test 2>&1 | tail -3 && cd ..
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
git add README.md
git commit -m "docs: desk display overview"
```

Expected: 0 failures (rerun once if only the known-flaky `test_appState_picksUpNewEventLive` fails).

---

## Self-review notes

- Spec §1 payload: Task 1. Spec §2 builder, publisher, settings, wiring, popover: Tasks 1–5. Spec §3 Worker: Task 6. Spec §4 firmware, three screens and buttons, both deploy paths, alarm, staleness: Task 7. Error table: Tasks 4, 6, 7. Testing section: Tasks 1–4 unit, 6 curl, 7 compile and on-device.
- Names checked across tasks: `DevicePayload.build(totals:statuses:gauges:sessions:warnPct:now:)`, `DevicePublisher.publish(_:to:token:session:)`, `DevicePublisher.Outcome`, `reset()`, `DeviceSecretStore`, `InMemoryDeviceSecretStore(token:)`, `AppState.publishDevice(force:)`, `setDeviceURL`, `setDeviceToken`, `deviceToken`, `lastDeviceOutcome`, `RecordingSession` (module scope), `AppSettings.deviceURL`.
- `refresh()` in AppState: the executor must read the function once to place `await publishDevice()` after its gauge refresh, since line numbers shift after Task 4's insertions.
