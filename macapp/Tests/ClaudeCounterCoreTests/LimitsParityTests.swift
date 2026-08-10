import XCTest
@testable import ClaudeCounterCore

/// Reads the same fixture bytes as `tui/internal/limits/parity_test.go`.
/// If these two suites ever disagree, the TUI and the menu bar app are
/// showing different numbers for the same spend — which is exactly the
/// drift this file exists to prevent.
final class LimitsParityTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Day: Decodable { let day: String; let usd: Double }
        struct Expect: Decodable {
            let window: String
            let spentUSD: Double
            let pct: Double
            let state: String
        }
        struct Case: Decodable {
            let name: String
            let now: String
            let dailyLimit: Double
            let weeklyLimit: Double
            let warnPct: Int
            let daily: [Day]
            let expect: [Expect]
        }
        let cases: [Case]
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func test_parityFixture() throws {
        guard let url = Bundle.module.url(forResource: "limits_parity",
                                          withExtension: "json",
                                          subdirectory: "Fixtures") else {
            return XCTFail("parity fixture not found in test bundle")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.cases.isEmpty, "parity fixture has no cases")

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")!

        for c in fixture.cases {
            guard let now = iso.date(from: c.now) else {
                XCTFail("\(c.name): bad now")
                continue
            }
            let daily = c.daily.map { DailyTotal(day: $0.day, usd: $0.usd, tokens: 0) }
            let got = Limits.evaluate(daily: daily,
                                      config: LimitsConfig(daily: c.dailyLimit,
                                                           weekly: c.weeklyLimit,
                                                           warnPct: c.warnPct),
                                      now: now,
                                      calendar: utc)

            XCTAssertEqual(got.count, c.expect.count, "\(c.name): status count")
            for (i, want) in c.expect.enumerated() where i < got.count {
                let g = got[i]
                XCTAssertEqual(g.window.rawValue, want.window, "\(c.name)[\(i)]: window")
                XCTAssertEqual(g.spentUSD, want.spentUSD, accuracy: 0.0001, "\(c.name)[\(i)]: spentUSD")
                XCTAssertEqual(g.pct, want.pct, accuracy: 0.0001, "\(c.name)[\(i)]: pct")
                XCTAssertEqual(g.state.rawValue, want.state, "\(c.name)[\(i)]: state")
            }
        }
    }
}
