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
            let total = app.totals.day["claude-opus-4-7"]?.usd ?? 0
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
            settingsStore: InMemorySettingsStore()
        )
        await app.start()
        XCTAssertGreaterThan(app.totals.day["claude-opus-4-7"]?.usd ?? 0, 0)

        await app.refresh()
        XCTAssertGreaterThan(app.totals.day["claude-opus-4-7"]?.usd ?? 0, 0,
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
            settingsStore: InMemorySettingsStore()
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
            settingsStore: InMemorySettingsStore()
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
            settingsStore: InMemorySettingsStore()
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
            settingsStore: store
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
            settingsStore: store
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
            settingsStore: store
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
}
