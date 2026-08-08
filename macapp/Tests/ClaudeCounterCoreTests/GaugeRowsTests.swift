import XCTest
@testable import ClaudeCounterCore

final class GaugeRowsTests: XCTestCase {

    private var statuses: [LimitStatus] {
        [
            LimitStatus(window: .day, spentUSD: 39, limitUSD: 50, pct: 78, state: .ok, resetsAt: Date()),
            LimitStatus(window: .week, spentUSD: 130, limitUSD: 250, pct: 52, state: .ok, resetsAt: Date()),
        ]
    }

    private var gauges: [PlanGauge] {
        [
            PlanGauge(vendor: "codex", windowLabel: "5h", pct: 92, resetsAt: Date().addingTimeInterval(7200),
                      observed: Date(), stale: false, plan: "plus"),
            PlanGauge(vendor: "codex", windowLabel: "7d", pct: 100, resetsAt: Date().addingTimeInterval(172800),
                      observed: Date(), stale: false, plan: "plus"),
            PlanGauge(vendor: "grok", windowLabel: "wk", pct: 14, resetsAt: Date().addingTimeInterval(21600),
                      observed: Date(), stale: false, plan: "SuperGrok"),
        ]
    }

    // Display order must match Go's exactly, or the popover and the TUI
    // disagree about which row is which.
    func test_build_fixedDisplayOrder() {
        let rows = GaugeRows.build(band: .short, statuses: statuses, gauges: gauges)
        XCTAssertEqual(rows.map(\.vendor), ["claude", "codex", "grok"])
    }

    func test_build_grokShortWindowIsNotApplicable() {
        let rows = GaugeRows.build(band: .short, statuses: statuses, gauges: gauges)
        XCTAssertEqual(rows.last?.vendor, "grok")
        XCTAssertNotNil(rows.last?.notApplicable)
        XCTAssertNil(rows.last?.plan)
    }

    func test_build_omitsVendorThatIsNotInstalled() {
        let onlyCodex = [gauges[0]]
        let rows = GaugeRows.build(band: .short, statuses: statuses, gauges: onlyCodex)
        XCTAssertEqual(rows.map(\.vendor), ["claude", "codex"])
    }

    func test_build_omitsUnsetBudget() {
        let unset = [
            LimitStatus(window: .day, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: Date()),
            LimitStatus(window: .week, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: Date()),
        ]
        let rows = GaugeRows.build(band: .short, statuses: unset, gauges: gauges)
        XCTAssertEqual(rows.map(\.vendor), ["codex", "grok"])
    }

    // A stale 100% must never drive the menu bar red.
    func test_worstPct_ignoresStaleRows() {
        let stale = [
            PlanGauge(vendor: "codex", windowLabel: "7d", pct: 100, resetsAt: Date(),
                      observed: Date(), stale: true, plan: "plus"),
            PlanGauge(vendor: "grok", windowLabel: "wk", pct: 14, resetsAt: Date().addingTimeInterval(3600),
                      observed: Date(), stale: false, plan: "SuperGrok"),
        ]
        XCTAssertEqual(GaugeRows.worstPct(statuses: statuses, gauges: stale), 78, accuracy: 0.0001)
    }

    // The no-config/no-vendors case: this must degrade to "no rows", not
    // a crash, and must never make the menu bar look alarmed. This is the
    // baseline every user with no limits.toml and no Codex/Grok installed
    // sees today, and it must look exactly the same after this change.
    func test_build_and_worstPct_withNoConfigAndNoVendors() {
        let unset = [
            LimitStatus(window: .day, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: Date()),
            LimitStatus(window: .week, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: Date()),
        ]
        XCTAssertEqual(GaugeRows.build(band: .short, statuses: unset, gauges: []), [])
        XCTAssertEqual(GaugeRows.build(band: .weekly, statuses: unset, gauges: []), [])
        XCTAssertEqual(GaugeRows.worstPct(statuses: unset, gauges: []), 0, accuracy: 0.0001)
    }
}
