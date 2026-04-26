import Foundation

// MARK: - Token totals

/// Per-cell token bucket. UInt64 end-to-end so accumulation across
/// thousands of events stays exact.
public struct TokenCounts: Equatable, Hashable, Sendable, Codable {
    public var input: UInt64
    public var output: UInt64
    public var cacheCreate: UInt64
    public var cacheRead: UInt64

    public init(input: UInt64 = 0, output: UInt64 = 0,
                cacheCreate: UInt64 = 0, cacheRead: UInt64 = 0) {
        self.input = input
        self.output = output
        self.cacheCreate = cacheCreate
        self.cacheRead = cacheRead
    }

    public static let zero = TokenCounts()

    public func adding(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: input &+ other.input,
            output: output &+ other.output,
            cacheCreate: cacheCreate &+ other.cacheCreate,
            cacheRead: cacheRead &+ other.cacheRead
        )
    }

    public func adding(_ usage: Usage) -> TokenCounts {
        TokenCounts(
            input: input &+ usage.input,
            output: output &+ usage.output,
            cacheCreate: cacheCreate &+ usage.cacheCreate,
            cacheRead: cacheRead &+ usage.cacheRead
        )
    }

    public func toUsage() -> Usage {
        Usage(input: input, output: output, cacheCreate: cacheCreate, cacheRead: cacheRead)
    }
}

// MARK: - Snapshot view types

public struct ModelDay: Equatable, Sendable {
    public var usd: Double
    public var tokens: TokenCounts
    public init(usd: Double, tokens: TokenCounts) {
        self.usd = usd; self.tokens = tokens
    }
}

public struct ProjectDay: Equatable, Sendable {
    public var main: TokenCounts
    public var sub: TokenCounts
    public var mainUSD: Double
    public var subUSD: Double

    public init(main: TokenCounts = .zero, sub: TokenCounts = .zero,
                mainUSD: Double = 0, subUSD: Double = 0) {
        self.main = main; self.sub = sub
        self.mainUSD = mainUSD; self.subUSD = subUSD
    }
    public var totalUSD: Double { mainUSD + subUSD }
    public var totalTokens: TokenCounts { main.adding(sub) }
}

public struct DailyTotal: Equatable, Sendable {
    public var day: String   // YYYY-MM-DD in local TZ
    public var usd: Double
    public init(day: String, usd: Double) { self.day = day; self.usd = usd }
}

public struct Totals: Equatable, Sendable {
    public var day: [String: ModelDay] = [:]
    public var month: [String: ModelDay] = [:]
    public var dayProj: [String: ProjectDay] = [:]
    public var monthProj: [String: ProjectDay] = [:]
    public var daily: [DailyTotal] = []
    public var todayHourly: [TokenCounts] = Array(repeating: .zero, count: 24)
    public var todayHourlyUSD: [Double] = Array(repeating: 0, count: 24)
    public var unknown: Int = 0
    public var dupes: Int = 0
    public var asOf: Date = .distantPast

    public init() {}
}

// MARK: - Civil day key (local timezone)

public struct CivilDay: Hashable, Sendable, Codable {
    public let year: Int
    public let month: Int
    public let day: Int
    public init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }
}

@inline(__always)
func dayOf(_ date: Date, calendar: Calendar = .current) -> CivilDay {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return CivilDay(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0)
}

@inline(__always)
func hourOf(_ date: Date, calendar: Calendar = .current) -> Int {
    calendar.component(.hour, from: date)
}

@inline(__always)
func civilDayString(_ d: CivilDay) -> String {
    String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
}

// MARK: - Aggregator (port of internal/agg.Aggregator)

public actor Aggregator {

    /// Storage cell: a (day, project, model, isSub) bucket of token counts.
    /// Cost is derived from these at snapshot time.
    public struct CellKey: Hashable, Sendable, Codable {
        public let day: CivilDay
        public let project: String
        public let model: String
        public let isSub: Bool
    }

    /// How many trailing days `Snapshot` fills into `daily`.
    public static let dailyWindow = 30

    private var pricing: PricingTable
    private var cells: [CellKey: TokenCounts] = [:]
    private var perMsg: Set<String> = []
    private var unknownMsgs: Set<String> = []
    private(set) public var dupes: Int = 0

    /// Per-hour tokens for events that fall on `today` only. Stored
    /// separately from `cells` because cells are keyed by day, not hour.
    private struct HourBucketKey: Hashable {
        let hour: Int
        let model: String
    }
    private var hourBuckets: [HourBucketKey: TokenCounts] = [:]
    private var hourBucketsDay: CivilDay? = nil

    private let now: () -> Date
    private let calendar: Calendar

    public init(pricing: PricingTable, now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.pricing = pricing
        self.now = now
        self.calendar = calendar
    }

    public func setPricing(_ table: PricingTable) {
        self.pricing = table
    }

    /// Replace internal state from a previously-persisted cache.
    public func load(cells: [CellKey: TokenCounts], perMsg: Set<String>,
                     unknownMsgs: Set<String>, dupes: Int) {
        self.cells = cells
        self.perMsg = perMsg
        self.unknownMsgs = unknownMsgs
        self.dupes = dupes
        // Hour buckets are derived from cells only for *today*; we don't
        // persist them. They rebuild as new events arrive after restart.
        self.hourBuckets.removeAll(keepingCapacity: false)
        self.hourBucketsDay = nil
    }

    public func exportState() -> (cells: [CellKey: TokenCounts],
                                  perMsg: Set<String>,
                                  unknownMsgs: Set<String>,
                                  dupes: Int) {
        (cells, perMsg, unknownMsgs, dupes)
    }

    public func reset() {
        cells.removeAll(keepingCapacity: true)
        perMsg.removeAll(keepingCapacity: true)
        unknownMsgs.removeAll(keepingCapacity: true)
        hourBuckets.removeAll(keepingCapacity: true)
        hourBucketsDay = nil
        dupes = 0
    }

    /// Record an event's contribution. Dedupe rule mirrors ccusage:
    /// the unique key is `messageID:requestID`; if either is missing the
    /// event is always counted (no dedup); first-seen wins.
    public func apply(_ e: UsageEvent) {
        // 1) Dedupe.
        if !e.messageID.isEmpty && !e.requestID.isEmpty {
            let key = e.messageID + ":" + e.requestID
            if perMsg.contains(key) {
                dupes += 1
                return
            }
            perMsg.insert(key)
        }

        // 2) Track unknowns for diagnostics (still bucket the tokens).
        if !pricing.has(model: e.model) {
            let uid = !e.messageID.isEmpty ? e.messageID : "\(e.model):\(e.timestamp)"
            unknownMsgs.insert(uid)
        }

        // 3) Bucket tokens into the day/project/model/isSub cell.
        let cellKey = CellKey(
            day: dayOf(e.timestamp, calendar: calendar),
            project: e.project,
            model: e.model,
            isSub: e.isSubagent
        )
        let current = cells[cellKey] ?? .zero
        cells[cellKey] = current.adding(e.usage)

        // 4) If the event is on the wall-clock today, also accumulate into
        //    today's hourly buckets. Day-rollover is detected lazily.
        let today = dayOf(now(), calendar: calendar)
        let evDay = cellKey.day
        if evDay == today {
            if hourBucketsDay != today {
                hourBuckets.removeAll(keepingCapacity: true)
                hourBucketsDay = today
            }
            let hour = hourOf(e.timestamp, calendar: calendar)
            let hk = HourBucketKey(hour: hour, model: e.model)
            hourBuckets[hk, default: .zero] = (hourBuckets[hk] ?? .zero).adding(e.usage)
        }
    }

    /// Compute per-model and per-project totals for today and this month
    /// from the accumulated token cells. Costs are computed once per
    /// (model, scope) by summing tokens first then applying pricing — this
    /// avoids float accumulation drift over thousands of events.
    public func snapshot() -> Totals {
        let nowLocal = now()
        let today = dayOf(nowLocal, calendar: calendar)
        let nowMonth = today.month
        let nowYear = today.year

        var out = Totals()
        out.asOf = nowLocal
        out.dupes = dupes
        out.unknown = unknownMsgs.count

        // Aggregate per-(scope, model) tokens.
        struct ModelScope: Hashable { let scope: String; let model: String }
        var modelTok: [ModelScope: TokenCounts] = [:]

        // Aggregate per-(scope, project, isSub, model) tokens. Model must
        // be preserved for per-project costing because a project may use
        // multiple models with different prices.
        struct ProjScopeModel: Hashable {
            let scope: String; let project: String; let isSub: Bool; let model: String
        }
        var projModelTok: [ProjScopeModel: TokenCounts] = [:]

        // Per-day-per-model for the daily window.
        struct DayModel: Hashable { let day: CivilDay; let model: String }
        var byDM: [DayModel: TokenCounts] = [:]

        for (k, t) in cells {
            // Day scope.
            if k.day == today {
                modelTok[ModelScope(scope: "day", model: k.model), default: .zero] =
                    (modelTok[ModelScope(scope: "day", model: k.model)] ?? .zero).adding(t)
                let pk = ProjScopeModel(scope: "day", project: k.project, isSub: k.isSub, model: k.model)
                projModelTok[pk, default: .zero] = (projModelTok[pk] ?? .zero).adding(t)
            }
            // Month scope.
            if k.day.year == nowYear && k.day.month == nowMonth {
                modelTok[ModelScope(scope: "month", model: k.model), default: .zero] =
                    (modelTok[ModelScope(scope: "month", model: k.model)] ?? .zero).adding(t)
                let pk = ProjScopeModel(scope: "month", project: k.project, isSub: k.isSub, model: k.model)
                projModelTok[pk, default: .zero] = (projModelTok[pk] ?? .zero).adding(t)
            }
            // Daily window (all days, only those in the last 30-day window
            // are shown — the slice below filters).
            byDM[DayModel(day: k.day, model: k.model), default: .zero] =
                (byDM[DayModel(day: k.day, model: k.model)] ?? .zero).adding(t)
        }

        // Apply pricing per (scope, model).
        for (mk, tok) in modelTok {
            let usd = pricing.has(model: mk.model)
                ? pricing.cost(model: mk.model, usage: tok.toUsage())
                : 0
            let md = ModelDay(usd: usd, tokens: tok)
            switch mk.scope {
            case "day":   out.day[mk.model] = md
            case "month": out.month[mk.model] = md
            default: break
            }
        }

        // Per-project: walk preserving model so cost is accurate when a
        // project uses multiple models with different prices.
        for (k, tok) in projModelTok {
            let usd = pricing.has(model: k.model)
                ? pricing.cost(model: k.model, usage: tok.toUsage())
                : 0
            switch k.scope {
            case "day":
                var pd = out.dayProj[k.project] ?? ProjectDay()
                if k.isSub { pd.sub = pd.sub.adding(tok); pd.subUSD += usd }
                else       { pd.main = pd.main.adding(tok); pd.mainUSD += usd }
                out.dayProj[k.project] = pd
            case "month":
                var pd = out.monthProj[k.project] ?? ProjectDay()
                if k.isSub { pd.sub = pd.sub.adding(tok); pd.subUSD += usd }
                else       { pd.main = pd.main.adding(tok); pd.mainUSD += usd }
                out.monthProj[k.project] = pd
            default:
                break
            }
        }

        // Daily window: last 30 days, oldest→newest.
        var dayCost: [CivilDay: Double] = [:]
        for (k, tok) in byDM where pricing.has(model: k.model) {
            dayCost[k.day, default: 0] += pricing.cost(model: k.model, usage: tok.toUsage())
        }
        out.daily = (0..<Self.dailyWindow).reversed().map { i in
            let date = calendar.date(byAdding: .day, value: -i, to: nowLocal) ?? nowLocal
            let cd = dayOf(date, calendar: calendar)
            return DailyTotal(day: civilDayString(cd), usd: dayCost[cd] ?? 0)
        }

        // Today hourly: tokens per hour, plus per-hour USD by walking the
        // (hour, model) buckets and applying pricing. Empty when the
        // stored hour-bucket day has rolled over (rebuilds as new events
        // arrive after the rollover).
        var hourly = Array(repeating: TokenCounts.zero, count: 24)
        var hourlyUSD = Array(repeating: 0.0, count: 24)
        if hourBucketsDay == today {
            for (hk, t) in hourBuckets {
                hourly[hk.hour] = hourly[hk.hour].adding(t)
                if pricing.has(model: hk.model) {
                    hourlyUSD[hk.hour] += pricing.cost(model: hk.model, usage: t.toUsage())
                }
            }
        }
        out.todayHourly = hourly
        out.todayHourlyUSD = hourlyUSD

        return out
    }
}
