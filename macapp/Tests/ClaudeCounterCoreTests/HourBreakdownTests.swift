import XCTest
@testable import ClaudeCounterCore

/// `hourBreakdownRows` turns one hour's per-model USD map into the
/// ordered rows the hourly chart's hover popup renders. It lives in
/// Core rather than beside the view because the test target depends on
/// `ClaudeCounterCore` only — view code in `ClaudeCounterBar` has no
/// test path (see the note atop `ModelPaletteTests`).
final class HourBreakdownTests: XCTestCase {

    func test_sortsBySpendDescending() {
        let (rows, overflow) = hourBreakdownRows(
            from: ["a": 1.0, "b": 5.0, "c": 3.0], limit: 5)
        XCTAssertEqual(rows.map(\.model), ["b", "c", "a"])
        XCTAssertEqual(overflow, 0)
    }

    func test_dropsZeroAndNegativeEntries() {
        // A model can appear in the map with no spend for the hour —
        // an all-cached turn, or a costed vendor reporting zero. A row
        // reading "$0.00" is noise in a popup this small.
        let (rows, _) = hourBreakdownRows(
            from: ["a": 2.0, "zero": 0.0, "neg": -1.0], limit: 5)
        XCTAssertEqual(rows.map(\.model), ["a"])
    }

    func test_capsAtLimitAndReportsOverflow() {
        let (rows, overflow) = hourBreakdownRows(
            from: ["a": 5, "b": 4, "c": 3, "d": 2, "e": 1], limit: 3)
        XCTAssertEqual(rows.map(\.model), ["a", "b", "c"])
        XCTAssertEqual(overflow, 2, "the two capped rows must be reported, not silently dropped")
    }

    func test_overflowCountsOnlyNonZeroRows() {
        // Zero rows are dropped before the cap, so they must not inflate
        // the "+N more" count — that would promise spend that isn't there.
        let (rows, overflow) = hourBreakdownRows(
            from: ["a": 5, "b": 4, "z1": 0, "z2": 0], limit: 1)
        XCTAssertEqual(rows.map(\.model), ["a"])
        XCTAssertEqual(overflow, 1)
    }

    func test_tiesBreakByModelNameSoOrderIsStable() {
        // Dictionary iteration order is not stable across renders. Without
        // a deterministic tiebreak the popup's rows would visibly reshuffle
        // while the pointer sits still on one bar.
        let input = ["beta": 2.0, "alpha": 2.0, "gamma": 2.0]
        let first = hourBreakdownRows(from: input, limit: 5).rows.map(\.model)
        XCTAssertEqual(first, ["alpha", "beta", "gamma"])
        for _ in 0..<20 {
            XCTAssertEqual(hourBreakdownRows(from: input, limit: 5).rows.map(\.model), first)
        }
    }

    func test_emptyHourYieldsNoRows() {
        let (rows, overflow) = hourBreakdownRows(from: [:], limit: 5)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(overflow, 0)
    }

    func test_allZeroHourYieldsNoRows() {
        // The view uses "no rows" to mean "show no popup at all" for an
        // idle hour, so this case must not produce an empty-looking panel.
        let (rows, overflow) = hourBreakdownRows(from: ["a": 0, "b": 0], limit: 5)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(overflow, 0)
    }

    func test_totalIsTheSumOfKeptRows() {
        let (rows, _) = hourBreakdownRows(from: ["a": 1.5, "b": 2.25, "z": 0], limit: 5)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.usd }, 3.75, accuracy: 1e-9)
    }
}
