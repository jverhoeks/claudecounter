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

    func test_evaluate_pctBetweenWarnAndOverIsWarn() {
        // weekSpent is 69 against a limit of 100 -> 69%, comfortably above
        // an 60 warnPct threshold and below 100 -> must be .warn, not .ok
        // or .over. This is the only place config.warnPct is read at all,
        // so it needs its own case rather than riding along with .ok/.over.
        let got = Limits.evaluate(daily: week,
                                  config: LimitsConfig(daily: 50, weekly: 100, warnPct: 60),
                                  now: date("2026-08-07T12:00:00Z"),
                                  calendar: utc)
        XCTAssertEqual(got[1].pct, 69, accuracy: 0.0001)
        XCTAssertEqual(got[1].state, .warn)
    }

    func test_evaluate_dayKeyParsing_rejectsFormatsGoRejects() {
        // Go's time.ParseInLocation("2006-01-02", ...) requires exactly
        // two digits for month and day; DateFormatter's own parsing is
        // lenient about missing leading zeros, so week grouping must
        // reject these the same way Go does or the two apps bucket the
        // same spend differently.
        let now = date("2026-08-07T12:00:00Z") // Friday, ISO week Aug 3-9
        let daily = [
            DailyTotal(day: "2026-08-9", usd: 1000, tokens: 0),  // day not zero-padded
            DailyTotal(day: "2026-8-07", usd: 1000, tokens: 0),  // month not zero-padded
            DailyTotal(day: "garbage", usd: 1000, tokens: 0),    // unparseable
            DailyTotal(day: "2026-08-07", usd: 5, tokens: 0),    // the one valid entry
        ]
        let got = Limits.evaluate(daily: daily,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: now,
                                  calendar: utc)
        XCTAssertEqual(got[1].spentUSD, 5, accuracy: 0.0001)
    }

    func test_evaluate_dayKeyParsing_rejectsOutOfRangeDayRatherThanRollingOver() {
        // "2026-02-30" does not exist. Go rejects it outright; a naive
        // DateFormatter parse rolls it over into 2026-03-02, which would
        // then wrongly land in that date's ISO week.
        let now = date("2026-03-02T12:00:00Z") // Monday: the date Feb 30 would roll into
        let daily = [
            DailyTotal(day: "2026-02-30", usd: 1000, tokens: 0),
            DailyTotal(day: "2026-03-02", usd: 7, tokens: 0),
        ]
        let got = Limits.evaluate(daily: daily,
                                  config: LimitsConfig(daily: 50, weekly: 250, warnPct: 80),
                                  now: now,
                                  calendar: utc)
        XCTAssertEqual(got[1].spentUSD, 7, accuracy: 0.0001)
    }

    func test_evaluate_wrongCalendar_stillMatchesISOWeekResult() {
        // evaluate must normalise week semantics internally: a caller that
        // passes a Sunday-first Gregorian calendar (e.g. Calendar.current
        // in most US-locale environments) must get the exact same ISO-week
        // grouping and reset time as one that passes the correct calendar,
        // or the day/week totals would depend on the caller's locale.
        var wrong = Calendar(identifier: .gregorian)
        wrong.timeZone = TimeZone(identifier: "UTC")!
        wrong.firstWeekday = 1 // Sunday-first

        let now = date("2026-08-07T12:00:00Z")
        let config = LimitsConfig(daily: 50, weekly: 250, warnPct: 80)
        let expected = Limits.evaluate(daily: week, config: config, now: now, calendar: utc)
        let got = Limits.evaluate(daily: week, config: config, now: now, calendar: wrong)
        XCTAssertEqual(got, expected)
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

    // "[ limits ]" is valid TOML — whitespace inside the brackets is
    // permitted — but the old code compared the trimmed line against the
    // literal "[limits]", so this set inSection = false, left daily/
    // weekly at their zero default, and did NOT throw (the line still
    // passes the hasPrefix("[")/hasSuffix("]") guard). The macapp showed
    // no budget rows and no error while the TUI (a real TOML parser)
    // read the same file fine — see config_test.go's
    // TestLoadAcceptsSpacedTableHeader for the Go-side pin of the same
    // case (final-review.md M-1).
    func test_load_acceptsSpacedTableHeader() throws {
        let path = NSTemporaryDirectory() + "/limits-\(UUID().uuidString).toml"
        try "[ limits ]\ndaily = 50.0\nweekly = 250.0\nwarn_pct = 70\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = try Limits.load(path: path)
        XCTAssertEqual(cfg.daily, 50)
        XCTAssertEqual(cfg.weekly, 250)
        XCTAssertEqual(cfg.warnPct, 70)
    }

    // Leading/trailing spaces around a key or its value already work —
    // both halves of the "=" split are trimmed with .whitespaces before
    // being read. Pinned here so a future refactor of the split can't
    // silently drop that trim without a test catching it.
    func test_load_toleratesSpacesAroundKeyAndValue() throws {
        let path = NSTemporaryDirectory() + "/limits-\(UUID().uuidString).toml"
        try "[limits]\n  daily   =   50.0  \nweekly= 250.0\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = try Limits.load(path: path)
        XCTAssertEqual(cfg.daily, 50)
        XCTAssertEqual(cfg.weekly, 250)
    }

    // A CRLF limits.toml (e.g. saved by a Windows editor) leaves a
    // trailing "\r" on every line. Swift's Character is an extended
    // grapheme cluster: "\r\n" is a single Character equal to neither
    // "\n" nor "\r" alone, so splitting on "\n" leaves the trailing "\r"
    // intact. That turns "[ limits ]\r" into a hasSuffix("]") failure
    // (malformed) and a value line's trailing "\r" into a non-numeric
    // parse failure (also malformed), even though Go's TOML parser reads
    // the same bytes fine. Splitting on isNewline instead handles "\n",
    // "\r", and "\r\n" each as one line ending.
    func test_load_acceptsCRLFLineEndings() throws {
        let path = NSTemporaryDirectory() + "/limits-\(UUID().uuidString).toml"
        try "[ limits ]\r\ndaily = 50.0\r\nweekly = 250.0\r\nwarn_pct = 70\r\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cfg = try Limits.load(path: path)
        XCTAssertEqual(cfg.daily, 50)
        XCTAssertEqual(cfg.weekly, 250)
        XCTAssertEqual(cfg.warnPct, 70)
    }

    // "A malformed file throws" is an explicit constraint — a typo must
    // not be silently read as "no limits set". Cover the four ways a
    // limits.toml can be malformed.

    func test_load_unterminatedSectionHeaderThrows() throws {
        try assertLoadThrows("[limits\ndaily = 50.0\n")
    }

    func test_load_lineWithoutEqualsThrows() throws {
        try assertLoadThrows("[limits]\ndaily 50.0\n")
    }

    func test_load_emptyValueThrows() throws {
        try assertLoadThrows("[limits]\ndaily = \n")
    }

    func test_load_nonNumericValueThrows() throws {
        try assertLoadThrows("[limits]\ndaily = fifty\n")
    }

    private func assertLoadThrows(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let path = NSTemporaryDirectory() + "/limits-\(UUID().uuidString).toml"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try Limits.load(path: path), file: file, line: line)
    }
}
