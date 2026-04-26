import XCTest
@testable import ClaudeCounterCore

final class AggregatorTests: XCTestCase {

    // MARK: - apply / dedupe

    func test_apply_singleEvent_appearsInSnapshot() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: Self.fixedNow, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.day["claude-opus-4-7"]?.tokens.input, 1_000_000)
        XCTAssertEqual(s.day["claude-opus-4-7"]?.usd ?? 0, 5.0, accuracy: 1e-9)
    }

    func test_apply_duplicateMsgReqID_isDeduped() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        let ev = event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                       project: "p1", isSub: false, ts: Self.fixedNow,
                       msgID: "m1", reqID: "r1")
        await agg.apply(ev)
        await agg.apply(ev) // duplicate
        let s = await agg.snapshot()
        XCTAssertEqual(s.day["claude-opus-4-7"]?.tokens.input, 1_000_000)
        XCTAssertEqual(s.dupes, 1)
    }

    func test_apply_emptyMessageID_neverDeduped() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        let ev = event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                       project: "p1", isSub: false, ts: Self.fixedNow,
                       msgID: "", reqID: "r1")
        await agg.apply(ev)
        await agg.apply(ev) // both counted because msgID is empty
        let s = await agg.snapshot()
        XCTAssertEqual(s.day["claude-opus-4-7"]?.tokens.input, 2_000_000)
        XCTAssertEqual(s.dupes, 0)
    }

    func test_apply_emptyRequestID_neverDeduped() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        let ev = event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                       project: "p1", isSub: false, ts: Self.fixedNow,
                       msgID: "m1", reqID: "")
        await agg.apply(ev)
        await agg.apply(ev) // both counted because reqID is empty
        let s = await agg.snapshot()
        XCTAssertEqual(s.day["claude-opus-4-7"]?.tokens.input, 2_000_000)
        XCTAssertEqual(s.dupes, 0)
    }

    func test_apply_unknownModel_addsToUnknownSet() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-mystery-9-9", input: 1_000_000,
                              output: 0, project: "p1", isSub: false,
                              ts: Self.fixedNow, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.unknown, 1)
        // Unknown-model tokens are still bucketed but cost is 0.
        XCTAssertEqual(s.day["claude-mystery-9-9"]?.tokens.input, 1_000_000)
        XCTAssertEqual(s.day["claude-mystery-9-9"]?.usd, 0)
    }

    // MARK: - civil day / month bucketing

    func test_snapshot_eventOnDifferentDay_notInDayButInMonth() async {
        let now = Self.fixedNow // 2026-04-26 14:00 local
        let yesterdayLocal = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: yesterdayLocal, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertNil(s.day["claude-opus-4-7"], "yesterday should not be in 'day' bucket")
        XCTAssertEqual(s.month["claude-opus-4-7"]?.tokens.input, 1_000_000,
                       "yesterday in same month should still be in 'month' bucket")
    }

    func test_snapshot_eventLastMonth_notInMonth() async {
        let now = Self.fixedNow
        let lastMonthLocal = Calendar.current.date(byAdding: .month, value: -1, to: now)!
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: lastMonthLocal, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertNil(s.day["claude-opus-4-7"])
        XCTAssertNil(s.month["claude-opus-4-7"])
    }

    // MARK: - per-project main vs subagent

    func test_snapshot_perProject_splitsMainAndSub() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: Self.fixedNow, msgID: "m1", reqID: "r1"))
        await agg.apply(event(model: "claude-opus-4-7", input: 2_000_000, output: 0,
                              project: "p1", isSub: true,
                              ts: Self.fixedNow, msgID: "m2", reqID: "r2"))

        let s = await agg.snapshot()
        let p = s.dayProj["p1"]
        XCTAssertEqual(p?.main.input, 1_000_000)
        XCTAssertEqual(p?.sub.input, 2_000_000)
        XCTAssertEqual(p?.mainUSD ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p?.subUSD ?? 0, 10.0, accuracy: 1e-9)
        XCTAssertEqual(p?.totalUSD ?? 0, 15.0, accuracy: 1e-9)
    }

    func test_snapshot_perProjectMultiModel_costedPerModel() async {
        // p1 spends 1M opus input ($5) and 1M sonnet input ($3) → $8 main.
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: Self.fixedNow, msgID: "m1", reqID: "r1"))
        await agg.apply(event(model: "claude-sonnet-4-6", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: Self.fixedNow, msgID: "m2", reqID: "r2"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.dayProj["p1"]?.mainUSD ?? 0, 8.0, accuracy: 1e-9)
    }

    // MARK: - daily window

    func test_snapshot_dailyWindow_returns30Days_oldestFirst_todayLast() async {
        let now = Self.fixedNow
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: now, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.daily.count, 30)
        // Last entry should be today.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        XCTAssertEqual(s.daily.last?.day, fmt.string(from: now))
        // Today's USD reflects the event we recorded.
        XCTAssertEqual(s.daily.last?.usd ?? 0, 5.0, accuracy: 1e-9)
        // Days other than today are zero (no events).
        for entry in s.daily.dropLast() {
            XCTAssertEqual(entry.usd, 0)
        }
    }

    // MARK: - hourly (today)

    func test_snapshot_todayHourly_bucketsByLocalHour() async {
        // Today at 09:30 and 14:30 local — should land in hours 9 and 14.
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Self.fixedNow)
        comps.hour = 9; comps.minute = 30
        let nineThirty = Calendar.current.date(from: comps)!
        comps.hour = 14
        let twoThirty = Calendar.current.date(from: comps)!

        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false, ts: nineThirty,
                              msgID: "m1", reqID: "r1"))
        await agg.apply(event(model: "claude-opus-4-7", input: 2_000_000, output: 0,
                              project: "p1", isSub: false, ts: twoThirty,
                              msgID: "m2", reqID: "r2"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.todayHourly.count, 24)
        XCTAssertEqual(s.todayHourly[9].input, 1_000_000)
        XCTAssertEqual(s.todayHourly[14].input, 2_000_000)
        XCTAssertEqual(s.todayHourly[0].input, 0)
    }

    func test_snapshot_todayHourly_ignoresYesterdayEvents() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Self.fixedNow)!
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-opus-4-7", input: 5_000_000, output: 0,
                              project: "p1", isSub: false, ts: yesterday,
                              msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        for h in 0..<24 {
            XCTAssertEqual(s.todayHourly[h].input, 0, "hour \(h) should have no tokens from yesterday")
        }
    }

    // MARK: - Fixtures / helpers

    /// 2026-04-26 14:00:00 in the user's local TZ. Late enough into the
    /// day that we can derive yesterday/last-month dates without rolling
    /// the day under feet.
    static let fixedNow: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 26; c.hour = 14
        return Calendar.current.date(from: c)!
    }()

    private func event(model: String, input: UInt64, output: UInt64,
                       project: String, isSub: Bool, ts: Date,
                       msgID: String, reqID: String) -> UsageEvent {
        UsageEvent(
            timestamp: ts, sessionID: "s1", cwd: "/tmp/x",
            project: project, model: model,
            messageID: msgID, requestID: reqID,
            isSubagent: isSub,
            usage: Usage(input: input, output: output)
        )
    }
}
