import XCTest
@testable import ClaudeCounterCore

final class GroupingTests: XCTestCase {

    private var seed: [SeriesKey: ModelDay] {
        [
            SeriesKey(source: "claude/work", vendor: "claude", model: "claude-opus-4-7"):
                ModelDay(usd: 10, tokens: TokenCounts(input: 1_000_000)),
            SeriesKey(source: "claude/work", vendor: "claude", model: "claude-sonnet-4-6"):
                ModelDay(usd: 5, tokens: TokenCounts(input: 500_000)),
            SeriesKey(source: "claude/home", vendor: "claude", model: "claude-opus-4-7"):
                ModelDay(usd: 2, tokens: TokenCounts(input: 200_000)),
            SeriesKey(source: "grok/home", vendor: "grok", model: "grok-4.5-build"):
                ModelDay(usd: 3, tokens: TokenCounts(input: 300_000)),
        ]
    }

    func test_group_byModel_mergesAcrossSources() {
        let g = Grouping.group(seed, by: .model)
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g["claude-opus-4-7"]?.usd, 12)
        // Token merge, not just USD — a grouping that only merges dollars
        // leaves every token view wrong while the USD view looks fine.
        XCTAssertEqual(g["claude-opus-4-7"]?.tokens.input, 1_200_000)
    }

    func test_group_byVendor_collapsesModels() {
        let g = Grouping.group(seed, by: .vendor)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g["claude"]?.usd, 17)
        XCTAssertEqual(g["claude"]?.tokens.input, 1_700_000)
        XCTAssertEqual(g["grok"]?.usd, 3)
        XCTAssertEqual(g["grok"]?.tokens.input, 300_000)
    }

    func test_group_bySource_keepsSubscriptionsApart() {
        let g = Grouping.group(seed, by: .source)
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g["claude/work"]?.usd, 15)
        XCTAssertEqual(g["claude/home"]?.usd, 2)
    }

    func test_group_byTotal_isOneSeries() {
        let g = Grouping.group(seed, by: .total)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g["total"]?.usd, 20)
        XCTAssertEqual(g["total"]?.tokens.input, 2_000_000)
    }

    func test_everyMode_sumsToTheSameTotal() {
        let want = seed.values.reduce(0) { $0 + $1.usd }
        for mode in [GroupMode.model, .vendor, .source, .total] {
            let got = Grouping.group(seed, by: mode).values.reduce(0) { $0 + $1.usd }
            XCTAssertEqual(got, want, accuracy: 0.0001, "mode \(mode)")
        }
    }

    func test_next_cycles() {
        var m = GroupMode.model
        for want in [GroupMode.vendor, .source, .total, .model] {
            m = m.next
            XCTAssertEqual(m, want)
        }
    }

    func test_label_matchesGoModeStrings() {
        XCTAssertEqual(GroupMode.model.label, "model")
        XCTAssertEqual(GroupMode.vendor.label, "vendor")
        XCTAssertEqual(GroupMode.source.label, "source")
        XCTAssertEqual(GroupMode.total.label, "total")
    }
}
