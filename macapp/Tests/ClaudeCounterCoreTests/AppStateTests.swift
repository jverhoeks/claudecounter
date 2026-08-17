import XCTest
@testable import ClaudeCounterCore

@MainActor
final class AppStateTests: XCTestCase {

    // MARK: - Real pricing-override path guard
    //
    // On 2026-08-16, `test_refreshPricingIfStale_staleSchema_...` (and
    // its siblings below) called `AppState.refreshPricingIfStale` with a
    // mock fetcher, and the method's hardcoded `writeToAppOverride()`
    // call wrote the mock's one-model stub straight to the REAL
    // `~/Library/Application Support/claudecounter-bar/pricing.toml` —
    // silently pricing every Claude/Codex model at $0.00 in the
    // developer's installed menu-bar app. `AppState` now takes an
    // injectable `pricingOverrideURL`; every test below passes a temp
    // one. This setUp/tearDown pair is the tripwire: if any test in this
    // file — now or added later — forgets to inject one and falls
    // through to the real path, this fails with that test's name
    // attached, instead of silently corrupting a developer's machine
    // again.
    private var realOverrideExistedBeforeTest = false
    private var realOverrideContentsBeforeTest: Data?

    override func setUp() {
        super.setUp()
        guard let url = try? PricingTable.appOverrideURL() else { return }
        realOverrideExistedBeforeTest = FileManager.default.fileExists(atPath: url.path)
        realOverrideContentsBeforeTest = try? Data(contentsOf: url)
    }

    override func tearDown() {
        if let url = try? PricingTable.appOverrideURL() {
            let existsNow = FileManager.default.fileExists(atPath: url.path)
            XCTAssertEqual(existsNow, realOverrideExistedBeforeTest,
                "this test wrote to the REAL pricing override path \(url.path) — " +
                "inject AppState(pricingOverrideURL:) with a temp URL instead")
            if existsNow {
                XCTAssertEqual(try? Data(contentsOf: url), realOverrideContentsBeforeTest,
                    "this test modified the REAL pricing override path \(url.path) — " +
                    "inject AppState(pricingOverrideURL:) with a temp URL instead")
            }
        }
        super.tearDown()
    }

    // MARK: - LiveEventBuffer

    func test_liveBuffer_pushNewest_atFront() {
        var buf = LiveEventBuffer(capacity: 3)
        for i in 0..<3 {
            buf.push(LiveEvent(timestamp: Date(), project: "p\(i)",
                               model: "m", usd: Double(i), isSubagent: false))
        }
        XCTAssertEqual(buf.items.map { $0.project }, ["p2", "p1", "p0"])
    }

    func test_liveBuffer_capRespected() {
        var buf = LiveEventBuffer(capacity: 2)
        for i in 0..<5 {
            buf.push(LiveEvent(timestamp: Date(), project: "p\(i)",
                               model: "m", usd: Double(i), isSubagent: false))
        }
        XCTAssertEqual(buf.items.count, 2)
        XCTAssertEqual(buf.items.map { $0.project }, ["p4", "p3"])
    }

    // A costed event's dollar figure must be used as given, not re-priced
    // from the table — the table has no entry for a Grok model and would
    // otherwise show $0 for every Grok row in the popover's Live section.
    func test_liveEvent_from_costedEvent_usesCostUSDNotPricingTable() {
        let costed = UsageEvent(
            timestamp: Date(), sessionID: "s1", cwd: "", project: "-Users-me-src-proj",
            model: "grok-4.6-build", messageID: "p1", requestID: "grok-4.6-build",
            isSubagent: false, usage: Usage(input: 100, output: 50),
            costUSD: 0.3721028, costed: true
        )
        XCTAssertEqual(LiveEvent.from(costed, pricing: .defaults).usd, 0.3721028, accuracy: 1e-9)
    }

    // A non-costed (Claude) event still prices from the table, unchanged.
    func test_liveEvent_from_nonCostedEvent_pricesFromTable() {
        let priced = UsageEvent(
            timestamp: Date(), sessionID: "s1", cwd: "", project: "-Users-me-src-proj",
            model: "claude-opus-4-8", messageID: "p1", requestID: "r1",
            isSubagent: false, usage: Usage(input: 1_000_000)
        )
        XCTAssertEqual(LiveEvent.from(priced, pricing: .defaults).usd, 5.0, accuracy: 1e-9)
    }

    // MARK: - scanCutoff

    func test_scanCutoff_noCache_usesGoFloor() {
        // 2026-04-15: floor = min(2026-04-01, 2026-03-11) = 2026-03-11.
        var c = DateComponents(); c.year = 2026; c.month = 4; c.day = 15
        let now = Calendar.current.date(from: c)!
        let cutoff = scanCutoff(now: now)
        let expected = Calendar.current.date(byAdding: .day, value: -35, to: now)!
        XCTAssertEqual(cutoff.timeIntervalSince(expected), 0, accuracy: 1)
    }

    func test_scanCutoff_recentCache_usesCacheFloor() {
        // Cache 2 hours ago → cutoff = cacheTime - 5min.
        var c = DateComponents(); c.year = 2026; c.month = 4; c.day = 26; c.hour = 14
        let now = Calendar.current.date(from: c)!
        let cacheTime = now.addingTimeInterval(-2 * 3600)
        let cutoff = scanCutoff(now: now, cacheWrittenAt: cacheTime)
        XCTAssertEqual(cutoff, cacheTime.addingTimeInterval(-5 * 60))
    }

    func test_scanCutoff_staleCache_capsAtGoFloor() {
        // Cache 90 days ago → cap at the Go floor (now-35d).
        var c = DateComponents(); c.year = 2026; c.month = 4; c.day = 26; c.hour = 14
        let now = Calendar.current.date(from: c)!
        let cacheTime = now.addingTimeInterval(-90 * 86_400)
        let cutoff = scanCutoff(now: now, cacheWrittenAt: cacheTime)
        let goFloor = Calendar.current.date(byAdding: .day, value: -35, to: now)!
        XCTAssertEqual(cutoff.timeIntervalSince(goFloor), 0, accuracy: 1)
    }

    // MARK: - End-to-end: live FSEvents pipeline

    /// Boot AppState pointed at a temp `projects/` dir. Append a JSONL
    /// line, expect totals to reflect the event within ~5s.
    func test_appState_picksUpNewEventLive() async throws {
        let root = NSTemporaryDirectory() + "as-\(UUID().uuidString)"
        let projects = root + "/projects/p1"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let now: () -> Date = { Date() }
        let agg = Aggregator(pricing: .defaults, now: now)
        // Pass in-memory dock + settings so the test never mutates
        // the actual NSApp activation policy / UserDefaults.
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            // Isolates this test from whatever real
            // ~/.config/claudecounter/sources.toml a developer machine
            // happens to have configured.
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            now: now,
            home: root
        )
        await app.start()

        // Wait for status to flip to .live or .scanning (cache cold start
        // should land in .live very quickly because the projects dir is empty).
        try await Task.sleep(nanoseconds: 200_000_000)

        // Drop a fresh JSONL line under the watched tree.
        let path = projects + "/sess.jsonl"
        let line = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        // Poll up to 5s for the totals to reflect the event.
        let deadline = Date().addingTimeInterval(5.0)
        var finalUSD: Double = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            let total = app.totals.day[SeriesKey(source: "claude/claude", vendor: "claude", model: "claude-opus-4-7")]?.usd ?? 0
            if total > 0 {
                finalUSD = total
                break
            }
        }

        await app.stop()
        XCTAssertEqual(finalUSD, 5.0, accuracy: 1e-6,
                       "expected $5.00 from 1M opus input tokens after live FSEvent")
    }

    /// Refresh: invalidates cache, rescans, totals reset and rebuild.
    func test_appState_refresh_rebuildsFromScratch() async throws {
        let root = NSTemporaryDirectory() + "as-r-\(UUID().uuidString)"
        let projects = root + "/projects/p1"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let path = projects + "/sess.jsonl"
        let line = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-r-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: root
        )
        await app.start()
        let opusKey = SeriesKey(source: "claude/claude", vendor: "claude", model: "claude-opus-4-7")
        XCTAssertGreaterThan(app.totals.day[opusKey]?.usd ?? 0, 0)

        await app.refresh()
        XCTAssertGreaterThan(app.totals.day[opusKey]?.usd ?? 0, 0,
                             "Refresh should rebuild totals from disk")
        await app.stop()
    }

    // MARK: - Budget vs. vendor-scan cadence split (final-review.md I-1)

    /// `refreshBudgets` is the cheap half of what used to be a single
    /// `refreshGauges`: a `limits.toml` read plus the pure
    /// `Limits.evaluate`, no filesystem walk. It must update
    /// `limitStatuses`/`warnPct` from the config it's given, and must
    /// NOT touch `planGauges` — that's the whole point of splitting it
    /// out, so the periodic loop can call this every tick (60s) without
    /// paying for the vendor rescan every tick too.
    func test_refreshBudgets_updatesStatusesAndWarnPct_leavesPlanGaugesUntouched() async throws {
        let root = NSTemporaryDirectory() + "as-lim-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/projects", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-lim-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let configPath = NSTemporaryDirectory() + "limits-\(UUID().uuidString).toml"
        try "[limits]\ndaily = 50.0\nweekly = 250.0\nwarn_pct = 70\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: root
        )
        await app.start()
        // Whatever start()'s own full rescan found (real machine state,
        // not asserted on) — refreshBudgets below must leave it exactly
        // as it is.
        let gaugesBeforeBudgetRefresh = app.planGauges

        await app.refreshBudgets(configPath: configPath)

        XCTAssertEqual(app.warnPct, 70)
        XCTAssertEqual(app.limitStatuses.count, 2)
        XCTAssertTrue(app.limitStatuses.contains { $0.window == .day && $0.limitUSD == 50 })
        XCTAssertTrue(app.limitStatuses.contains { $0.window == .week && $0.limitUSD == 250 })
        XCTAssertEqual(app.planGauges, gaugesBeforeBudgetRefresh,
                       "refreshBudgets must not touch planGauges — that's rescanPlanGauges' job")

        await app.stop()
    }

    /// `rescanPlanGauges` is the expensive half: the vendor filesystem
    /// walk. It must not touch `limitStatuses` — that's `refreshBudgets`'
    /// job, called on a different (faster) cadence by the periodic loop.
    func test_rescanPlanGauges_leavesLimitStatusesUntouched() async throws {
        let root = NSTemporaryDirectory() + "as-scan-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/projects", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-scan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let configPath = NSTemporaryDirectory() + "limits-\(UUID().uuidString).toml"
        try "[limits]\ndaily = 50.0\nweekly = 250.0\nwarn_pct = 70\n"
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: root
        )
        await app.start()
        await app.refreshBudgets(configPath: configPath)
        let statusesBeforeRescan = app.limitStatuses

        await app.rescanPlanGauges()

        XCTAssertEqual(app.limitStatuses, statusesBeforeRescan,
                       "rescanPlanGauges must not touch limitStatuses — that's refreshBudgets' job")

        await app.stop()
    }

    /// The split must not change any of the three behaviours the
    /// pre-split `refreshGauges` got right: a malformed config degrades
    /// to no rows (never a crash), the resulting `lastError` is scoped
    /// to `refreshBudgets`'s own error (`lastLimitsError`) so a later
    /// clean load clears exactly that error and nothing else, and
    /// `warnPct` falls back to the default rather than staying at a
    /// stale, possibly stricter, value.
    func test_refreshBudgets_malformedConfig_degradesToNoRows_thenClearsOwnErrorOnFix() async throws {
        let root = NSTemporaryDirectory() + "as-bad-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/projects", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let configPath = NSTemporaryDirectory() + "limits-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: root
        )
        await app.start()

        try "[limits]\ndaily = = =\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        await app.refreshBudgets(configPath: configPath)

        XCTAssertEqual(app.limitStatuses, [], "malformed config must degrade to no rows, not a crash")
        XCTAssertNotNil(app.lastError, "a malformed limits.toml must surface once via lastError")
        XCTAssertEqual(app.warnPct, LimitsConfig.defaultWarnPct,
                       "warnPct must fall back to the default, not stay at a stale prior value")

        // Fix the typo — the error WE set must clear itself without a
        // manual Refresh, and the rows must come back.
        try "[limits]\ndaily = 50.0\nweekly = 250.0\n".write(toFile: configPath, atomically: true, encoding: .utf8)
        await app.refreshBudgets(configPath: configPath)

        XCTAssertNil(app.lastError, "a fixed limits.toml should clear the error refreshBudgets itself set")
        XCTAssertEqual(app.limitStatuses.count, 2)

        await app.stop()
    }

    // MARK: - Dock icon wiring

    /// Boot AppState with `dockIconEnabled = true` (the default) and an
    /// in-memory dock controller. The first publishSnapshot — which
    /// happens whether or not files are present — should make the dock
    /// icon visible AND stamp a badge with the formatted today total.
    func test_appState_start_appliesDockSetting_andStampsBadge() async throws {
        let root = NSTemporaryDirectory() + "as-d-\(UUID().uuidString)"
        let projects = root + "/projects/p1"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Drop a single $5 opus event so today's USD is non-zero on
        // first snapshot (the default $0.00 badge would also work, but
        // proving the value flows through is more useful).
        let path = projects + "/sess.jsonl"
        let line = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-d-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let dock = InMemoryDockIconController()
        let store = InMemorySettingsStore()  // defaults: dockIconEnabled = true
        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: dock,
            settingsStore: store,
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: root
        )
        await app.start()
        await app.stop()

        XCTAssertTrue(dock.isVisible, "dock icon should be visible after start")
        XCTAssertEqual(dock.badge, "$5",
                       "dock badge should reflect today's USD as whole dollars after first snapshot")
    }

    /// Boot AppState with `dockIconEnabled = false`. The dock controller
    /// should stay hidden and the badge should never be stamped.
    func test_appState_start_withDockDisabled_keepsDockHidden() async throws {
        let root = NSTemporaryDirectory() + "as-d2-\(UUID().uuidString)"
        let projects = root + "/projects/p1"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-d2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let dock = InMemoryDockIconController()
        let store = InMemorySettingsStore(initial: AppSettings(dockIconEnabled: false))
        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: dock,
            settingsStore: store,
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: root
        )
        await app.start()
        await app.stop()

        XCTAssertFalse(dock.isVisible, "dock icon should stay hidden when disabled")
        XCTAssertNil(dock.badge, "no badge should be stamped when dock is hidden")
        // The controller's setBadge call IS made (snapshot publishing
        // is unconditional), but it's a no-op while hidden — the
        // recorded calls show the attempts, the visible badge stays nil.
    }

    /// Toggling at runtime: starts with dock off, user enables, dock
    /// flips to visible AND the current spend is stamped immediately.
    func test_appState_setDockIconEnabled_togglesAndPersists() async throws {
        let root = NSTemporaryDirectory() + "as-d3-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/projects", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-d3-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let dock = InMemoryDockIconController()
        let store = InMemorySettingsStore(initial: AppSettings(dockIconEnabled: false))
        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: dock,
            settingsStore: store,
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: root
        )
        await app.start()
        XCTAssertFalse(dock.isVisible)

        // User flips the toggle on → dock becomes visible and the badge
        // is stamped (zero spend in this empty fixture, so $0).
        app.setDockIconEnabled(true)
        XCTAssertTrue(dock.isVisible)
        XCTAssertEqual(dock.badge, "$0")
        XCTAssertTrue(store.load().dockIconEnabled,
                      "preference should be persisted via the store")

        // Flip back off — dock hides, badge clears.
        app.setDockIconEnabled(false)
        XCTAssertFalse(dock.isVisible)
        XCTAssertNil(dock.badge)
        XCTAssertFalse(store.load().dockIconEnabled)

        await app.stop()
    }

    // MARK: - Multi-source scanning (Task 10 global constraints)

    /// Two configured sources with disjoint roots must each accumulate
    /// their own totals under their own `SeriesKey.source`, never
    /// merged and never dropped. This is the test that would fail if a
    /// call site forgot to stamp the real source/vendor onto an event.
    func test_appState_twoSources_attributeIndependently() async throws {
        let base = NSTemporaryDirectory() + "as-multi-\(UUID().uuidString)"
        let workProjects = base + "/work/projects/p1"
        let personalProjects = base + "/personal/projects/p1"
        try FileManager.default.createDirectory(atPath: workProjects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: personalProjects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let ts = ISO8601DateFormatter().string(from: Date())
        // 1M opus input tokens ($5) under "work", 2M under "personal" —
        // distinct amounts so a bug that merges or drops one source's
        // events instead of properly separating them is visible, not
        // just "both happen to read the same number".
        let workLine = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        let personalLine = #"{"type":"assistant","message":{"id":"m2","model":"claude-opus-4-7","usage":{"input_tokens":2000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s2","cwd":"/tmp/y","requestId":"r2"}"#
        try (workLine + "\n").write(toFile: workProjects + "/sess.jsonl", atomically: true, encoding: .utf8)
        try (personalLine + "\n").write(toFile: personalProjects + "/sess.jsonl", atomically: true, encoding: .utf8)

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "claude"
        label = "work"
        root = "\(base)/work/projects"

        [[source]]
        vendor = "claude"
        label = "personal"
        root = "\(base)/personal/projects"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-multi-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: base + "/work/projects", // unused once sources.toml resolves
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: base
        )
        await app.start()

        XCTAssertEqual(Set(app.sources.map { $0.id }), ["claude/work", "claude/personal"])

        let workUSD = app.totals.day[SeriesKey(source: "claude/work", vendor: "claude", model: "claude-opus-4-7")]?.usd ?? 0
        let personalUSD = app.totals.day[SeriesKey(source: "claude/personal", vendor: "claude", model: "claude-opus-4-7")]?.usd ?? 0
        XCTAssertEqual(workUSD, 5.0, accuracy: 1e-6, "work source's 1M input tokens should price at $5")
        XCTAssertEqual(personalUSD, 10.0, accuracy: 1e-6, "personal source's 2M input tokens should price at $10")

        await app.stop()
    }

    /// A malformed sources.toml must never stop counting: it degrades to
    /// the single implicit source rooted at `projectsRoot`, surfaces via
    /// `lastError`, and the projects root it falls back to is still
    /// scanned normally.
    func test_appState_malformedSourcesConfig_degradesToFallback_countingContinues() async throws {
        let root = NSTemporaryDirectory() + "as-badsrc-\(UUID().uuidString)"
        let projects = root + "/projects/p1"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let line = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        try (line + "\n").write(toFile: projects + "/sess.jsonl", atomically: true, encoding: .utf8)

        let sourcesPath = root + "/sources.toml"
        // Unknown vendor -> Sources.load throws.
        try """
        [[source]]
        vendor = "openai"
        label = "x"
        root = "/tmp/x"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-badsrc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: root + "/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: root
        )
        await app.start()

        XCTAssertEqual(app.sources, [SourceEntry(vendor: "claude", label: "claude", root: root + "/projects")],
                       "a malformed sources.toml must degrade to the single implicit source")
        XCTAssertNotNil(app.lastError, "the malformed config must surface once via lastError")

        let usd = app.totals.day[SeriesKey(source: "claude/claude", vendor: "claude", model: "claude-opus-4-7")]?.usd ?? 0
        XCTAssertEqual(usd, 5.0, accuracy: 1e-6, "counting must continue against the fallback root")

        await app.stop()
    }

    /// A configured source whose root doesn't exist on disk contributes
    /// nothing and is NOT an error — the other, reachable source must
    /// still be scanned and must not itself trip `lastError`.
    func test_appState_missingConfiguredRoot_isNotAnError_otherSourceStillCounts() async throws {
        let base = NSTemporaryDirectory() + "as-missing-\(UUID().uuidString)"
        let realProjects = base + "/real/projects/p1"
        try FileManager.default.createDirectory(atPath: realProjects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        // "ghost"'s root is deliberately never created.

        let line = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        try (line + "\n").write(toFile: realProjects + "/sess.jsonl", atomically: true, encoding: .utf8)

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "claude"
        label = "real"
        root = "\(base)/real/projects"

        [[source]]
        vendor = "claude"
        label = "ghost"
        root = "\(base)/ghost/projects"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-missing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: base + "/real/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: base
        )
        await app.start()

        XCTAssertNil(app.lastError, "a merely-missing configured root must not be treated as an error")
        let usd = app.totals.day[SeriesKey(source: "claude/real", vendor: "claude", model: "claude-opus-4-7")]?.usd ?? 0
        XCTAssertEqual(usd, 5.0, accuracy: 1e-6, "the reachable source must still be scanned")

        await app.stop()
    }

    /// Exercises the LIVE watcher path with more than one configured
    /// source — `test_appState_twoSources_attributeIndependently` only
    /// covers the initial backfill (files existed before `start()`).
    /// `sourceForPath`'s prefix-match branch only runs once
    /// `sources.count > 1`, is brand new code, and is exactly where a
    /// `resolvingSymlinksInPath` mismatch (e.g. `/var` vs `/private/var`
    /// under `NSTemporaryDirectory()`) would silently misroute an event
    /// into `lastError` instead of `totals` — spend quietly lost, not
    /// just mis-attributed. Mirrors `test_appState_picksUpNewEventLive`
    /// but with two sources.
    func test_appState_twoSources_liveWatcherAttributesToCorrectSource() async throws {
        let base = NSTemporaryDirectory() + "as-multilive-\(UUID().uuidString)"
        let workProjects = base + "/work/projects/p1"
        let personalProjects = base + "/personal/projects/p1"
        try FileManager.default.createDirectory(atPath: workProjects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: personalProjects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "claude"
        label = "work"
        root = "\(base)/work/projects"

        [[source]]
        vendor = "claude"
        label = "personal"
        root = "\(base)/personal/projects"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-multilive-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let now: () -> Date = { Date() }
        let agg = Aggregator(pricing: .defaults, now: now)
        let app = AppState(
            projectsRoot: base + "/work/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            now: now,
            home: base
        )
        await app.start()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Drop a fresh JSONL line under the SECOND source's root, after
        // start() — not present during the initial backfill, so this
        // can only show up via the live watcher.
        let path = personalProjects + "/sess.jsonl"
        let line = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ISO8601DateFormatter().string(from: Date()))","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(5.0)
        var finalUSD: Double = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            let total = app.totals.day[SeriesKey(source: "claude/personal", vendor: "claude", model: "claude-opus-4-7")]?.usd ?? 0
            if total > 0 {
                finalUSD = total
                break
            }
        }

        await app.stop()
        XCTAssertEqual(finalUSD, 5.0, accuracy: 1e-6,
                       "the live watcher must attribute a personal-source event to claude/personal")
        XCTAssertNil(app.lastError, "sourceForPath must resolve the watched path to a configured source")
    }

    /// Editing a source's root in place (same vendor/label — what the
    /// GUI editor's folder picker does when a user repoints an existing
    /// row) must backfill the NEW root's history on the next reload.
    /// Without this, the stale reader from before the edit just starts
    /// watching the new root going forward and the user sees zero for
    /// that source until some future event arrives.
    func test_appState_reloadSources_rootChange_backfillsNewRoot() async throws {
        let base = NSTemporaryDirectory() + "as-rootchange-\(UUID().uuidString)"
        let oldRoot = base + "/old/projects/p1"
        let newRoot = base + "/new/projects/p1"
        try FileManager.default.createDirectory(atPath: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: newRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let ts = ISO8601DateFormatter().string(from: Date())
        let oldLine = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        let newLine = #"{"type":"assistant","message":{"id":"m2","model":"claude-opus-4-7","usage":{"input_tokens":3000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s2","cwd":"/tmp/y","requestId":"r2"}"#
        try (oldLine + "\n").write(toFile: oldRoot + "/sess.jsonl", atomically: true, encoding: .utf8)
        try (newLine + "\n").write(toFile: newRoot + "/sess.jsonl", atomically: true, encoding: .utf8)

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "claude"
        label = "work"
        root = "\(base)/old/projects"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-rootchange-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: base + "/old/projects",
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: base
        )
        await app.start()
        let key = SeriesKey(source: "claude/work", vendor: "claude", model: "claude-opus-4-7")
        XCTAssertEqual(app.totals.day[key]?.usd ?? 0, 5.0, accuracy: 1e-6,
                       "initial scan should see the old root's event")

        // Edit the source's root in place — same vendor/label (same
        // id), pointed at a different folder: exactly what the GUI
        // editor's folder picker does.
        try Sources.write([SourceEntry(vendor: "claude", label: "work", root: base + "/new/projects")], to: sourcesPath)
        await app.reloadSources()

        XCTAssertEqual(app.totals.day[key]?.usd ?? 0, 20.0, accuracy: 1e-6,
                       "reloadSources must backfill the new root ($15 more), not just start watching it going forward")

        await app.stop()
    }

    /// Regression for a cache-restore bug: seeding EVERY reader with the
    /// FULL merged offset map (instead of only the slice each reader's
    /// own source owns) leaves every non-owning reader holding a frozen,
    /// stale copy of another source's file offset. `mergedOffsets()`
    /// then has to pick between the true owner's advanced value and a
    /// stale one via `Dictionary`'s unspecified iteration order — and
    /// when it picks the stale one, the persisted cache records an
    /// offset BEHIND what was actually read, so the next launch
    /// re-scans and re-counts already-counted events: double-counted
    /// spend, exactly what the global constraints forbid.
    ///
    /// Drives this through a REAL two-phase start/stop/restart cycle
    /// (not a hand-built `CacheFile`) so the seeded offsets are in
    /// whatever path form the system actually produces — `walkDirLikeGo`
    /// and FSEvents both report paths through their OS-resolved form
    /// (e.g. `/private/var/...` under `NSTemporaryDirectory()`), and a
    /// synthetic cache built from the literal, unresolved path string
    /// would silently exercise a different (and unrepresentative)
    /// mismatch than the one this test is meant to catch.
    ///
    /// A third restart with no further changes proves the fix is
    /// durable, not just "happened to net out right once": if any path
    /// were still being lost or duplicated across readers, re-scanning
    /// from a stale offset would inflate one of the totals again.
    func test_appState_restartAfterCacheRestore_advancesOnlyTheChangedSourceOffset() async throws {
        let base = NSTemporaryDirectory() + "as-seed-\(UUID().uuidString)"
        let workProjects = base + "/work/projects/p1"
        let personalProjects = base + "/personal/projects/p1"
        try FileManager.default.createDirectory(atPath: workProjects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: personalProjects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let workPath = workProjects + "/sess.jsonl"
        let personalPath = personalProjects + "/sess.jsonl"
        let ts = ISO8601DateFormatter().string(from: Date())
        let firstLine = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}\#n"#
        try firstLine.write(toFile: workPath, atomically: true, encoding: .utf8)
        try firstLine.write(toFile: personalPath, atomically: true, encoding: .utf8)

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "claude"
        label = "work"
        root = "\(base)/work/projects"

        [[source]]
        vendor = "claude"
        label = "personal"
        root = "\(base)/personal/projects"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-seed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cacheStore = CacheStore(url: cacheURL)
        let key = SeriesKey(source: "claude/work", vendor: "claude", model: "claude-opus-4-7")

        func makeApp() -> AppState {
            AppState(
                projectsRoot: base + "/work/projects",
                aggregator: Aggregator(pricing: .defaults),
                reader: Reader(),
                cacheStore: cacheStore,
                pricing: .defaults,
                dockIcon: InMemoryDockIconController(),
                settingsStore: InMemorySettingsStore(),
                sourcesConfigPath: sourcesPath,
                home: base
            )
        }

        // Phase 1: fresh scan, no pre-existing cache. Both sources read
        // their one line ($5 each) and flush a real cache on stop().
        let app1 = makeApp()
        await app1.start()
        XCTAssertEqual(app1.totals.day[key]?.usd ?? 0, 5.0, accuracy: 1e-6)
        await app1.stop()

        // Append a SECOND line to the WORK file only — new content the
        // phase-1 cache doesn't know about. personal is untouched.
        let secondLine = #"{"type":"assistant","message":{"id":"m2","model":"claude-opus-4-7","usage":{"input_tokens":2000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"\#(ts)","sessionId":"s2","cwd":"/tmp/y","requestId":"r2"}\#n"#
        try (secondLine).appendTo(path: workPath)

        // Phase 2: a fresh AppState restores the real cache from phase
        // 1 (cells AND offsets), seeds each reader with only its own
        // source's offsets, and rescans. work must gain exactly the new
        // $10 (5 restored + 10 new = 15); personal must gain nothing
        // (already fully read, nothing new on disk).
        let app2 = makeApp()
        await app2.start()
        XCTAssertEqual(app2.totals.day[key]?.usd ?? 0, 15.0, accuracy: 1e-6,
                       "work must restore its $5 and add exactly the new line's $10 — not lose the restore, and not double the new line")
        await app2.stop()

        // Phase 3: restart again with NO further changes. If any
        // offset were lost or corrupted by cross-source seeding, this
        // would re-read and re-count something. Dedupe (perMsg) is a
        // second safety net, but the totals must not even need it here.
        let app3 = makeApp()
        await app3.start()
        XCTAssertEqual(app3.totals.day[key]?.usd ?? 0, 15.0,
                       accuracy: 1e-6, "a second restart with no new content must not change the total")
        await app3.stop()
    }

    /// Pins the invariant that makes `mergedOffsets()`'s plain
    /// last-wins merge safe, DIRECTLY rather than through the
    /// downstream double-counting symptom: after cache restore, every
    /// reader's offset dict must contain ONLY paths under its own
    /// source's root, and a cached path belonging to no configured
    /// source must be dropped rather than land in some reader anyway.
    ///
    /// A restart-cycle test (`test_appState_restartAfterCacheRestore_…`
    /// above) observes this only through whether a total comes out
    /// right, which depends on `mergedOffsets()`'s merge happening to
    /// pick the correct value out of an *unordered* `Dictionary` when
    /// two readers disagree about a path — a re-review transplanted an
    /// earlier version of that kind of test onto the pre-fix (broadcast
    /// seed) code and found it failed only 2 of 14 runs (~14%): most
    /// runs stayed green by accident. This test instead asserts the
    /// membership property itself, which has no dependence on
    /// iteration order and fails 100% of the time if the broadcast seed
    /// is ever reintroduced.
    ///
    /// Uses empty source roots (no `.jsonl` files) so `start()`'s
    /// subsequent scan phase finds nothing to read and can't mutate the
    /// seeded offsets before this test inspects them via
    /// `AppState.readerOffsetsByID()`.
    func test_appState_seedReaders_scopesEachOffsetToExactlyOneOwningReader() async throws {
        let base = NSTemporaryDirectory() + "as-invariant-\(UUID().uuidString)"
        let workRoot = base + "/work/projects"
        let personalRoot = base + "/personal/projects"
        try FileManager.default.createDirectory(atPath: workRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: personalRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let workPath = workRoot + "/p1/sess.jsonl"
        let personalPath = personalRoot + "/p1/sess.jsonl"
        // Under NEITHER configured root — simulates a source that was
        // removed from sources.toml since this offset was cached.
        let orphanPath = base + "/orphan/projects/p1/sess.jsonl"

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "claude"
        label = "work"
        root = "\(workRoot)"

        [[source]]
        vendor = "claude"
        label = "personal"
        root = "\(personalRoot)"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-invariant-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cacheStore = CacheStore(url: cacheURL)
        let seededCache = CacheFile(
            writtenAt: Date(),
            cells: [],
            perMsg: [],
            offsets: [workPath: 111, personalPath: 222, orphanPath: 333],
            parseErrors: 0,
            dupes: 0,
            unknownMsgs: []
        )
        try cacheStore.save(seededCache)

        let app = AppState(
            projectsRoot: workRoot,
            aggregator: Aggregator(pricing: .defaults),
            reader: Reader(),
            cacheStore: cacheStore,
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: base
        )
        await app.start()
        await app.stop()

        let bySource = await app.readerOffsetsByID()

        XCTAssertEqual(bySource["claude/work"], [workPath: 111],
                       "the work reader must hold exactly its own path, nothing more")
        XCTAssertEqual(bySource["claude/personal"], [personalPath: 222],
                       "the personal reader must hold exactly its own path, nothing more")

        let allSeededPaths = Set(bySource.values.flatMap { $0.keys })
        XCTAssertEqual(allSeededPaths, [workPath, personalPath],
                       "each mapped path must appear in exactly one reader — never duplicated across readers, never missing")
        XCTAssertFalse(bySource.values.contains { $0[orphanPath] != nil },
                       "a cached path matching no configured source must be dropped, not assigned to some reader anyway")
    }

    /// Pins final-review.md item 3: `sourceForPath`'s `sources.count ==
    /// 1` shortcut resolves ANY path to the lone source, no matter
    /// where it actually lives — a shortcut that's fine for the
    /// watcher (see `sourceForPath`'s doc comment) but wrong for
    /// `seedReaders`, which must drop an unmatched cached path exactly
    /// as the multi-source case does. With exactly ONE configured
    /// source, a cached path that lies OUTSIDE that source's root must
    /// still be dropped rather than seeded into its reader — seeding it
    /// anyway is the identical failure mode Task 10 fixed (an offset
    /// persisted behind what was read, re-triggering a re-read and, for
    /// events missing a `messageID`/`requestID`, a re-count).
    ///
    /// This must FAIL against the un-fixed shortcut: with only one
    /// source configured, `sourceForPath("...")` returns that source
    /// unconditionally, so `orphanPath` below would land in its reader
    /// instead of being dropped.
    func test_appState_seedReaders_singleSource_dropsPathOutsideRoot() async throws {
        let base = NSTemporaryDirectory() + "as-single-source-\(UUID().uuidString)"
        let workRoot = base + "/work/projects"
        try FileManager.default.createDirectory(atPath: workRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let workPath = workRoot + "/p1/sess.jsonl"
        // Under the ONE configured source's root — must be kept.
        // A path from a DIFFERENT, no-longer-configured root — must be
        // dropped, even though there's only one reader to (mis)assign
        // it to.
        let orphanPath = base + "/orphan/projects/p1/sess.jsonl"

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "claude"
        label = "work"
        root = "\(workRoot)"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-single-source-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cacheStore = CacheStore(url: cacheURL)
        let seededCache = CacheFile(
            writtenAt: Date(),
            cells: [],
            perMsg: [],
            offsets: [workPath: 111, orphanPath: 333],
            parseErrors: 0,
            dupes: 0,
            unknownMsgs: []
        )
        try cacheStore.save(seededCache)

        let app = AppState(
            projectsRoot: workRoot,
            aggregator: Aggregator(pricing: .defaults),
            reader: Reader(),
            cacheStore: cacheStore,
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: base
        )
        await app.start()
        await app.stop()

        let bySource = await app.readerOffsetsByID()

        XCTAssertEqual(bySource["claude/work"], [workPath: 111],
                       "the sole reader must hold only its own path — the orphan must not be seeded into it just because it's the only reader available")
    }

    // MARK: - Codex replay across a restart (Finding 1: double-count on relaunch)

    /// Reproduces the critical bug: a codex rollout file that keeps
    /// growing across an app relaunch. Session 1 (before "restart")
    /// writes session_meta + one token_count reading; that reading's
    /// delta (its own value, since it's the session's first) is what a
    /// prior run would have counted and cached, alongside the file's
    /// byte offset at that point.
    ///
    /// The cache is seeded directly (not produced by a real prior
    /// `start()`) so this test controls the exact offset/cell pairing
    /// that must reconcile — the whole point of the fix under test.
    /// Session "2" (after "restart") appends a SECOND token_count
    /// reading before the fresh `AppState` calls `start()`, which must
    /// seed readers, replay the already-counted bytes into a
    /// reconstructed `CodexParser`, and then read only the appended
    /// bytes during backfill.
    ///
    /// Without the fix, `seedReaders` hands the codex reader a bare
    /// offset with no parser: the fresh `CodexParser` created on first
    /// use treats the second reading as the session's "first" (no
    /// `havePrev`), so its delta is the ENTIRE cumulative total-so-far
    /// (1500/200/150 minus nothing) stacked on top of the cache's
    /// already-restored 1000/200/100 — a double count. It would also
    /// lose session_meta's `parent_thread_id` and `cwd` (both live only
    /// on line 1, behind the offset), so the doubled contribution lands
    /// under project `""` with the fallback model `gpt-5.6-sol` instead
    /// of the correct `-Users-me-src-proj` / `codex-auto-review` — this
    /// test's project/model/isSubagent assertions catch that even if a
    /// naive fix got the token math right by accident.
    func test_appState_codexReplay_acrossRestart_countsOnlyTheNewDelta() async throws {
        let dirName = "as-codex-replay-\(UUID().uuidString)"
        let rawBase = NSTemporaryDirectory() + dirName
        let rawCodexRoot = rawBase + "/codex/sessions/2026/08/16"
        try FileManager.default.createDirectory(atPath: rawCodexRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rawBase) }
        // NSTemporaryDirectory() is under /var, an APFS firmlink to
        // /private/var — NOT a plain symlink, so `resolvingSymlinksInPath`
        // (used by `AppState.matchSource`) is a no-op on it, but
        // `FileManager.contentsOfDirectory(at:)` (used by
        // `Reader.candidateFiles`'s real directory walk) canonicalizes
        // every entry it returns to /private/var/... regardless. Seeding
        // the cache's offset with the RAW /var/... form this test would
        // naturally build would make `matchSource`'s prefix check fail
        // against the canonical path the real scan reports for the same
        // file — an environment artifact, not the bug under test — and
        // masks Finding 1 behind an unrelated routing miss. Recovering
        // the canonical form via one real directory listing, up front,
        // keeps every path this test constructs consistent with what
        // `candidateFiles` will actually see.
        let base = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            includingPropertiesForKeys: nil, options: []
        ).first { $0.lastPathComponent == dirName }!.path
        let codexRoot = base + "/codex/sessions/2026/08/16"

        let rolloutPath = codexRoot + "/rollout-replay.jsonl"

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date()
        let t0 = iso.string(from: now.addingTimeInterval(-120))
        let t1 = iso.string(from: now.addingTimeInterval(-60))
        let t2 = iso.string(from: now)

        // Session 1: session_meta (parent_thread_id present -> subagent,
        // no thread_settings_applied ever declared -> fallback model
        // "codex-auto-review") + one token_count reading. This is what a
        // prior run would have read and counted.
        let sessionMeta = #"{"timestamp":"\#(t0)","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/proj","parent_thread_id":"parent-1"}}"#
        let reading1 = #"{"timestamp":"\#(t1)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":100,"total_tokens":1100}}}}"#
        let partA = sessionMeta + "\n" + reading1 + "\n"
        try partA.write(toFile: rolloutPath, atomically: true, encoding: .utf8)
        let offsetAfterPartA = Int64(Data(partA.utf8).count)

        let sourcesPath = base + "/sources.toml"
        try """
        [[source]]
        vendor = "codex"
        label = "codex"
        root = "\(base)/codex/sessions"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let today = civilDayString(dayOf(now))
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-codex-replay-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        let cacheStore = CacheStore(url: cacheURL)
        let seededCache = CacheFile(
            writtenAt: now,
            cells: [
                CacheFile.CellEntry(
                    day: today, project: "-Users-me-src-proj", source: "codex/codex",
                    vendor: "codex", model: "codex-auto-review", isSub: true,
                    input: 800, output: 100, cacheCreate: 0, cacheRead: 200
                )
            ],
            perMsg: [],
            offsets: [rolloutPath: offsetAfterPartA],
            parseErrors: 0,
            dupes: 0,
            unknownMsgs: []
        )
        try cacheStore.save(seededCache)

        // "Restart": the session continues and appends a second reading
        // BEFORE the new AppState instance ever calls start().
        let reading2 = #"{"timestamp":"\#(t2)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":200,"output_tokens":150,"total_tokens":1650}}}}"#
        let handle = FileHandle(forWritingAtPath: rolloutPath)!
        handle.seekToEndOfFile()
        handle.write((reading2 + "\n").data(using: .utf8)!)
        try handle.close()

        let app = AppState(
            projectsRoot: base + "/unused-claude-root",
            aggregator: Aggregator(pricing: .defaults),
            reader: Reader(),
            cacheStore: cacheStore,
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: base
        )
        await app.start()
        await app.stop()

        // Correct: the cache's 1000/200/100 baseline plus reading 2's OWN
        // delta (500/0/50, i.e. (1500-1000)/(200-200)/(150-100)) — never
        // the cache's baseline plus reading 2's entire cumulative total.
        let pd = app.totals.monthProj["-Users-me-src-proj"]
        XCTAssertNotNil(pd, "project attribution lost — session_meta's cwd must survive the restart via replay")
        XCTAssertEqual(pd?.sub.input, 1300, "expected 800 (cached) + 500 (reading 2's own delta), not a doubled cumulative")
        XCTAssertEqual(pd?.sub.output, 150, "expected 100 (cached) + 50 (reading 2's own delta)")
        XCTAssertEqual(pd?.sub.cacheRead, 200, "expected 200 (cached) + 0 (reading 2's own delta)")
        XCTAssertEqual(pd?.main.input, 0, "parent_thread_id must still mark this a subagent turn after replay — a lost hasParent would misfile the new delta under main")

        let seriesKey = SeriesKey(source: "codex/codex", vendor: "codex", model: "codex-auto-review")
        XCTAssertEqual(app.totals.month[seriesKey]?.tokens.input, 1300,
                       "model must still resolve to codex-auto-review (parent_thread_id fallback) after replay, not the no-parent fallback gpt-5.6-sol")
    }

    // MARK: - Home-based vendor discovery (resolveSources)

    /// The shipped bug this branch fixes: `resolveSources`'s missing-file
    /// branch returned a hardcoded Claude-only fallback instead of
    /// `Sources.defaultsWithClaudeRoot`, so a user with no
    /// `sources.toml` (the default state for every install) never got
    /// Grok auto-discovered in the menu-bar app, even though the Go TUI
    /// discovers it via `sources.Defaults` on the same corpus. `home` is
    /// a temp dir distinct from `projectsRoot`, so this proves BOTH
    /// halves at once: the Claude entry stays at the INJECTED
    /// `projectsRoot` (not `home/.claude/projects`), and `grok` is
    /// discovered under the INJECTED `home` (not the real machine's).
    func test_appState_noSourcesToml_discoversGrokUnderHome_claudeStaysAtInjectedRoot() async throws {
        let root = NSTemporaryDirectory() + "as-homedisc-\(UUID().uuidString)"
        let projects = root + "/projects"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let home = NSTemporaryDirectory() + "as-home-\(UUID().uuidString)"
        let grokSessions = home + "/.grok/sessions"
        try FileManager.default.createDirectory(atPath: grokSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-homedisc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: projects,
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            // No sources.toml at this path — exercises the missing-file branch.
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            home: home
        )
        await app.start()

        XCTAssertEqual(app.sources.first, SourceEntry(vendor: "claude", label: "claude", root: projects),
                       "the Claude entry must stay at the injected projectsRoot, not home/.claude/projects")
        XCTAssertTrue(app.sources.contains { $0.vendor == "grok" && $0.root == grokSessions },
                      "grok must be auto-discovered under the injected home when its sessions dir exists")

        await app.stop()
    }

    /// Mandatory per Task 5: proves Codex discovery reaches `AppState`,
    /// not just `Sources.defaults` in isolation. Phase B shipped Grok
    /// dead in the macapp because `Sources.defaults` was unit-tested on
    /// its own while nothing asserted `AppState.start()` actually reached
    /// it — `eef9e14` fixed that path (see the Grok test above); this is
    /// the same assertion for a third vendor, constructed the same way:
    /// no `sources.toml` at all, and a temp `home` containing
    /// `.codex/sessions`.
    func test_appState_discoversCodexWithNoSourcesToml() async throws {
        let root = NSTemporaryDirectory() + "as-codexdisc-\(UUID().uuidString)"
        let projects = root + "/projects"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let home = NSTemporaryDirectory() + "as-home-codex-\(UUID().uuidString)"
        let codexSessions = home + "/.codex/sessions"
        try FileManager.default.createDirectory(atPath: codexSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-codexdisc-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: projects,
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            // No sources.toml at this path — exercises the missing-file branch.
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-codex-\(UUID().uuidString).toml",
            home: home
        )
        await app.start()

        XCTAssertTrue(app.sources.contains { $0.vendor == "codex" && $0.root == codexSessions },
                      "codex must be auto-discovered under the injected home when its sessions dir exists")

        await app.stop()
    }

    /// The malformed-config `catch` branch had the identical defect —
    /// it also returned the bare Claude-only fallback instead of
    /// `defaultsWithClaudeRoot`. Discovery must survive that path too,
    /// alongside the (unrelated, already-correct) `lastError` surfacing.
    func test_appState_malformedSourcesToml_stillDiscoversGrokUnderHome_setsLastError() async throws {
        let root = NSTemporaryDirectory() + "as-homedisc-bad-\(UUID().uuidString)"
        let projects = root + "/projects"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let home = NSTemporaryDirectory() + "as-home-bad-\(UUID().uuidString)"
        let grokSessions = home + "/.grok/sessions"
        try FileManager.default.createDirectory(atPath: grokSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let sourcesPath = root + "/sources.toml"
        // Unknown vendor -> Sources.load throws (the malformed-config branch).
        try """
        [[source]]
        vendor = "openai"
        label = "x"
        root = "/tmp/x"
        """.write(toFile: sourcesPath, atomically: true, encoding: .utf8)

        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-homedisc-bad-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let agg = Aggregator(pricing: .defaults)
        let app = AppState(
            projectsRoot: projects,
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: .defaults,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: sourcesPath,
            home: home
        )
        await app.start()

        XCTAssertEqual(app.sources.first, SourceEntry(vendor: "claude", label: "claude", root: projects),
                       "the Claude entry must stay at the injected projectsRoot even on the malformed-config path")
        XCTAssertTrue(app.sources.contains { $0.vendor == "grok" && $0.root == grokSessions },
                      "grok must still be discovered under home when sources.toml is malformed")
        XCTAssertNotNil(app.lastError, "a malformed sources.toml must still surface via lastError")

        await app.stop()
    }

    // MARK: - refreshPricingIfStale (Swift mirror of Go's loadPricing
    // stale-cache branch)

    /// `pricingOverrideURL` is always a fresh temp path — see the guard
    /// at the top of this file for why a real one must never leak in
    /// here.
    private func makeMinimalAppState(pricing: PricingTable, pricingOverrideURL: URL) -> AppState {
        let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ascache-stale-\(UUID().uuidString).json")
        return AppState(
            projectsRoot: NSTemporaryDirectory() + "as-stale-\(UUID().uuidString)",
            aggregator: Aggregator(pricing: pricing),
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: pricing,
            dockIcon: InMemoryDockIconController(),
            settingsStore: InMemorySettingsStore(),
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml",
            pricingOverrideURL: pricingOverrideURL
        )
    }

    // A table already at the current schema must not trigger a network
    // fetch — this is the "cache hit" path, exercised on every ordinary
    // launch.
    func test_refreshPricingIfStale_currentSchema_doesNotFetch() async {
        let current = PricingTable(models: ["claude-opus-4-7": ModelPrice(
            inputPerMTok: 5, outputPerMTok: 25, cacheCreationPerMTok: 6.25, cacheReadPerMTok: 0.5)],
            schema: PricingTable.currentSchema)
        let overrideURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aspricing-current-\(UUID().uuidString).toml")
        let app = makeMinimalAppState(pricing: current, pricingOverrideURL: overrideURL)
        let mock = CountingMockSession(data: Data(), response:
            HTTPURLResponse(url: PricingFetcher.liteLLMURL, statusCode: 200,
                            httpVersion: "HTTP/1.1", headerFields: nil)!)
        await app.refreshPricingIfStale(session: mock)
        let calls = await mock.callCount
        XCTAssertEqual(calls, 0, "an up-to-date schema must never trigger a refetch")
        XCTAssertEqual(app.pricing, current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideURL.path),
                       "no refetch means nothing should have been written at all")
    }

    // A table below the current schema (including PricingTable.defaults,
    // schema 0) is a complete, valid table just missing an entire
    // provider's worth of models — refetch once and adopt the fresh
    // result on success.
    func test_refreshPricingIfStale_staleSchema_fetchesAndAdoptsFreshTable() async throws {
        let stale = PricingTable(models: ["claude-opus-4-7": ModelPrice(
            inputPerMTok: 5, outputPerMTok: 25, cacheCreationPerMTok: 6.25, cacheReadPerMTok: 0.5)],
            schema: 0)
        let overrideURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aspricing-stale-\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: overrideURL) }
        let app = makeMinimalAppState(pricing: stale, pricingOverrideURL: overrideURL)
        let freshJSON = """
        {
          "gpt-5.6-luna": {
            "litellm_provider": "openai",
            "input_cost_per_token": 0.0000002,
            "output_cost_per_token": 0.0000012
          }
        }
        """
        let mock = CountingMockSession(data: Data(freshJSON.utf8), response:
            HTTPURLResponse(url: PricingFetcher.liteLLMURL, statusCode: 200,
                            httpVersion: "HTTP/1.1", headerFields: nil)!)
        await app.refreshPricingIfStale(session: mock)
        let calls = await mock.callCount
        XCTAssertEqual(calls, 1, "a stale schema must trigger exactly one refetch")
        XCTAssertTrue(app.pricing.has(model: "gpt-5.6-luna"), "the fresh table must be adopted")
        XCTAssertFalse(app.pricing.has(model: "claude-opus-4-7"), "the stale table must not survive a successful refetch")

        // The write must land at the INJECTED temp URL, never the real
        // app-override path (that's the whole point of this fix).
        XCTAssertTrue(FileManager.default.fileExists(atPath: overrideURL.path),
                     "a successful refetch must persist the fresh table to the injected override URL")
        let written = TOMLPricing.decode(try String(contentsOf: overrideURL, encoding: .utf8))
        XCTAssertTrue(written.has(model: "gpt-5.6-luna"), "the persisted file must contain the fresh table")
        XCTAssertEqual(written.schema, PricingTable.currentSchema,
                       "the persisted file must stamp the current schema, or this refetch-once-per-stale-cache guard never re-fires correctly")
    }

    // On refetch failure (offline), the stale table already loaded must be
    // kept rather than dropping to baked-in defaults — a network hiccup
    // must never change Claude dollars as a side effect of a Codex/OpenAI
    // pricing change.
    func test_refreshPricingIfStale_refetchFails_keepsStaleTable() async {
        let stale = PricingTable(models: ["claude-opus-4-7": ModelPrice(
            inputPerMTok: 5, outputPerMTok: 25, cacheCreationPerMTok: 6.25, cacheReadPerMTok: 0.5)],
            schema: 0)
        let overrideURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aspricing-failed-\(UUID().uuidString).toml")
        let app = makeMinimalAppState(pricing: stale, pricingOverrideURL: overrideURL)
        let mock = CountingMockSession(data: Data(), response:
            HTTPURLResponse(url: PricingFetcher.liteLLMURL, statusCode: 503,
                            httpVersion: "HTTP/1.1", headerFields: nil)!)
        await app.refreshPricingIfStale(session: mock)
        XCTAssertEqual(app.pricing, stale, "a failed refetch must leave the stale table in place, not drop to defaults")
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideURL.path),
                       "a failed refetch must never write anything, at the injected URL or otherwise")
    }
}

private actor CountingMockSession: URLSessionProtocol {
    private(set) var callCount = 0
    let data: Data
    let response: URLResponse
    init(data: Data, response: URLResponse) {
        self.data = data
        self.response = response
    }
    func dataReturning(from url: URL) async throws -> (Data, URLResponse) {
        callCount += 1
        return (data, response)
    }
}

private extension String {
    func appendTo(path: String) throws {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            try self.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.utf8))
    }
}
