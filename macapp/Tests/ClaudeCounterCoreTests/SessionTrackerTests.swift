import XCTest
@testable import ClaudeCounterCore

final class SessionTrackerTests: XCTestCase {

    // A fixed "now" so active-window / prune math is deterministic.
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 1; c.hour = 12
        return Calendar.current.date(from: c)!
    }()

    private func ev(session: String = "s1",
                    model: String = "claude-opus-4-8",
                    input: UInt64 = 0, output: UInt64 = 0,
                    cacheCreate: UInt64 = 0, cacheRead: UInt64 = 0,
                    project: String = "-Users-me-src-proj",
                    ts: Date, sub: Bool = false,
                    costUSD: Double = 0, costed: Bool = false,
                    coverageOnly: Bool = false, hasUsage: Bool = false) -> UsageEvent {
        UsageEvent(
            timestamp: ts, sessionID: session, cwd: "/tmp/x",
            project: project, model: model,
            messageID: "", requestID: "", isSubagent: sub,
            usage: Usage(input: input, output: output,
                         cacheCreate: cacheCreate, cacheRead: cacheRead),
            costUSD: costUSD, costed: costed,
            coverageOnly: coverageOnly, hasUsage: hasUsage
        )
    }

    private func onlySession(_ stats: [SessionStat]) -> SessionStat {
        XCTAssertEqual(stats.count, 1)
        return stats[0]
    }

    // MARK: - turn counting & cost

    func test_turns_countMainOnly_costIncludesSub() async {
        let t = SessionTracker(pricing: .defaults)
        // 2 main + 1 subagent turn, all opus, all with 1M input tokens.
        await t.apply(ev(input: 1_000_000, ts: Self.now.addingTimeInterval(-30)))
        await t.apply(ev(input: 1_000_000, ts: Self.now.addingTimeInterval(-20)))
        await t.apply(ev(input: 1_000_000, ts: Self.now.addingTimeInterval(-10), sub: true))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.turns, 2, "age-in-turns counts main turns only")
        // 3 turns × 1M input × $5/Mtok = $15 (subagent cost rolls up).
        XCTAssertEqual(s.costUSD, 15.0, accuracy: 1e-9)
    }

    // MARK: - context = latest MAIN turn by timestamp

    func test_context_isLatestMainTurn_byTimestampNotApplyOrder() async {
        let t = SessionTracker(pricing: .defaults)
        // Apply the LATER (small ctx) turn first, then an EARLIER (big ctx)
        // turn — mirroring the Reader applying subagent-first / out of order.
        await t.apply(ev(input: 50_000, ts: Self.now.addingTimeInterval(-5)))
        await t.apply(ev(input: 100_000, ts: Self.now.addingTimeInterval(-60)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.contextTokens, 50_000, "latest-by-timestamp turn wins, not last applied")
    }

    func test_context_excludesSubagentTurns() async {
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(input: 50_000, ts: Self.now.addingTimeInterval(-30)))
        // A later subagent turn with a huge context must NOT define the gauge.
        await t.apply(ev(input: 900_000, ts: Self.now.addingTimeInterval(-5), sub: true))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.contextTokens, 50_000)
        XCTAssertEqual(s.contextWindow, 200_000, "peak from main turns stays under 200k")
    }

    func test_context_countsInputPlusCacheReadPlusCacheCreate() async {
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(input: 10_000, cacheCreate: 20_000, cacheRead: 30_000,
                         ts: Self.now.addingTimeInterval(-10)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.contextTokens, 60_000)
    }

    // MARK: - last-5-minute cost

    func test_cost5m_excludesTurnsOlderThan5Minutes() async {
        let t = SessionTracker(pricing: .defaults)
        // 10 minutes ago (out of window) then 1 minute ago (in window).
        await t.apply(ev(input: 1_000_000, ts: Self.now.addingTimeInterval(-600)))
        await t.apply(ev(input: 1_000_000, ts: Self.now.addingTimeInterval(-60)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.cost5mUSD, 5.0, accuracy: 1e-9, "only the recent turn counts")
        XCTAssertEqual(s.costUSD, 10.0, accuracy: 1e-9, "total still counts both")
    }

    // MARK: - cache-creation cost

    func test_cacheCreateCost_isCreationComponentOnly() async {
        let t = SessionTracker(pricing: .defaults)
        // opus cacheCreation = $6.25 / Mtok; input should NOT be included here.
        await t.apply(ev(input: 1_000_000, cacheCreate: 2_000_000,
                         ts: Self.now.addingTimeInterval(-10)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.cacheCreateCostUSD, 12.5, accuracy: 1e-9)
    }

    // MARK: - window inference & pct clamp

    func test_inferredWindow_bumpsTo1MAbove200k() {
        XCTAssertEqual(inferredContextWindow(peakContextTokens: 200_000), 200_000)
        XCTAssertEqual(inferredContextWindow(peakContextTokens: 200_001), 1_000_000)
    }

    func test_contextPct_clampedAtOne() async {
        let t = SessionTracker(pricing: .defaults)
        // Peak > 200k → 1M window; latest ctx 1.5M → pct clamps to 1.0.
        await t.apply(ev(input: 1_500_000, ts: Self.now.addingTimeInterval(-10)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.contextWindow, 1_000_000)
        XCTAssertEqual(s.contextPct, 1.0, accuracy: 1e-9)
    }

    // MARK: - active filter & prune

    func test_activeFilter_excludesIdleBeyondWindow() async {
        let th = SessionThresholds(activeWindow: 15 * 60)
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(input: 1, ts: Self.now.addingTimeInterval(-20 * 60))) // 20m idle
        let stats = await t.snapshot(now: Self.now, thresholds: th) // explicit 15m window
        XCTAssertTrue(stats.isEmpty)
    }

    func test_activeFilter_includesWithinWindow() async {
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(input: 1, ts: Self.now.addingTimeInterval(-5 * 60)))
        let stats = await t.snapshot(now: Self.now, thresholds: .defaults)
        XCTAssertEqual(stats.count, 1)
    }

    func test_multipleSessions_sortedByRecentCost() async {
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(session: "cold", input: 100_000, ts: Self.now.addingTimeInterval(-60)))
        await t.apply(ev(session: "hot", input: 1_000_000, ts: Self.now.addingTimeInterval(-30)))
        let stats = await t.snapshot(now: Self.now, thresholds: .defaults)
        XCTAssertEqual(stats.map { $0.sessionID }, ["hot", "cold"])
    }

    // MARK: - warning thresholds (strictly-greater boundaries)

    func test_turnWarning_firesStrictlyAboveThreshold() async {
        let th = SessionThresholds(turnWarnCount: 2)
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(input: 1, ts: Self.now.addingTimeInterval(-30)))
        await t.apply(ev(input: 1, ts: Self.now.addingTimeInterval(-20)))
        var s = onlySession(await t.snapshot(now: Self.now, thresholds: th))
        XCTAssertFalse(s.warnings.contains(.turns), "== threshold does not warn")
        await t.apply(ev(input: 1, ts: Self.now.addingTimeInterval(-10)))
        s = onlySession(await t.snapshot(now: Self.now, thresholds: th))
        XCTAssertTrue(s.warnings.contains(.turns), "> threshold warns")
    }

    func test_contextWarning_firesStrictlyAbovePct() async {
        let th = SessionThresholds(contextWarnPct: 0.80)
        let t = SessionTracker(pricing: .defaults)
        // 160k / 200k = 0.80 exactly → no warn.
        await t.apply(ev(input: 160_000, ts: Self.now.addingTimeInterval(-10)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: th))
        XCTAssertFalse(s.warnings.contains(.context))
    }

    func test_cacheWarning_firesOnRecentRate() async {
        let th = SessionThresholds(cacheWarnUSD: 2.00)
        let t = SessionTracker(pricing: .defaults)
        // 1M opus cacheCreate = $6.25 within the last 5 min → $6.25/5m > $2.
        await t.apply(ev(cacheCreate: 1_000_000, ts: Self.now.addingTimeInterval(-10)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: th))
        XCTAssertEqual(s.cacheCreate5mUSD, 6.25, accuracy: 1e-9)
        XCTAssertTrue(s.warnings.contains(.cache))
    }

    func test_cacheWarning_doesNotFireOnStaleCreation() async {
        let th = SessionThresholds(cacheWarnUSD: 2.00)
        let t = SessionTracker(pricing: .defaults)
        // Big cache creation 10 min ago (out of the 5m rate window), plus a
        // cheap recent turn to keep the session active. Cumulative cost is
        // high, but the RATE is ~0 → no cache warning, no permanent red.
        await t.apply(ev(cacheCreate: 1_000_000, ts: Self.now.addingTimeInterval(-600)))
        await t.apply(ev(input: 1_000, ts: Self.now.addingTimeInterval(-30)))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: th))
        XCTAssertGreaterThan(s.cacheCreateCostUSD, 2.0, "cumulative total is still high")
        XCTAssertEqual(s.cacheCreate5mUSD, 0.0, accuracy: 1e-9)
        XCTAssertFalse(s.warnings.contains(.cache), "rate-based warning stays clear once thrash stops")
    }

    // MARK: - costed events (Grok) — use costUSD as given, never re-priced

    func test_costedEvent_usesCostUSDNotPricingTable() async {
        let t = SessionTracker(pricing: .defaults)
        // "grok-4.6-build" has no entry in the pricing table; a non-costed
        // event with this model would price to $0.
        await t.apply(ev(model: "grok-4.6-build", input: 52_295, output: 5_833,
                         ts: Self.now.addingTimeInterval(-10),
                         costUSD: 0.3721028, costed: true))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.costUSD, 0.3721028, accuracy: 1e-9)
    }

    func test_costedEvent_cacheCreateCostIsZero_notTablePriced() async {
        let t = SessionTracker(pricing: .defaults)
        // Deliberately a model that IS in the pricing table (opus): if
        // the costed guard were missing, `cacheCreate` would silently get
        // priced through it (opus cacheCreate = $6.25/Mtok → $12.50 here)
        // even though the event's own dollar figure is authoritative and
        // has no such breakdown to draw on. Grok never collides with a
        // real Claude model name, but the guard must not depend on that.
        await t.apply(ev(model: "claude-opus-4-8", cacheCreate: 2_000_000,
                         ts: Self.now.addingTimeInterval(-10),
                         costUSD: 1.0, costed: true))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.cacheCreateCostUSD, 0, "a costed event has no cache-creation breakdown")
    }

    // MARK: - coverageOnly events are bookkeeping, not a turn

    func test_coverageOnlyEvent_doesNotCreateASession() async {
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(model: "", ts: Self.now.addingTimeInterval(-10), coverageOnly: true))
        let stats = await t.snapshot(now: Self.now, thresholds: .defaults)
        XCTAssertTrue(stats.isEmpty, "a bookkeeping-only event must not surface as a live session")
    }

    func test_coverageOnlyEvent_doesNotInflateTurnsOrClobberLatestMain() async {
        let t = SessionTracker(pricing: .defaults)
        let ts = Self.now.addingTimeInterval(-10)
        // Same timestamp as the real turn — exercises `apply`'s `>=`
        // tie-break. A coverage event sharing that timestamp must not
        // count as a second turn or overwrite the model/context the real
        // usage event set.
        await t.apply(ev(input: 50_000, ts: ts))
        await t.apply(ev(model: "", ts: ts, coverageOnly: true, hasUsage: true))
        let s = onlySession(await t.snapshot(now: Self.now, thresholds: .defaults))
        XCTAssertEqual(s.turns, 1, "the coverage event must not count as a second turn")
        XCTAssertEqual(s.model, "claude-opus-4-8")
        XCTAssertEqual(s.contextTokens, 50_000)
    }

    // MARK: - reset

    func test_reset_clearsSessions() async {
        let t = SessionTracker(pricing: .defaults)
        await t.apply(ev(input: 1, ts: Self.now.addingTimeInterval(-10)))
        await t.reset()
        let stats = await t.snapshot(now: Self.now, thresholds: .defaults)
        XCTAssertTrue(stats.isEmpty)
    }
}
