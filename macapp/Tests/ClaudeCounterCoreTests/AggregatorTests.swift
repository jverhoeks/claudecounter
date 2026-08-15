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
        XCTAssertEqual(s.day[sk("claude-opus-4-7")]?.tokens.input, 1_000_000)
        XCTAssertEqual(s.day[sk("claude-opus-4-7")]?.usd ?? 0, 5.0, accuracy: 1e-9)
    }

    func test_apply_duplicateMsgReqID_isDeduped() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        let ev = event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                       project: "p1", isSub: false, ts: Self.fixedNow,
                       msgID: "m1", reqID: "r1")
        await agg.apply(ev)
        await agg.apply(ev) // duplicate
        let s = await agg.snapshot()
        XCTAssertEqual(s.day[sk("claude-opus-4-7")]?.tokens.input, 1_000_000)
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
        XCTAssertEqual(s.day[sk("claude-opus-4-7")]?.tokens.input, 2_000_000)
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
        XCTAssertEqual(s.day[sk("claude-opus-4-7")]?.tokens.input, 2_000_000)
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
        XCTAssertEqual(s.day[sk("claude-mystery-9-9")]?.tokens.input, 1_000_000)
        XCTAssertEqual(s.day[sk("claude-mystery-9-9")]?.usd, 0)
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
        XCTAssertNil(s.day[sk("claude-opus-4-7")], "yesterday should not be in 'day' bucket")
        XCTAssertEqual(s.month[sk("claude-opus-4-7")]?.tokens.input, 1_000_000,
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
        XCTAssertNil(s.day[sk("claude-opus-4-7")])
        XCTAssertNil(s.month[sk("claude-opus-4-7")])
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
        // Today's tokens reflect the event we recorded (1M input, 0 of others).
        XCTAssertEqual(s.daily.last?.tokens ?? 0, 1_000_000)
        // Days other than today are zero (no events) — both USD and tokens.
        for entry in s.daily.dropLast() {
            XCTAssertEqual(entry.usd, 0)
            XCTAssertEqual(entry.tokens, 0)
        }
    }

    func test_snapshot_dailyTokens_sumAllFourTokenTypes() async {
        // One event with non-zero values for ALL four token types — the
        // daily token total should be the sum, not just `input`.
        let now = Self.fixedNow
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-opus-4-7",
                              input: 100, output: 200,
                              cacheCreate: 30, cacheRead: 70,
                              project: "p1", isSub: false,
                              ts: now, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.daily.last?.tokens ?? 0, 100 + 200 + 30 + 70)
    }

    func test_snapshot_dailyTokens_sumAcrossModels() async {
        // Two events on the same day from two different models — the
        // daily total should sum across models (it's an unbucketed total).
        let now = Self.fixedNow
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-opus-4-7", input: 100, output: 0,
                              project: "p1", isSub: false,
                              ts: now, msgID: "m1", reqID: "r1"))
        await agg.apply(event(model: "claude-sonnet-4-7", input: 250, output: 0,
                              project: "p2", isSub: false,
                              ts: now, msgID: "m2", reqID: "r2"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.daily.last?.tokens ?? 0, 350)
    }

    func test_snapshot_dailyTokens_includesUnpricedModels() async {
        // Tokens count for ALL models, even ones missing from pricing —
        // the chart should reflect raw activity. (USD only counts priced
        // models, that's the existing behaviour and is unchanged.)
        let now = Self.fixedNow
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-mystery-model-9000",
                              input: 500, output: 0,
                              project: "p1", isSub: false,
                              ts: now, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertEqual(s.daily.last?.tokens ?? 0, 500,
                       "tokens count even for unpriced models")
        XCTAssertEqual(s.daily.last?.usd ?? 0, 0,
                       "USD stays zero for unpriced models")
    }

    // MARK: - Per-model daily breakdown (for stacked-bar charts)

    /// Two models on the same day → daily breakdown maps each model
    /// name to its individual tokens AND usd contribution. The totals
    /// already-tested elsewhere should equal the sum of these maps.
    func test_snapshot_dailyByModel_splitsTokensAndUSD() async {
        let now = Self.fixedNow
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: now, msgID: "m1", reqID: "r1"))
        await agg.apply(event(model: "claude-sonnet-4-6", input: 2_000_000, output: 0,
                              project: "p2", isSub: false,
                              ts: now, msgID: "m2", reqID: "r2"))

        let s = await agg.snapshot()
        let last = s.daily.last
        XCTAssertEqual(last?.tokensByModel["claude-opus-4-7"] ?? 0, 1_000_000)
        XCTAssertEqual(last?.tokensByModel["claude-sonnet-4-6"] ?? 0, 2_000_000)
        // Sum of per-model tokens equals the day's total.
        let summedTokens = (last?.tokensByModel.values.reduce(0, +)) ?? 0
        XCTAssertEqual(summedTokens, last?.tokens ?? 0)

        // Costs split per model too. Default input prices: Opus $5/Mtok,
        // Sonnet $3/Mtok (see Pricing.swift `defaults`).
        XCTAssertEqual(last?.usdByModel["claude-opus-4-7"] ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(last?.usdByModel["claude-sonnet-4-6"] ?? 0, 6.0, accuracy: 1e-9)
        let summedUSD = (last?.usdByModel.values.reduce(0, +)) ?? 0
        XCTAssertEqual(summedUSD, last?.usd ?? 0, accuracy: 1e-9)
    }

    /// Unpriced models contribute to `tokensByModel` but NOT to
    /// `usdByModel` — the breakdown mirrors the totals' rule that
    /// USD-bearing keys must be priced.
    func test_snapshot_dailyByModel_unpricedHasTokensButNoUSD() async {
        let now = Self.fixedNow
        let agg = Aggregator(pricing: .defaults, now: { now })
        await agg.apply(event(model: "claude-mystery-model-9000",
                              input: 500, output: 0,
                              project: "p1", isSub: false,
                              ts: now, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        let last = s.daily.last
        XCTAssertEqual(last?.tokensByModel["claude-mystery-model-9000"] ?? 0, 500,
                       "unpriced model should appear in tokensByModel")
        XCTAssertNil(last?.usdByModel["claude-mystery-model-9000"],
                     "unpriced model must not appear in usdByModel")
    }

    /// Days with no events have empty per-model breakdowns.
    func test_snapshot_dailyByModel_emptyDaysHaveEmptyMaps() async {
        let now = Self.fixedNow
        let agg = Aggregator(pricing: .defaults, now: { now })
        // Single event — only "today" has data. Yesterday should be empty.
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false,
                              ts: now, msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        XCTAssertGreaterThan(s.daily.count, 1)
        // Penultimate entry (yesterday) — both maps empty.
        let yesterday = s.daily[s.daily.count - 2]
        XCTAssertTrue(yesterday.tokensByModel.isEmpty)
        XCTAssertTrue(yesterday.usdByModel.isEmpty)
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

    // MARK: - hourly per-model breakdown (any day in the window)

    /// Two models in the same hour stack into separate per-model
    /// entries, and the per-hour totals match todayHourlyUSD.
    func test_snapshot_hourlyUSDByModel_splitsModelsWithinHour() async {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Self.fixedNow)
        comps.hour = 9; comps.minute = 30
        let nineThirty = Calendar.current.date(from: comps)!

        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false, ts: nineThirty,
                              msgID: "m1", reqID: "r1"))
        await agg.apply(event(model: "claude-sonnet-4-5", input: 1_000_000, output: 0,
                              project: "p1", isSub: false, ts: nineThirty,
                              msgID: "m2", reqID: "r2"))
        let s = await agg.snapshot()

        let today = s.daily.last
        XCTAssertEqual(today?.hourlyUSDByModel.count, 24)
        let nine = today?.hourlyUSDByModel[9] ?? [:]
        XCTAssertEqual(nine.count, 2, "both models present in hour 9")
        XCTAssertGreaterThan(nine["claude-opus-4-7"] ?? 0, 0)
        XCTAssertGreaterThan(nine["claude-sonnet-4-5"] ?? 0, 0)
        XCTAssertEqual(nine.values.reduce(0, +), s.todayHourlyUSD[9], accuracy: 1e-9,
                       "per-model hour segments sum to the hour total")
        XCTAssertTrue(today?.hourlyUSDByModel[10].isEmpty ?? false, "untouched hours stay empty")
    }

    /// Past days inside the window carry their own hourly breakdown —
    /// the data behind click-a-day-in-the-monthly-chart.
    func test_snapshot_hourlyUSDByModel_availableForPastDays() async {
        var comps = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: Calendar.current.date(byAdding: .day, value: -3, to: Self.fixedNow)!)
        comps.hour = 22
        let threeDaysAgoLate = Calendar.current.date(from: comps)!

        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-opus-4-7", input: 1_000_000, output: 0,
                              project: "p1", isSub: false, ts: threeDaysAgoLate,
                              msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()

        let entry = s.daily[s.daily.count - 4]   // window is oldest→newest
        XCTAssertGreaterThan(entry.hourlyUSDByModel[22]["claude-opus-4-7"] ?? 0, 0,
                             "past day keeps its per-hour per-model spend")
        // And today's chart stays untouched.
        XCTAssertTrue(s.daily.last?.hourlyUSDByModel.allSatisfy { $0.isEmpty } ?? false)
    }

    /// Unpriced models bucket tokens but contribute no USD segments,
    /// matching usdByModel's behaviour.
    func test_snapshot_hourlyUSDByModel_excludesUnpricedModels() async {
        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg.apply(event(model: "claude-mystery-model-9000", input: 500, output: 0,
                              project: "p1", isSub: false, ts: Self.fixedNow,
                              msgID: "m1", reqID: "r1"))
        let s = await agg.snapshot()
        let hour = hourOfFixedNow()
        XCTAssertNil(s.daily.last?.hourlyUSDByModel[hour]["claude-mystery-model-9000"])
        XCTAssertGreaterThan(s.todayHourly[hour].input, 0, "tokens still counted")
    }

    private func hourOfFixedNow() -> Int {
        Calendar.current.component(.hour, from: Self.fixedNow)
    }

    // MARK: - costed cells (vendor-reported dollars, e.g. Grok)

    func test_costedEvent_ignoresPricingTable() async {
        // Price the model absurdly: if snapshot ever consults the table for
        // a costed cell the assertion fails loudly rather than drifting.
        let table = PricingTable(models: ["grok-4.6-build":
            ModelPrice(inputPerMTok: 1000, outputPerMTok: 1000,
                       cacheCreationPerMTok: 0, cacheReadPerMTok: 0)])
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let agg = Aggregator(pricing: table, now: { now })

        await agg.apply(UsageEvent(
            timestamp: now, sessionID: "s", cwd: "", project: "p",
            model: "grok-4.6-build", messageID: "prompt-1", requestID: "grok-4.6-build",
            isSubagent: false,
            usage: Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 0, cacheRead: 0),
            source: "grok/grok", vendor: "grok",
            costUSD: 0.37, costed: true))

        let got = await agg.snapshot()
        let key = SeriesKey(source: "grok/grok", vendor: "grok", model: "grok-4.6-build")
        XCTAssertEqual(got.month[key]?.usd ?? 0, 0.37, accuracy: 1e-9)
        XCTAssertEqual(got.day[key]?.usd ?? 0, 0.37, accuracy: 1e-9)
        XCTAssertEqual(got.daily.last?.usd ?? 0, 0.37, accuracy: 1e-9)
        XCTAssertEqual(got.monthProj["p"]?.totalUSD ?? 0, 0.37, accuracy: 1e-9)
        XCTAssertEqual(got.unknown, 0, "a costed model has no pricing entry to be missing")
        // The hourly chart must show it too — that is the view the user asked for.
        let hour = Calendar.current.component(.hour, from: now)
        XCTAssertEqual(got.todayHourlyUSD[hour], 0.37, accuracy: 1e-9)
        XCTAssertEqual(got.daily.last?.hourlyUSDByModel[hour]["grok-4.6-build"] ?? 0,
                       0.37, accuracy: 1e-9)
    }

    func test_pricedAndCostedCells_sumTogether() async {
        let table = PricingTable(models: ["claude-opus-4-7":
            ModelPrice(inputPerMTok: 15, outputPerMTok: 75,
                       cacheCreationPerMTok: 0, cacheReadPerMTok: 0)])
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let agg = Aggregator(pricing: table, now: { now })

        await agg.apply(UsageEvent(
            timestamp: now, sessionID: "s", cwd: "", project: "p",
            model: "claude-opus-4-7", messageID: "m1", requestID: "r1", isSubagent: false,
            usage: Usage(input: 1_000_000, output: 0, cacheCreate: 0, cacheRead: 0),
            source: "claude/claude", vendor: "claude"))
        await agg.apply(UsageEvent(
            timestamp: now, sessionID: "s", cwd: "", project: "p",
            model: "grok-4.6-build", messageID: "prompt-1", requestID: "grok-4.6-build",
            isSubagent: false,
            usage: Usage(input: 500, output: 0, cacheCreate: 0, cacheRead: 0),
            source: "grok/grok", vendor: "grok", costUSD: 2.5, costed: true))

        let got = await agg.snapshot()
        XCTAssertEqual(got.month.values.reduce(0) { $0 + $1.usd }, 17.5, accuracy: 1e-9)
        XCTAssertEqual(got.monthProj["p"]?.totalUSD ?? 0, 17.5, accuracy: 1e-9)
        XCTAssertEqual(got.daily.last?.usd ?? 0, 17.5, accuracy: 1e-9)
    }

    func test_coverageEvent_contributesNoSpendAndReportsTheFraction() async {
        let now = Date(timeIntervalSince1970: 1_786_800_000)
        let agg = Aggregator(pricing: PricingTable(models: [:]), now: { now })
        for hasUsage in [true, true, true, false] {
            await agg.apply(UsageEvent(
                timestamp: now, sessionID: "s", cwd: "", project: "p",
                model: "", messageID: "", requestID: "", isSubagent: false,
                usage: Usage(input: 999, output: 0, cacheCreate: 0, cacheRead: 0),
                source: "grok/grok", vendor: "grok",
                costUSD: 99, costed: true, coverageOnly: true, hasUsage: hasUsage))
        }
        let got = await agg.snapshot()
        XCTAssertTrue(got.month.isEmpty, "coverage events are bookkeeping, never spend")
        XCTAssertEqual(got.daily.last?.usd ?? 0, 0, accuracy: 1e-9)
        XCTAssertEqual(got.coverage["grok"]?.turns, 4)
        XCTAssertEqual(got.coverage["grok"]?.withUsage, 3)
        XCTAssertEqual(got.coverage["grok"]?.fraction ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertTrue(got.coverage["grok"]?.partial ?? false)
        // A vendor that emits no coverage events reads as complete, not 0%.
        XCTAssertFalse(got.coverage["claude"]?.partial ?? false)
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

    /// All events in this file go through the (implicit) default source,
    /// so every series key shares the same source/vendor — only the
    /// model varies per test.
    private func sk(_ model: String) -> SeriesKey {
        SeriesKey(source: "claude/claude", vendor: "claude", model: model)
    }

    private func event(model: String, input: UInt64, output: UInt64,
                       cacheCreate: UInt64 = 0, cacheRead: UInt64 = 0,
                       project: String, isSub: Bool, ts: Date,
                       msgID: String, reqID: String) -> UsageEvent {
        UsageEvent(
            timestamp: ts, sessionID: "s1", cwd: "/tmp/x",
            project: project, model: model,
            messageID: msgID, requestID: reqID,
            isSubagent: isSub,
            usage: Usage(input: input, output: output,
                         cacheCreate: cacheCreate, cacheRead: cacheRead)
        )
    }
}
