import XCTest
@testable import ClaudeCounterCore

final class LimitsTests: XCTestCase {

    // Pin the calendar to UTC + ISO-8601 so week boundaries are
    // deterministic and match the Go implementation.
    private var utc: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: s)!
    }

    private var week: [DailyTotal] {
        [
            DailyTotal(day: "2026-08-03", usd: 10, tokens: 0),
            DailyTotal(day: "2026-08-06", usd: 20, tokens: 0),
            DailyTotal(day: "2026-08-07", usd: 39, tokens: 0),
            DailyTotal(day: "2026-08-02", usd: 99, tokens: 0), // previous ISO week
        ]
    }

    func test_evaluate_dayUsesCalendarDay() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[0].window, .day)
        XCTAssertEqual(got[0].spentUSD, 39, accuracy: 0.0001)
        XCTAssertEqual(got[0].pct, 78, accuracy: 0.0001)
        XCTAssertEqual(got[0].state, .ok)
    }

    func test_evaluate_weekExcludesPreviousISOWeek() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[1].spentUSD, 69, accuracy: 0.0001)
    }

    func test_evaluate_exactlyAtLimitIsOver() {
        let got = Limits.evaluate(daily: [DailyTotal(day: "2026-08-07", usd: 50, tokens: 0)],
                                  config: LimitsConfig(daily: 50, weekly: 0, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[0].state, .over)
    }

    func test_evaluate_unsetLimitYieldsNoPercentage() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 0, weekly: 250, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[0].state, .unset)
        XCTAssertEqual(got[0].pct, 0, accuracy: 0.0001)
        XCTAssertNotEqual(got[1].state, .unset)
    }

    func test_evaluate_dayResetsAt_isNextMidnight() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[0].resetsAt, date("2026-08-08T00:00:00Z"))
    }

    // Go's nextMonday derives "next Monday" from today's weekday with a
    // wraparound special case when today IS Monday. Pin both edges so a
    // Swift-side dateInterval bug can't hide behind mid-week-only tests.
    func test_evaluate_weekResetsAt_fromMonday_isNextMonday() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: date("2026-08-03T00:00:00Z"), // Monday
                                  calendar: utc)
        XCTAssertEqual(got[1].resetsAt, date("2026-08-10T00:00:00Z"))
    }

    func test_evaluate_weekResetsAt_fromSunday_isNextMonday() {
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: date("2026-08-09T23:00:00Z"), // Sunday
                                  calendar: utc)
        XCTAssertEqual(got[1].resetsAt, date("2026-08-10T00:00:00Z"))
    }

    func test_load_missingFileIsNotAnError() throws {
        let path = NSTemporaryDirectory() + "/absent-\(UUID().uuidString).toml"
        let cfg = try Limits.load(path: path)
        XCTAssertEqual(cfg.daily, 0)
        XCTAssertEqual(cfg.weekly, 0)
    }

    func test_load_parsesLimitsAndDefaultsWarnPct() throws {
        let path = NSTemporaryDirectory() + "/limits-\(UUID().uuidString).toml"
        try "[limits]\ndaily = 50.0\nweekly = 250.0\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = try Limits.load(path: path)
        XCTAssertEqual(cfg.daily, 50)
        XCTAssertEqual(cfg.weekly, 250)
        XCTAssertEqual(cfg.warnPct, LimitsConfig.defaultWarnPct)
    }
}
