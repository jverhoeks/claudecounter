import XCTest
@testable import ClaudeCounterCore

@MainActor
final class AppStateTests: XCTestCase {

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
            now: now
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
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml"
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
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml"
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
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml"
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
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml"
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
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml"
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
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml"
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
            sourcesConfigPath: NSTemporaryDirectory() + "as-nosrc-\(UUID().uuidString).toml"
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
            sourcesConfigPath: sourcesPath
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
            sourcesConfigPath: sourcesPath
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
            sourcesConfigPath: sourcesPath
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
            now: now
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
            sourcesConfigPath: sourcesPath
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
}
