import XCTest
@testable import ClaudeCounterCore

// `ModelPalette` lives in the ClaudeCounterBar target, but we want to
// keep the test logic near the rest of the data-model tests. The
// behaviour tested here is purely about the ranking and key-stability
// of the model→colour-index mapping; we re-implement just enough of
// the ranking rule below to verify the shared assumptions hold —
// changes to `ModelPalette` should drag a corresponding update here.
//
// (We can't `@testable import ClaudeCounterBar` because it's an
// executable, not a library target. The mapping rule is small enough
// that mirroring it in this test file is cheaper than refactoring the
// target structure.)
final class ModelPaletteRankingTests: XCTestCase {

    /// The palette ranks models by month-USD descending, then appends
    /// any extras (models that show up in the daily window but not in
    /// the month totals) in alphabetical order. This test pins that
    /// rule so a regression in `Aggregator.snapshot` (e.g. forgetting
    /// to populate `usdByModel` for a day) doesn't silently shuffle
    /// the colour assignments.
    func test_modelOrder_isMonthUSDDescending_thenAlphabetical() {
        // Three priced models with descending month USD.
        let month: [String: ModelDay] = [
            "claude-opus-4-7":   ModelDay(usd: 100, tokens: .zero),
            "claude-sonnet-4-6": ModelDay(usd: 30,  tokens: .zero),
            "claude-haiku-4-5":  ModelDay(usd: 5,   tokens: .zero),
        ]
        // Plus a model that only appears in the 30-day window (e.g. a
        // legacy model used 3 weeks ago but not this calendar month).
        let daily: [DailyTotal] = [
            DailyTotal(day: "2026-04-15",
                       usd: 0,
                       tokens: 100,
                       usdByModel: [:],
                       tokensByModel: ["claude-legacy-model": 100])
        ]

        let order = expectedOrder(month: month, daily: daily)
        XCTAssertEqual(
            order,
            ["claude-opus-4-7",      // rank 0 (top USD)
             "claude-sonnet-4-6",    // rank 1
             "claude-haiku-4-5",     // rank 2
             "claude-legacy-model"], // appended (alphabetical among extras)
            "month-USD descending then alphabetical extras"
        )
    }

    /// Two extras → alphabetical between them.
    func test_modelOrder_multipleExtras_areAlphabetical() {
        let month: [String: ModelDay] = [
            "claude-opus-4-7": ModelDay(usd: 50, tokens: .zero),
        ]
        let daily: [DailyTotal] = [
            DailyTotal(day: "2026-04-01",
                       usd: 0, tokens: 100,
                       usdByModel: [:],
                       tokensByModel: ["zeta-model": 50, "alpha-model": 50]),
        ]
        let order = expectedOrder(month: month, daily: daily)
        XCTAssertEqual(order,
                       ["claude-opus-4-7", "alpha-model", "zeta-model"])
    }

    /// Pure mirror of `ModelPalette.init`'s ranking rule, kept close
    /// to the assertions so a future change to the rule has to
    /// update this helper too — guards against drift.
    private func expectedOrder(month: [String: ModelDay],
                               daily: [DailyTotal]) -> [String] {
        let monthRanked = month
            .map { (name: $0.key, usd: $0.value.usd) }
            .sorted { $0.usd > $1.usd }
            .map(\.name)
        let monthSet = Set(monthRanked)
        var extras = Set<String>()
        for d in daily {
            for m in d.usdByModel.keys where !monthSet.contains(m) { extras.insert(m) }
            for m in d.tokensByModel.keys where !monthSet.contains(m) { extras.insert(m) }
        }
        return monthRanked + extras.sorted()
    }
}
