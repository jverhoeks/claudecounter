import XCTest
@testable import ClaudeCounterCore

/// Reads the same fixture bytes as `tui/internal/agg/costed_parity_test.go`.
/// It is a second fixture, separate from `grouping_parity.json`: that one
/// pins `Grouping.group` over priced series only. This one adds a costed
/// vendor — Grok, whose dollars come from the provider rather than a
/// pricing table — plus a coverage tally, so a costed cell and its
/// coverage marker are pinned cross-language exactly like every other
/// shared quantity. If these two suites ever disagree, the TUI and the
/// menu bar app report different dollars for the same Grok month.
///
/// The fixture's two Grok models (grok-4.5-build, grok-4-fast) both carry
/// a non-zero dayUsd because they arose from one turn whose modelUsage
/// array had two entries — a single turn_completed event that reported
/// usage against both models at once.
final class CostedParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Series: Decodable {
            let source: String
            let vendor: String
            let model: String
            let usd: Double     // month total
            let tokens: UInt64  // month total
            let dayUsd: Double  // this series' contribution to the fixture's one day
        }
        struct CoverageTally: Decodable {
            let turns: Int
            let withUsage: Int
        }
        let series: [Series]
        let expect: [String: [String: Double]]
        let expectTokens: [String: [String: UInt64]]
        let dayTotalUSD: Double
        let coverage: [String: CoverageTally]
        let expectCoverageFraction: [String: Double]
    }

    private let modes: [String: GroupMode] = [
        "model": .model,
        "vendor": .vendor,
        "source": .source,
        "total": .total,
    ]

    func test_costedParityFixture() throws {
        guard let url = Bundle.module.url(forResource: "costed_parity",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            return XCTFail("costed parity fixture not found in test bundle")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.series.isEmpty, "costed parity fixture has no series")
        XCTAssertFalse(fixture.expect.isEmpty, "costed parity fixture has no expectations")
        XCTAssertFalse(fixture.coverage.isEmpty, "costed parity fixture has no coverage")

        var monthInput: [SeriesKey: ModelDay] = [:]
        var dayInput: [SeriesKey: ModelDay] = [:]
        for s in fixture.series {
            let key = SeriesKey(source: s.source, vendor: s.vendor, model: s.model)

            var cur = monthInput[key] ?? ModelDay(usd: 0, tokens: .zero)
            cur.usd += s.usd
            cur.tokens = cur.tokens.adding(TokenCounts(input: s.tokens))
            monthInput[key] = cur

            var dcur = dayInput[key] ?? ModelDay(usd: 0, tokens: .zero)
            dcur.usd += s.dayUsd
            dayInput[key] = dcur
        }

        for (name, mode) in modes {
            guard let want = fixture.expect[name] else {
                XCTFail("fixture has no expectations for mode \(name)")
                continue
            }
            guard let wantTokens = fixture.expectTokens[name] else {
                XCTFail("fixture has no token expectations for mode \(name)")
                continue
            }
            let got = Grouping.group(monthInput, by: mode)
            XCTAssertEqual(got.count, want.count, "mode \(name): bucket count")
            for (bucket, wantUSD) in want {
                guard let g = got[bucket] else {
                    XCTFail("mode \(name): missing bucket \(bucket), want USD \(wantUSD)")
                    continue
                }
                XCTAssertEqual(g.usd, wantUSD, accuracy: 0.0001, "mode \(name): bucket \(bucket)")
                guard let wantTok = wantTokens[bucket] else {
                    XCTFail("mode \(name): missing token expectation for bucket \(bucket)")
                    continue
                }
                XCTAssertEqual(g.tokens.input, wantTok, "mode \(name): bucket \(bucket) tokens")
            }
        }

        // The daily-window figure the sparkline shows for the fixture's
        // one day is a separate group() call over the day-scoped series,
        // exactly as Aggregator.snapshot's daily computation is a
        // separate pass from month.
        let dayTotal = Grouping.group(dayInput, by: .total)["total"]?.usd ?? 0
        XCTAssertEqual(dayTotal, fixture.dayTotalUSD, accuracy: 0.0001, "day-window total")

        // Coverage isn't grouped here (groupCoverage's worst-vendor rule
        // has its own unit test); this just pins the raw fraction the
        // fixture's turn tally produces, since that arithmetic is what
        // the coverage marker in the UI is built on.
        XCTAssertFalse(fixture.expectCoverageFraction.isEmpty,
                        "costed parity fixture has no coverage fraction expectations")
        for (vendor, wantFraction) in fixture.expectCoverageFraction {
            guard let c = fixture.coverage[vendor] else {
                XCTFail("fixture coverage missing vendor \(vendor)")
                continue
            }
            let cov = Coverage(turns: c.turns, withUsage: c.withUsage)
            XCTAssertEqual(cov.fraction, wantFraction, accuracy: 0.0001,
                            "coverage[\(vendor)].fraction")
        }
    }
}
