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

    // resets_at in the fixture is far future (Unix 4102444800); evaluate
    // as if `now` is later, so the window has actually closed.
    func test_scanCodex_marksExpiredWindowStale() throws {
        let src = try fixtureURL("codex_old_layout.jsonl")
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)/2026/08/07")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dst = root.appendingPathComponent("rollout-a.jsonl")
        try FileManager.default.copyItem(at: src, to: dst)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let future = Date(timeIntervalSince1970: 4102444800).addingTimeInterval(3600)
        // Pin the fixture's mtime to the same timeline as `future` — the
        // age-bounded walk and the staleness check must share one clock,
        // or the copied (2026-dated) file falls outside the cutoff and
        // is silently excluded before staleness is ever evaluated.
        try FileManager.default.setAttributes([.modificationDate: future.addingTimeInterval(-3600)],
                                              ofItemAtPath: dst.path)

        let gs = PlanLimits.scanCodex(root: root.deletingLastPathComponent().deletingLastPathComponent().path,
                                      now: future)
        XCTAssertEqual(gs.count, 2)
        XCTAssertTrue(gs.allSatisfy(\.stale))
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
