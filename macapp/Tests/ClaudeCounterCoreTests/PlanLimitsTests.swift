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

    // A single invalid-UTF-8 byte sequence anywhere in a file must only
    // drop the one line it's on, never the whole file — otherwise a
    // corrupt byte in an old line could hide the newest observation in
    // an otherwise-readable file, silently violating "always the freshest
    // observation by event timestamp."
    func test_scanCodex_skipsInvalidUTF8LineKeepsNewerObservation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-\(UUID().uuidString)/2026/08/07")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let before = #"{"timestamp":"2026-08-07T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":50.0,"window_minutes":300,"resets_at":4102444800},"secondary":null}}}"#
        let after = #"{"timestamp":"2026-08-07T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","plan_type":"plus","primary":{"used_percent":99.0,"window_minutes":300,"resets_at":4102444800},"secondary":null}}}"#
        var body = Data()
        body.append(before.data(using: .utf8)!)
        body.append(0x0A)
        body.append(contentsOf: [0xFF, 0xFE]) // invalid UTF-8, undecodable as its own line
        body.append(0x0A)
        body.append(after.data(using: .utf8)!)
        body.append(0x0A)

        let dst = root.appendingPathComponent("rollout-invalid.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: dst.path, contents: body))
        let now = date("2026-08-07T13:00:00Z")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)],
                                              ofItemAtPath: dst.path)

        let gs = PlanLimits.scanCodex(root: root.deletingLastPathComponent().deletingLastPathComponent().path,
                                      now: now)
        XCTAssertEqual(gs.count, 1)
        XCTAssertEqual(gs.first?.pct, 99,
                       "the corrupt line must be skipped, not the whole file, so the newer line after it is still read")
    }

    // Same contract for Grok: an invalid-UTF-8 line must not hide a
    // newer billing line that follows it in the same file.
    func test_scanGrok_skipsInvalidUTF8LineKeepsNewerObservation() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let before = #"{"ts":"2026-08-07T10:00:00.000Z","src":"shell","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":9.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-31T20:00:10.825033+00:00","end":"2026-08-07T20:00:10.825033+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0}},"subscriptionTier":"SuperGrok"}}"#
        let after = #"{"ts":"2026-08-07T12:00:00.000Z","src":"shell","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":14.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-07-31T20:00:10.825033+00:00","end":"2026-08-07T20:00:10.825033+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0}},"subscriptionTier":"SuperGrok"}}"#
        var body = Data()
        body.append(before.data(using: .utf8)!)
        body.append(0x0A)
        body.append(contentsOf: [0xFF, 0xFE]) // invalid UTF-8, undecodable as its own line
        body.append(0x0A)
        body.append(after.data(using: .utf8)!)
        body.append(0x0A)

        let dst = root.appendingPathComponent("unified.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: dst.path, contents: body))

        let gs = PlanLimits.scanGrok(path: dst.path, now: date("2026-08-07T19:00:00Z"))
        XCTAssertEqual(gs.count, 1)
        XCTAssertEqual(gs.first?.pct, 14,
                       "the corrupt line must be skipped, not the whole file, so the newer line after it is still read")
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
