import XCTest
@testable import ClaudeCounterCore

final class HintsTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!

    private func sample(_ i: Int, model: String = "claude-opus-5-5", t: Date, context: UInt64, read: UInt64,
                        write1h: UInt64 = 0, sub: Bool = false, effort: String? = "medium", output: UInt64 = 300,
                        session: String = "s1", rebuild: CacheRebuild = .none) -> RequestSample {
        RequestSample(requestID: "r\(i)", time: t, model: model, isSubagent: sub, effort: effort,
                      firstBlock: 2, duration: 5, output: output, context: context, cacheRead: read,
                      thinkingTokens: nil, toolCalls: 0, toolErrors: ToolErrorCounts(), interrupted: false,
                      rebuild: rebuild, input: 0, cacheWrite: context - read, cacheWrite1h: write1h, session: session)
    }

    /// One main session growing `step` tokens per turn from 100k, a turn a minute.
    private func growingSession(step: Int = 4_000) -> [RequestSample] {
        (0..<100).map { i in
            let ctx = UInt64(100_000 + i * step)
            return sample(i, t: now.addingTimeInterval(Double(i - 100) * 60), context: ctx,
                          read: ctx - UInt64(step), write1h: UInt64(step))
        }
    }

    func test_compact_firesForBigContextsAndKnowsWhenApplied() throws {
        let s = growingSession()
        let h = try XCTUnwrap(Hints.build(s, pricing: .defaults, settings: .init(), days: 7, now: now).first { $0.id == .compact })
        XCTAssertGreaterThan(h.savingUSD, 0)
        XCTAssertNil(h.applied)
        XCTAssertEqual(h.snippet, "\"autoCompactWindow\": 200000")
        let applied = Hints.build(s, pricing: .defaults, settings: .init(autoCompactWindow: 200_000), days: 7, now: now)
        XCTAssertNotNil(applied.first { $0.id == .compact }?.applied)
    }

    func test_cacheTTL_onlyWhenPausesDontNeedTheHour() {
        // Back-to-back turns: every 1h write was read within 5 minutes. Big
        // enough writes that the waste clears the $2 noise floor.
        let quick = growingSession(step: 20_000)
        XCTAssertNotNil(Hints.build(quick, pricing: .defaults, settings: .init(), days: 7, now: now).first { $0.id == .cacheTTL })
        // Same session with 20-minute pauses: the 1h cache saves full rewrites, so no hint.
        let paused = quick.enumerated().map { i, x -> RequestSample in
            var y = x; y.time = now.addingTimeInterval(Double(i - 100) * 1200); return y
        }
        XCTAssertNil(Hints.build(paused, pricing: .defaults, settings: .init(), days: 7, now: now).first { $0.id == .cacheTTL })
    }

    func test_subagentModel_pricesTheSwitchToSonnet() throws {
        let subs = (0..<50).map { sample($0, t: now.addingTimeInterval(-3600), context: 2_000_000, read: 1_900_000,
                                        sub: true, session: "sub\($0)") }
        let h = try XCTUnwrap(Hints.build(subs, pricing: .defaults, settings: .init(), days: 7, now: now).first { $0.id == .subagentModel })
        let spend = subs.reduce(0) { $0 + $1.cost(.defaults) }
        XCTAssertGreaterThan(h.savingUSD, 0)
        XCTAssertLessThan(h.savingUSD, spend)
        let applied = Hints.build(subs, pricing: .defaults, settings: .init(subagentModel: "claude-sonnet-5"), days: 7, now: now)
        XCTAssertNotNil(applied.first { $0.id == .subagentModel }?.applied)
    }

    func test_oldSamplesAreOutsideThePeriod() {
        let old = growingSession().map { x -> RequestSample in var y = x; y.time = x.time.addingTimeInterval(-30 * 86400); return y }
        XCTAssertTrue(Hints.build(old, pricing: .defaults, settings: .init(), days: 7, now: now).isEmpty)
    }

    func test_settingsSnapshot_readsTheKeysHintsCheck() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"""
        {"autoCompactWindow": 200000, "promptCacheTtl": "5m", "model": "claude-opus-5-5", "effortLevel": "high",
         "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "claude-sonnet-5"},
         "modelSettings": {"claude-opus-5": {"effortLevel": "xhigh"}}}
        """#.write(to: url, atomically: true, encoding: .utf8)
        let c = ClaudeSettingsSnapshot.load(path: url.path)
        XCTAssertEqual(c.autoCompactWindow, 200_000)
        XCTAssertEqual(c.promptCacheTtl, "5m")
        XCTAssertEqual(c.subagentModel, "claude-sonnet-5")
        XCTAssertEqual(c.effort(for: "claude-opus-5"), "xhigh")
        XCTAssertEqual(c.effort(for: "claude-opus-5-5"), "high")
        XCTAssertEqual(ClaudeSettingsSnapshot.load(path: "/nonexistent/settings.json"), ClaudeSettingsSnapshot())
    }
}
