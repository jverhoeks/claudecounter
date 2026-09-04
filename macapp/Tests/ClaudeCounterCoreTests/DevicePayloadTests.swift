import XCTest
@testable import ClaudeCounterCore

final class DevicePayloadTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_756_982_460) // 2025-09-04T10:41:00Z

    private func key(_ vendor: String, _ model: String) -> SeriesKey {
        SeriesKey(source: "\(vendor)/\(vendor)", vendor: vendor, model: model)
    }

    private var totals: Totals {
        var t = Totals()
        t.day = [
            key("claude", "claude-opus-5"): ModelDay(usd: 12.104, tokens: .zero),
            key("claude", "claude-sonnet-5"): ModelDay(usd: 6.3, tokens: .zero),
            key("codex", "gpt-5"): ModelDay(usd: 4.1, tokens: .zero),
        ]
        t.week = [
            key("claude", "claude-opus-5"): ModelDay(usd: 60, tokens: .zero),
            key("codex", "gpt-5"): ModelDay(usd: 22, tokens: .zero),
        ]
        t.month = [
            key("claude", "claude-opus-5"): ModelDay(usd: 201.3, tokens: .zero),
            key("claude", "claude-sonnet-5"): ModelDay(usd: 111.2, tokens: .zero),
            key("codex", "gpt-5"): ModelDay(usd: 61.2, tokens: .zero),
            key("grok", "grok-4"): ModelDay(usd: 12.7, tokens: .zero),
            key("grok", "grok-free"): ModelDay(usd: 0, tokens: .zero),
        ]
        return t
    }

    private var statuses: [LimitStatus] {
        [
            LimitStatus(window: .day, spentUSD: 18.4, limitUSD: 30, pct: 61.3, state: .ok, resetsAt: now),
            LimitStatus(window: .week, spentUSD: 0, limitUSD: 0, pct: 0, state: .unset, resetsAt: now),
        ]
    }

    private var gauges: [PlanGauge] {
        [
            PlanGauge(vendor: "grok", windowLabel: "wk", pct: 15.4, resetsAt: now, observed: now, stale: false, plan: ""),
            PlanGauge(vendor: "codex", windowLabel: "7d", pct: 48, resetsAt: now, observed: now, stale: true, plan: "plus"),
            PlanGauge(vendor: "codex", windowLabel: "5h", pct: 71, resetsAt: now, observed: now, stale: false, plan: "plus"),
        ]
    }

    private func session(_ id: String, project: String, pct: Double, warn: Bool) -> SessionStat {
        SessionStat(sessionID: id, project: project, model: "claude-opus-5",
                    costUSD: 1, cost5mUSD: 0, cacheCreate5mUSD: 0,
                    contextTokens: 0, contextWindow: 200_000, contextPct: pct,
                    cacheCreateCostUSD: 0, turns: 3, ageSeconds: 10,
                    warnings: warn ? [.context] : [])
    }

    func test_build_vendorSpendSumsAndRoundsToCents() {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.v, 1)
        XCTAssertEqual(p.at, "2025-09-04T10:41:00Z")
        XCTAssertEqual(p.spend["claude"], DevicePayload.Spend(day: 18.4, week: 60, month: 312.5))
        XCTAssertEqual(p.spend["codex"], DevicePayload.Spend(day: 4.1, week: 22, month: 61.2))
        XCTAssertEqual(p.spend["grok"], DevicePayload.Spend(day: 0, week: 0, month: 12.7))
    }

    func test_build_modelsSortedByMonthThenNameAndZeroDropped() {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.models.map(\.model), ["claude-opus-5", "claude-sonnet-5", "gpt-5", "grok-4"])
        XCTAssertEqual(p.models[0], DevicePayload.ModelSpend(vendor: "claude", model: "claude-opus-5",
                                                             day: 12.1, week: 60, month: 201.3))
        XCTAssertEqual(p.models[3].day, 0)
    }

    func test_build_modelsCappedAtTwenty() {
        var t = Totals()
        for i in 0..<25 {
            t.month[key("claude", String(format: "m-%02d", i))] = ModelDay(usd: Double(100 - i), tokens: .zero)
        }
        let p = DevicePayload.build(totals: t, statuses: [], gauges: [], sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.models.count, 20)
        XCTAssertEqual(p.models.first?.model, "m-00")
        XCTAssertEqual(p.models.last?.model, "m-19")
    }

    func test_build_usageFollowsGaugeRowsOrderAndSkipsUnsetBudget() {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertEqual(p.usage, [
            DevicePayload.Usage(vendor: "claude", window: "daily", pct: 61, stale: false),
            DevicePayload.Usage(vendor: "codex", window: "5h", pct: 71, stale: false),
            DevicePayload.Usage(vendor: "codex", window: "7d", pct: 48, stale: true),
            DevicePayload.Usage(vendor: "grok", window: "wk", pct: 15, stale: false),
        ])
        XCTAssertEqual(p.warnPct, 80)
    }

    func test_build_contextPicksHighestSessionAndShortensProject() {
        let sessions = [
            session("a", project: "-Users-me-src-tries-foo", pct: 0.42, warn: false),
            session("b", project: "-Users-me-src-tries-claudecounter", pct: 0.834, warn: true),
        ]
        let p = DevicePayload.build(totals: totals, statuses: [], gauges: [],
                                    sessions: sessions, warnPct: 80, now: now)
        XCTAssertEqual(p.context, DevicePayload.Context(session: "claudecounter", pct: 83, warn: true))
    }

    func test_build_contextNilWithoutSessions() {
        let p = DevicePayload.build(totals: totals, statuses: [], gauges: [],
                                    sessions: [], warnPct: 80, now: now)
        XCTAssertNil(p.context)
    }

    func test_encoded_isDeterministicAndCompact() throws {
        let p = DevicePayload.build(totals: totals, statuses: statuses, gauges: gauges,
                                    sessions: [], warnPct: 80, now: now)
        let a = try p.encoded()
        let b = try p.encoded()
        XCTAssertEqual(a, b)
        let s = String(decoding: a, as: UTF8.self)
        XCTAssertFalse(s.contains("\n"))
        XCTAssertTrue(s.hasPrefix("{\"at\":"), "keys must be sorted so byte equality means content equality")
        XCTAssertTrue(s.contains("\"context\":null"))
    }
}
