import XCTest
@testable import ClaudeCounterCore

/// Reads the same fixture bytes as `tui/internal/agg/codex_parity_test.go`.
/// Unlike `costed_parity.json`/`grouping_parity.json`, this fixture drives
/// the real `Aggregator.apply`/`snapshot` path rather than feeding
/// pre-summed usd straight into `Grouping.group`: Codex is priced, not
/// costed, so the behavior worth pinning cross-language — the pricing
/// table lookup, and `codex-auto-review`'s alias to `gpt-5.6-luna` — only
/// fires if each language's own pricing lookup actually runs. The
/// fixture's pricing table has a row for `gpt-5.6-luna` but none for
/// `codex-auto-review` itself, so a non-zero `codex-auto-review` cost is
/// reachable only through the alias. If these two suites ever disagree,
/// the TUI and the menu bar app report different dollars for the same
/// Codex month.
final class CodexParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Now: Decodable { let year, month, day, hour: Int }
        struct Price: Decodable {
            let input, output, cacheCreate, cacheRead: Double
        }
        struct Event: Decodable {
            let msgID, reqID, source, project, model: String
            let dayOffset: Int
            let input, output, cacheCreate, cacheRead: UInt64
        }
        struct Tokens: Decodable {
            let input, output, cacheCreate, cacheRead: UInt64
        }
        struct Daily: Decodable { let usd: Double; let tokens: UInt64 }
        struct Proj: Decodable {
            let usd: Double
            let input, output, cacheCreate, cacheRead: UInt64
        }

        let now: Now
        let pricing: [String: Price]
        let events: [Event]
        let expectUnknown: Int
        let expectMonth: [String: [String: Double]]
        let expectMonthTokens: [String: [String: Tokens]]
        let expectDay: [String: [String: Double]]
        let expectDayTokens: [String: [String: Tokens]]
        let expectMonthProj: [String: Proj]
        let expectDayProj: [String: Proj]
        let expectDaily: [String: Daily]
    }

    private let modes: [String: GroupMode] = [
        "model": .model,
        "vendor": .vendor,
        "source": .source,
        "total": .total,
    ]

    func test_codexParityFixture() async throws {
        guard let url = Bundle.module.url(forResource: "codex_parity",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            return XCTFail("codex parity fixture not found in test bundle")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.events.isEmpty, "codex parity fixture has no events")

        var table = PricingTable(models: [:], schema: PricingTable.currentSchema)
        for (model, p) in fixture.pricing {
            table.models[model] = ModelPrice(inputPerMTok: p.input, outputPerMTok: p.output,
                                             cacheCreationPerMTok: p.cacheCreate,
                                             cacheReadPerMTok: p.cacheRead)
        }

        var comps = DateComponents()
        comps.year = fixture.now.year; comps.month = fixture.now.month
        comps.day = fixture.now.day; comps.hour = fixture.now.hour
        let calendar = Calendar.current
        let now = calendar.date(from: comps)!

        let agg = Aggregator(pricing: table, now: { now }, calendar: calendar)
        for e in fixture.events {
            let ts = calendar.date(byAdding: .day, value: e.dayOffset, to: now)!
            let ev = UsageEvent(
                timestamp: ts, sessionID: "s1", cwd: "/tmp/codex",
                project: e.project, model: e.model,
                messageID: e.msgID, requestID: e.reqID, isSubagent: false,
                usage: Usage(input: e.input, output: e.output,
                            cacheCreate: e.cacheCreate, cacheRead: e.cacheRead),
                source: e.source, vendor: "codex"
            )
            _ = await agg.apply(ev)
        }
        let snap = await agg.snapshot()

        XCTAssertEqual(snap.unknown, fixture.expectUnknown,
                       "codex-auto-review must resolve via alias, never count as unpriced")

        func checkScope(_ scopeName: String, _ input: [SeriesKey: ModelDay],
                        _ wantUSD: [String: [String: Double]],
                        _ wantTok: [String: [String: Fixture.Tokens]]) {
            for (name, mode) in modes {
                guard let want = wantUSD[name] else {
                    XCTFail("fixture has no \(scopeName) USD expectations for mode \(name)")
                    continue
                }
                guard let wantTokens = wantTok[name] else {
                    XCTFail("fixture has no \(scopeName) token expectations for mode \(name)")
                    continue
                }
                let got = Grouping.group(input, by: mode)
                XCTAssertEqual(got.count, want.count, "\(scopeName) mode \(name): bucket count")
                for (bucket, wantUSDVal) in want {
                    guard let g = got[bucket] else {
                        XCTFail("\(scopeName) mode \(name): missing bucket \(bucket), want USD \(wantUSDVal)")
                        continue
                    }
                    XCTAssertEqual(g.usd, wantUSDVal, accuracy: 0.0001,
                                   "\(scopeName) mode \(name): bucket \(bucket)")
                    guard let wt = wantTokens[bucket] else {
                        XCTFail("\(scopeName) mode \(name): missing token expectation for bucket \(bucket)")
                        continue
                    }
                    XCTAssertEqual(g.tokens.input, wt.input, "\(scopeName) mode \(name): bucket \(bucket) input")
                    XCTAssertEqual(g.tokens.output, wt.output, "\(scopeName) mode \(name): bucket \(bucket) output")
                    XCTAssertEqual(g.tokens.cacheCreate, wt.cacheCreate, "\(scopeName) mode \(name): bucket \(bucket) cacheCreate")
                    XCTAssertEqual(g.tokens.cacheRead, wt.cacheRead, "\(scopeName) mode \(name): bucket \(bucket) cacheRead")
                }
            }
        }

        checkScope("month", snap.month, fixture.expectMonth, fixture.expectMonthTokens)
        checkScope("day", snap.day, fixture.expectDay, fixture.expectDayTokens)

        XCTAssertFalse(fixture.expectMonthProj.isEmpty, "fixture has no month-project expectations")
        for (proj, want) in fixture.expectMonthProj {
            guard let pd = snap.monthProj[proj] else {
                XCTFail("missing monthProj entry for \(proj)")
                continue
            }
            XCTAssertEqual(pd.totalUSD, want.usd, accuracy: 0.0001, "monthProj[\(proj)].totalUSD")
            let tok = pd.totalTokens
            XCTAssertEqual(tok.input, want.input, "monthProj[\(proj)].totalTokens.input")
            XCTAssertEqual(tok.output, want.output, "monthProj[\(proj)].totalTokens.output")
            XCTAssertEqual(tok.cacheCreate, want.cacheCreate, "monthProj[\(proj)].totalTokens.cacheCreate")
            XCTAssertEqual(tok.cacheRead, want.cacheRead, "monthProj[\(proj)].totalTokens.cacheRead")
        }

        XCTAssertFalse(fixture.expectDayProj.isEmpty, "fixture has no day-project expectations")
        for (proj, want) in fixture.expectDayProj {
            guard let pd = snap.dayProj[proj] else {
                XCTFail("missing dayProj entry for \(proj)")
                continue
            }
            XCTAssertEqual(pd.totalUSD, want.usd, accuracy: 0.0001, "dayProj[\(proj)].totalUSD")
            let tok = pd.totalTokens
            XCTAssertEqual(tok.input, want.input, "dayProj[\(proj)].totalTokens.input")
            XCTAssertEqual(tok.output, want.output, "dayProj[\(proj)].totalTokens.output")
            XCTAssertEqual(tok.cacheCreate, want.cacheCreate, "dayProj[\(proj)].totalTokens.cacheCreate")
            XCTAssertEqual(tok.cacheRead, want.cacheRead, "dayProj[\(proj)].totalTokens.cacheRead")
        }
        // proj-b has no events on today's civil day (its two events fall on
        // dayOffset -1 and -2), so it must be entirely absent from dayProj
        // rather than present with a zero total.
        XCTAssertNil(snap.dayProj["proj-b"], "dayProj[proj-b] present, want absent (no events today)")

        XCTAssertFalse(fixture.expectDaily.isEmpty, "fixture has no daily expectations")
        var byDay: [String: DailyTotal] = [:]
        for d in snap.daily { byDay[d.day] = d }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        for (offsetStr, want) in fixture.expectDaily {
            guard let offset = Int(offsetStr) else {
                XCTFail("bad offset \(offsetStr) in fixture")
                continue
            }
            let day = calendar.date(byAdding: .day, value: offset, to: now)!
            let dayStr = fmt.string(from: day)
            guard let got = byDay[dayStr] else {
                XCTFail("daily has no entry for \(dayStr) (offset \(offsetStr))")
                continue
            }
            XCTAssertEqual(got.usd, want.usd, accuracy: 0.0001, "daily[\(dayStr)] (offset \(offsetStr)) usd")
            XCTAssertEqual(got.tokens, want.tokens, "daily[\(dayStr)] (offset \(offsetStr)) tokens")
        }
    }
}
