import XCTest
@testable import ClaudeCounterCore

/// Reads the same fixture bytes as `tui/internal/agg/grouping_parity_test.go`.
/// If these two suites ever disagree, the TUI and the menu bar app are
/// grouping the same spend into different vendor/source/model buckets —
/// exactly the drift this file exists to prevent.
///
/// This is a second fixture, separate from limits_parity.json, which pins
/// the budget engines. This one pins Grouping.group/GroupMode instead.
final class GroupingParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Series: Decodable {
            let source: String
            let vendor: String
            let model: String
            let usd: Double
            let tokens: UInt64
        }
        let series: [Series]
        let expect: [String: [String: Double]]
        let expectTokens: [String: [String: UInt64]]
    }

    private let modes: [String: GroupMode] = [
        "model": .model,
        "vendor": .vendor,
        "source": .source,
        "total": .total,
    ]

    func test_groupingParityFixture() throws {
        guard let url = Bundle.module.url(forResource: "grouping_parity",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            return XCTFail("grouping parity fixture not found in test bundle")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.series.isEmpty, "grouping parity fixture has no series")
        XCTAssertFalse(fixture.expect.isEmpty, "grouping parity fixture has no expectations")
        XCTAssertFalse(fixture.expectTokens.isEmpty, "grouping parity fixture has no token expectations")

        var input: [SeriesKey: ModelDay] = [:]
        for s in fixture.series {
            let key = SeriesKey(source: s.source, vendor: s.vendor, model: s.model)
            var cur = input[key] ?? ModelDay(usd: 0, tokens: .zero)
            cur.usd += s.usd
            cur.tokens = cur.tokens.adding(TokenCounts(input: s.tokens))
            input[key] = cur
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
            let got = Grouping.group(input, by: mode)
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
    }
}
