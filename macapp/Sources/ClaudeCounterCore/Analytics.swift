import Foundation

extension TokenCounts {
    /// Every token kind summed — the figure all token readouts show.
    public var total: UInt64 { input &+ output &+ cacheCreate &+ cacheRead }

    /// Share of prompt-side tokens served from cache. 0 when nothing
    /// was sent.
    public var cacheHitRate: Double {
        let prompt = input &+ cacheCreate &+ cacheRead
        return prompt == 0 ? 0 : Double(cacheRead) / Double(prompt)
    }
}

extension ModelDay {
    /// Tokens bought per dollar. nil for a $0 row (unpriced or all
    /// free) rather than infinity.
    public var tokensPerUSD: Double? { usd > 0 ? Double(tokens.total) / usd : nil }
}

/// Pure helpers behind the dashboard window. Lives in Core so the test
/// target can reach it.
public enum Analytics {

    /// `count` consecutive civil days ending at `end`, oldest first, as
    /// the YYYY-MM-DD keys `Totals.history` uses. Gap-filled, so a line
    /// chart drops to zero on idle days instead of interpolating across.
    public static func days(ending end: Date, count: Int, calendar: Calendar = .current) -> [String] {
        (0..<max(count, 0)).reversed().map { i in
            civilDayString(dayOf(calendar.date(byAdding: .day, value: -i, to: end) ?? end,
                                 calendar: calendar))
        }
    }

    /// The dashboard's grouping axis: `GroupMode`'s four plus the two
    /// cuts only the history carries.
    public enum Dimension: String, CaseIterable, Sendable {
        case model, vendor, source, project, agent, total
    }

    /// Day → series name → value under `dim`. Every dimension partitions
    /// the same cells, so all six sum to the same total per day.
    public static func grouped(_ t: Totals, by dim: Dimension) -> [String: [String: ModelDay]] {
        func md(_ usd: Double, _ tok: TokenCounts) -> ModelDay { ModelDay(usd: usd, tokens: tok) }
        switch dim {
        case .model:  return t.history.mapValues { Grouping.group($0, by: .model) }
        case .vendor: return t.history.mapValues { Grouping.group($0, by: .vendor) }
        case .source: return t.history.mapValues { Grouping.group($0, by: .source) }
        case .total:  return t.history.mapValues { Grouping.group($0, by: .total) }
        case .project:
            return t.projectHistory.mapValues { day in
                var out: [String: ModelDay] = [:]
                for (p, v) in day {
                    let name = shortProjectName(p)
                    let cur = out[name] ?? md(0, .zero)
                    out[name] = md(cur.usd + v.totalUSD, cur.tokens.adding(v.totalTokens))
                }
                return out
            }
        case .agent:
            return t.projectHistory.mapValues { day in
                var main = md(0, .zero), sub = md(0, .zero)
                for v in day.values {
                    main = md(main.usd + v.mainUSD, main.tokens.adding(v.main))
                    sub = md(sub.usd + v.subUSD, sub.tokens.adding(v.sub))
                }
                return ["main": main, "subagent": sub]
            }
        }
    }

    /// Per-series values aligned with `days` (zero where idle), largest
    /// spender first. Series past `top` fold into one "other" line so a
    /// long project tail doesn't turn the chart into noise.
    public static func series(_ grouped: [String: [String: ModelDay]], days: [String],
                              top: Int = 8) -> [(name: String, values: [ModelDay])] {
        let empty = ModelDay(usd: 0, tokens: .zero)
        let ranked = sum(grouped, days: days).sorted {
            $0.value.usd == $1.value.usd ? $0.key < $1.key : $0.value.usd > $1.value.usd
        }.map(\.key)
        let kept = Set(ranked.prefix(top))
        var out: [String: [ModelDay]] = [:]
        for (i, day) in days.enumerated() {
            for (name, v) in grouped[day] ?? [:] {
                let n = kept.contains(name) ? name : "other"
                var vals = out[n] ?? Array(repeating: empty, count: days.count)
                vals[i] = ModelDay(usd: vals[i].usd + v.usd, tokens: vals[i].tokens.adding(v.tokens))
                out[n] = vals
            }
        }
        let order = ranked.prefix(top) + ["other"]
        return order.compactMap { n in out[n].map { (n, $0) } }
    }

    /// Totals over `days`, per series name.
    public static func sum(_ grouped: [String: [String: ModelDay]],
                           days: [String]) -> [String: ModelDay] {
        var out: [String: ModelDay] = [:]
        for day in days {
            for (k, v) in grouped[day] ?? [:] {
                let cur = out[k] ?? ModelDay(usd: 0, tokens: .zero)
                out[k] = ModelDay(usd: cur.usd + v.usd, tokens: cur.tokens.adding(v.tokens))
            }
        }
        return out
    }

    /// Model-row coverage over `days`, via the same worst-vendor rule
    /// the popover's table uses. Empty for every other dimension.
    public static func coverage(_ t: Totals, days: [String], by dim: Dimension) -> [String: Coverage] {
        guard dim == .model else { return [:] }
        var perVendor: [String: Coverage] = [:]
        var keys: [SeriesKey: ModelDay] = [:]
        for day in days {
            for (v, c) in t.coverageHistory[day] ?? [:] {
                var cur = perVendor[v] ?? Coverage()
                cur.turns += c.turns; cur.withUsage += c.withUsage
                perVendor[v] = cur
            }
            for k in (t.history[day] ?? [:]).keys { keys[k] = ModelDay(usd: 0, tokens: .zero) }
        }
        return Grouping.groupCoverage(keys, coverage: perVendor, by: .model)
    }

    /// Spend by weekday (0 = Monday) × local hour over the `daily`
    /// window — which is 30 days, the depth hourly data is kept for.
    /// `model` restricts it to one model's spend; nil sums them all.
    public static func heatmap(_ daily: [DailyTotal], model: String? = nil,
                               calendar: Calendar = .current) -> [[Double]] {
        var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd"
        for d in daily {
            guard let date = fmt.date(from: d.day) else { continue }
            let wd = (calendar.component(.weekday, from: date) + 5) % 7 // Sun=1 → 6
            for (h, byModel) in d.hourlyUSDByModel.enumerated() where h < 24 {
                grid[wd][h] += model.map { byModel[$0] ?? 0 } ?? byModel.values.reduce(0, +)
            }
        }
        return grid
    }

    /// Tail of Claude's dash-encoded project dir
    /// ("-Users-me-src-foo-bar" → "foo-bar"). Mirrors the Go TUI's
    /// shortProject helper.
    public static func shortProjectName(_ encoded: String) -> String {
        if encoded.isEmpty { return "(unknown)" }
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-")
        if parts.count <= 4 { return trimmed }
        return parts.dropFirst(4).joined(separator: "-")
    }

    /// A monthly fee prorated onto `period`, on a 365-day year so the
    /// three periods agree (a month is 1/12 of the year, a week 7/365).
    public static func proratedFee(monthly: Double, period: PeriodMode) -> Double {
        switch period {
        case .day:   return monthly * 12 / 365
        case .week:  return monthly * 12 * 7 / 365
        case .month: return monthly
        }
    }

    /// Month-to-date spend run forward at its daily average to the end
    /// of the month. Today counts as a full day, so this runs low early
    /// in the day.
    public static func projectedMonth(monthToDate: Double, now: Date,
                                      calendar: Calendar = .current) -> Double {
        let elapsed = calendar.component(.day, from: now)
        let length = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        return monthToDate / Double(max(elapsed, 1)) * Double(length)
    }
}
