import XCTest
@testable import ClaudeCounterCore

@MainActor
final class DockIconTests: XCTestCase {

    // MARK: - InMemoryDockIconController (the test double itself)

    func test_inMemory_defaultsToHidden() {
        let dock = InMemoryDockIconController()
        XCTAssertFalse(dock.isVisible)
        XCTAssertNil(dock.badge)
    }

    func test_inMemory_setVisibleTrue_flipsState_andRecordsCall() {
        let dock = InMemoryDockIconController()
        dock.setVisible(true)
        XCTAssertTrue(dock.isVisible)
        XCTAssertEqual(dock.setVisibleCalls, [true])
    }

    func test_inMemory_setBadgeWhileHidden_recordsCall_butDoesNotStamp() {
        // Production semantics: writes to the badge when the icon is
        // hidden are no-ops (the badge is invisible anyway). The test
        // double mirrors this — call is recorded for assertion, but the
        // visible badge remains nil.
        let dock = InMemoryDockIconController()
        dock.setBadge("$12.34")
        XCTAssertNil(dock.badge)
        XCTAssertEqual(dock.setBadgeCalls, ["$12.34"])
    }

    func test_inMemory_setBadgeWhileVisible_appliesText() {
        let dock = InMemoryDockIconController(initiallyVisible: true)
        dock.setBadge("$12.34")
        XCTAssertEqual(dock.badge, "$12.34")
        XCTAssertEqual(dock.setBadgeCalls, ["$12.34"])
    }

    func test_inMemory_setVisibleFalse_clearsBadge() {
        let dock = InMemoryDockIconController(initiallyVisible: true)
        dock.setBadge("$5")
        XCTAssertEqual(dock.badge, "$5")

        dock.setVisible(false)
        XCTAssertNil(dock.badge)
        XCTAssertFalse(dock.isVisible)
    }

    func test_inMemory_setBadgeNilExplicit_clearsBadge() {
        let dock = InMemoryDockIconController(initiallyVisible: true)
        dock.setBadge("$5")
        dock.setBadge(nil)
        XCTAssertNil(dock.badge)
        // Both calls are recorded.
        XCTAssertEqual(dock.setBadgeCalls.count, 2)
        XCTAssertEqual(dock.setBadgeCalls[0], "$5")
        XCTAssertNil(dock.setBadgeCalls[1])
    }

    // MARK: - formatUSDWhole

    func test_formatUSDWhole_zeroAndDecimals() {
        XCTAssertEqual(formatUSDWhole(0), "$0")
        XCTAssertEqual(formatUSDWhole(0.49), "$0")
        // printf %.0f rounds ties to even — 0.50 → 0, 1.50 → 2.
        XCTAssertEqual(formatUSDWhole(0.50), "$0")
        XCTAssertEqual(formatUSDWhole(1.50), "$2")
    }

    func test_formatUSDWhole_typicalSpend() {
        XCTAssertEqual(formatUSDWhole(34.87), "$35")
        XCTAssertEqual(formatUSDWhole(123.45), "$123")
        XCTAssertEqual(formatUSDWhole(1234.56), "$1235")
    }

    func test_formatUSDWhole_neverEmitsDecimalPoint() {
        // Regression guard: any input value, whole or fractional,
        // produces a string with no '.' — the whole point of the helper.
        for v in [0.0, 0.01, 0.5, 1.0, 9.99, 50.0, 100.0, 999.99, 1234.56] {
            XCTAssertFalse(formatUSDWhole(v).contains("."),
                           "formatUSDWhole(\(v)) should not contain a decimal point")
        }
    }

    // MARK: - NSAppDockIconController (smoke test only)

    /// Verify the production type can be instantiated without crashing.
    /// We don't actually flip the activation policy on the test runner
    /// — that would steal focus and add a dock icon for `xctest`, which
    /// is jarring for anyone running `swift test` locally. We just
    /// confirm the constructor and property accessor work.
    func test_nsApp_instantiates_andStartsHidden() {
        let dock = NSAppDockIconController()
        XCTAssertFalse(dock.isVisible)
    }
}
