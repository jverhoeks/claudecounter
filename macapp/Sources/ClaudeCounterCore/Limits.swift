import Foundation

/// Mirrors `tui/internal/limits` in Go. The two implementations are
/// independent but their behaviour is pinned together by the shared
/// parity fixture — see `LimitsParityTests`.
public struct LimitsConfig: Equatable, Sendable {
    public static let defaultWarnPct = 80

    public var daily: Double
    public var weekly: Double
    public var warnPct: Int

    public init(daily: Double = 0, weekly: Double = 0, warnPct: Int = LimitsConfig.defaultWarnPct) {
        self.daily = daily
        self.weekly = weekly
        self.warnPct = warnPct <= 0 ? LimitsConfig.defaultWarnPct : warnPct
    }
}

public enum LimitWindow: String, Sendable {
    case day, week
    /// Matches Go's `Window.String()` so rendered labels agree.
    public var label: String { self == .week ? "wk" : "daily" }
}

/// Raw values match Go's `State.String()` exactly — the parity fixture
/// compares them as strings.
public enum LimitState: String, Sendable {
    case unset, ok, warn, over
}

public struct LimitStatus: Equatable, Sendable {
    public var window: LimitWindow
    public var spentUSD: Double
    public var limitUSD: Double
    public var pct: Double
    public var state: LimitState
    public var resetsAt: Date
}

public enum Limits {

    public static func defaultConfigPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/claudecounter/limits.toml")
    }

    /// Reads limits.toml. A missing file yields zero limits and no error:
    /// that is the normal unconfigured state. Malformed content throws so
    /// the caller can surface it once.
    public static func load(path: String) throws -> LimitsConfig {
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            return LimitsConfig(daily: 0, weekly: 0)
        }
        var daily = 0.0, weekly = 0.0, warn = 0
        var inSection = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw LimitsError.malformed(line) }
                inSection = (line == "[limits]")
                continue
            }
            guard inSection else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[1].isEmpty else {
                throw LimitsError.malformed(line)
            }
            switch parts[0] {
            case "daily":
                guard let v = Double(parts[1]) else { throw LimitsError.malformed(line) }
                daily = v
            case "weekly":
                guard let v = Double(parts[1]) else { throw LimitsError.malformed(line) }
                weekly = v
            case "warn_pct":
                guard let v = Int(parts[1]) else { throw LimitsError.malformed(line) }
                warn = v
            default:
                continue
            }
        }
        return LimitsConfig(daily: daily, weekly: weekly, warnPct: warn)
    }

    /// Pure evaluation, always returning exactly two statuses, day first.
    public static func evaluate(daily: [DailyTotal],
                                config: LimitsConfig,
                                now: Date,
                                calendar callerCalendar: Calendar) -> [LimitStatus] {
        // Force ISO week semantics (Monday-first, ISO identifier)
        // regardless of what the caller passes: week grouping below and
        // the week-reset countdown in nextWeekStart both read `.weekOfYear`
        // off this same calendar, so normalising once here is what keeps
        // them from silently disagreeing with each other. Only the time
        // zone stays caller-controlled — DailyTotal.day is a local
        // calendar day, so tests (and production) must be able to pin it.
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = callerCalendar.timeZone
        calendar.firstWeekday = 2

        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"

        let todayKey = f.string(from: now)
        let nowWeek = calendar.component(.weekOfYear, from: now)
        let nowYear = calendar.component(.yearForWeekOfYear, from: now)

        var daySpent = 0.0, weekSpent = 0.0
        for d in daily {
            if d.day == todayKey { daySpent += d.usd }
            guard let t = parseDay(d.day, formatter: f) else { continue }
            // Compare ISO week AND the ISO week-year: a week straddling
            // 31 Dec belongs to one bucket, not two.
            if calendar.component(.weekOfYear, from: t) == nowWeek,
               calendar.component(.yearForWeekOfYear, from: t) == nowYear {
                weekSpent += d.usd
            }
        }

        return [
            build(.day, daySpent, config.daily, config.warnPct, nextMidnight(now, calendar)),
            build(.week, weekSpent, config.weekly, config.warnPct, nextWeekStart(now, calendar)),
        ]
    }

    /// Parses a day key the way Go's `time.ParseInLocation("2006-01-02", ...)`
    /// does: exactly four-digit year / two-digit month / two-digit day, and
    /// no rollover of an out-of-range day (so "2026-02-30" is rejected, not
    /// silently normalised to March 2). DateFormatter's own parsing is
    /// lenient about both; round-tripping the parsed date back through the
    /// same formatter and requiring an exact string match closes both gaps.
    private static func parseDay(_ s: String, formatter: DateFormatter) -> Date? {
        guard let d = formatter.date(from: s), formatter.string(from: d) == s else { return nil }
        return d
    }

    private static func build(_ window: LimitWindow,
                              _ spent: Double,
                              _ limit: Double,
                              _ warnPct: Int,
                              _ resets: Date) -> LimitStatus {
        guard limit > 0 else {
            return LimitStatus(window: window, spentUSD: spent, limitUSD: limit,
                               pct: 0, state: .unset, resetsAt: resets)
        }
        let pct = 100 * spent / limit
        let state: LimitState = pct >= 100 ? .over : (pct >= Double(warnPct) ? .warn : .ok)
        return LimitStatus(window: window, spentUSD: spent, limitUSD: limit,
                           pct: pct, state: state, resetsAt: resets)
    }

    private static func nextMidnight(_ now: Date, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now
    }

    /// `cal` must already be normalised to Monday-first ISO week rules
    /// (see `evaluate`) — this does not re-force `firstWeekday` itself, so
    /// that grouping and the reset countdown always agree.
    private static func nextWeekStart(_ now: Date, _ cal: Calendar) -> Date {
        let startOfWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: 7, to: startOfWeek) ?? now
    }
}

public enum LimitsError: Error, Equatable {
    case malformed(String)
}
