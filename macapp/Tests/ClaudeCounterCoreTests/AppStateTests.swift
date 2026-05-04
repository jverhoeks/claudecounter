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
