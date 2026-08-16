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

/// Identifies one chartable series. Source and vendor are both stored
/// rather than vendor being derived from source at snapshot time: the
/// macapp persists cells between runs, so a label removed from the
/// config would otherwise leave its cached cells unattributable. Mirrors
/// `agg.SeriesKey` in `tui/internal/agg/agg.go`.
public struct SeriesKey: Hashable, Sendable, Codable {
    public let source: String // "vendor/label"
    public let vendor: String
    public let model: String

    public init(source: String, vendor: String, model: String) {
        self.source = source
        self.vendor = vendor
        self.model = model
    }
}

/// One cell's accumulated contribution. `tokens` is everything the cell
/// saw and drives the token charts. The dollar side is split because a
/// cell may hold both kinds: `costedUSD` is summed as-is from
/// vendor-reported figures, `pricedTokens` is the subset that goes
/// through the pricing table at snapshot time.
///
/// Keeping them separate rather than branching on "is this series
/// costed" matters for the per-project, per-day and per-hour
/// aggregations, which key on model alone — there a costed and a priced
/// contribution can land in one bucket. Mirrors `agg.cellVal` in Go.
public struct CellValue: Equatable, Sendable {
    public var tokens: TokenCounts
    public var costedUSD: Double
    public var pricedTokens: TokenCounts

    public init(tokens: TokenCounts = .zero, costedUSD: Double = 0,
                pricedTokens: TokenCounts = .zero) {
        self.tokens = tokens
        self.costedUSD = costedUSD
        self.pricedTokens = pricedTokens
    }

    public static let zero = CellValue()

    public func adding(_ other: CellValue) -> CellValue {
        CellValue(tokens: tokens.adding(other.tokens),
                  costedUSD: costedUSD + other.costedUSD,
                  pricedTokens: pricedTokens.adding(other.pricedTokens))
    }
}

/// How much of a vendor's activity carried usable usage data. Mirrors
/// `agg.Coverage` in Go, threshold included.
public struct Coverage: Equatable, Sendable, Codable {
    public var turns: Int
    public var withUsage: Int

    public init(turns: Int = 0, withUsage: Int = 0) {
        self.turns = turns; self.withUsage = withUsage
    }

    /// A vendor that reported no turns is complete by definition, not
    /// 0% — Claude emits no coverage events and must never render as a
    /// partial figure.
    public var fraction: Double { turns == 0 ? 1 : Double(withUsage) / Double(turns) }
    public var partial: Bool { fraction < Aggregator.partialCoverageThreshold }
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
    /// Total tokens for the day across all models — sum of input,
    /// output, cache-create and cache-read. UInt64 so it accumulates
    /// exactly across thousands of events without float drift.
    public var tokens: UInt64
    /// Per-model breakdown for the day. The chart layer uses this to
    /// stack bar segments by model so the user can see at a glance
    /// which model drove the spend / token volume on a given day.
    /// Same key set as `tokensByModel` (the union of every model that
    /// produced events on the day).
    public var usdByModel: [String: Double]
    public var tokensByModel: [String: UInt64]
    /// Per-hour, per-model USD for the day — 24 entries, one dictionary
    /// per local hour. Drives the hourly chart both for today and when
    /// the user clicks a day in the monthly chart to drill in.
    public var hourlyUSDByModel: [[String: Double]]

    public init(day: String,
                usd: Double,
                tokens: UInt64 = 0,
                usdByModel: [String: Double] = [:],
                tokensByModel: [String: UInt64] = [:],
                hourlyUSDByModel: [[String: Double]] = Array(repeating: [:], count: 24)) {
        self.day = day
        self.usd = usd
        self.tokens = tokens
        self.usdByModel = usdByModel
        self.tokensByModel = tokensByModel
        self.hourlyUSDByModel = hourlyUSDByModel
    }
}

public struct Totals: Equatable, Sendable {
    public var day: [SeriesKey: ModelDay] = [:]
    public var month: [SeriesKey: ModelDay] = [:]
    public var dayProj: [String: ProjectDay] = [:]
    public var monthProj: [String: ProjectDay] = [:]
    public var daily: [DailyTotal] = []
    public var todayHourly: [TokenCounts] = Array(repeating: .zero, count: 24)
    public var todayHourlyUSD: [Double] = Array(repeating: 0, count: 24)
    public var unknown: Int = 0
    public var dupes: Int = 0
    /// How much of each vendor's activity carried usable usage data,
    /// scoped to the displayed month (same scope as `month`).
    public var coverage: [String: Coverage] = [:]
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

    /// Storage cell: a (day, project, source, vendor, model, isSub) bucket
    /// of token counts. Cost is derived from these at snapshot time.
    public struct CellKey: Hashable, Sendable, Codable {
        public let day: CivilDay
        public let project: String
        public let source: String
        public let vendor: String
        public let model: String
        public let isSub: Bool
    }

    /// How many trailing days `Snapshot` fills into `daily`.
    public static let dailyWindow = 30

    /// The usage-bearing fraction below which a vendor's figures are
    /// presented as a floor rather than a total.
    public static let partialCoverageThreshold = 0.95

    private var pricing: PricingTable
    private var cells: [CellKey: CellValue] = [:]
    private var perMsg: Set<String> = []
    private var unknownMsgs: Set<String> = []
    private(set) public var dupes: Int = 0
    private var coverage: [CoverageKey: Coverage] = [:]

    /// Scopes a coverage tally to a (day, vendor) so `snapshot` can
    /// restrict it to the displayed month.
    private struct CoverageKey: Hashable { let day: CivilDay; let vendor: String }

    /// Per-(day, hour, vendor, model) contribution for every day in the
    /// trailing `dailyWindow`. Stored separately from `cells` because
    /// cells are keyed by day, not hour. Days that fall out of the window
    /// are pruned lazily at snapshot time.
    ///
    /// Vendor is part of the key even though the hourly chart stacks by
    /// model alone. Without it a costed and a priced contribution could
    /// share a bucket whenever two vendors use the same model name, and
    /// the bucket would no longer be one kind or the other — which is
    /// what `CacheFile.HourEntry` relies on to round-trip in one Bool
    /// instead of a second token quartet. `CellKey` already carries
    /// vendor for the same reason.
    private struct HourBucketKey: Hashable {
        let day: CivilDay
        let hour: Int
        let vendor: String
        let model: String
    }
    private var hourBuckets: [HourBucketKey: CellValue] = [:]

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
    /// Hour buckets are loaded separately via `loadHourBuckets` — see
    /// `CacheFile.restore` for the canonical sequencing.
    public func load(cells: [CellKey: CellValue], perMsg: Set<String>,
                     unknownMsgs: Set<String>, dupes: Int,
                     coverage: [(day: CivilDay, vendor: String, coverage: Coverage)] = []) {
        self.cells = cells
        self.perMsg = perMsg
        self.unknownMsgs = unknownMsgs
        self.dupes = dupes
        self.coverage = Dictionary(uniqueKeysWithValues: coverage.map {
            (CoverageKey(day: $0.day, vendor: $0.vendor), $0.coverage)
        })
        // Default to empty until loadHourBuckets is called explicitly.
        self.hourBuckets.removeAll(keepingCapacity: false)
    }

    public func exportState() -> (cells: [CellKey: CellValue],
                                  perMsg: Set<String>,
                                  unknownMsgs: Set<String>,
                                  dupes: Int,
                                  coverage: [(day: CivilDay, vendor: String, coverage: Coverage)]) {
        (cells, perMsg, unknownMsgs, dupes,
         coverage.map { (day: $0.key.day, vendor: $0.key.vendor, coverage: $0.value) })
    }

    /// Snapshot of the per-(day, hour, vendor, model) state for the
    /// trailing window. Empty if no events have been recorded yet.
    public func exportHourBuckets()
        -> [(day: CivilDay, hour: Int, vendor: String, model: String, value: CellValue)]
    {
        hourBuckets.map { (k, v) in
            (day: k.day, hour: k.hour, vendor: k.vendor, model: k.model, value: v)
        }
    }

    /// Replace the hourly state from a cache. Entries older than the
    /// trailing `dailyWindow` (per the injected clock) are dropped —
    /// they can never be displayed and would only grow the cache.
    public func loadHourBuckets(
        entries: [(day: CivilDay, hour: Int, vendor: String, model: String, value: CellValue)]
    ) {
        let cutoff = windowCutoffString()
        var rebuilt: [HourBucketKey: CellValue] = [:]
        for e in entries where civilDayString(e.day) >= cutoff {
            let key = HourBucketKey(day: e.day, hour: e.hour, vendor: e.vendor, model: e.model)
            rebuilt[key] = e.value
        }
        hourBuckets = rebuilt
    }

    /// `civilDayString` of the oldest day inside the trailing window.
    /// Civil-day strings are zero-padded so lexicographic comparison
    /// matches chronological order.
    private func windowCutoffString() -> String {
        let oldest = calendar.date(byAdding: .day, value: -(Self.dailyWindow - 1),
                                   to: now()) ?? now()
        return civilDayString(dayOf(oldest, calendar: calendar))
    }

    public func reset() {
        cells.removeAll(keepingCapacity: true)
        perMsg.removeAll(keepingCapacity: true)
        unknownMsgs.removeAll(keepingCapacity: true)
        hourBuckets.removeAll(keepingCapacity: true)
        coverage.removeAll(keepingCapacity: true)
        dupes = 0
    }

    /// Record an event's contribution. Dedupe rule mirrors ccusage:
    /// the unique key is `messageID:requestID`; if either is missing the
    /// event is always counted (no dedup); first-seen wins.
    ///
    /// Returns `true` when the event was newly counted, `false` when it
    /// was dropped as a duplicate. Callers that also drive a
    /// `SessionTracker` use this so dedup stays a single source of truth
    /// (the tracker is fed only on `true`), never double-counting turns.
    @discardableResult
    public func apply(_ e: UsageEvent) -> Bool {
        // 1) Dedupe.
        if !e.messageID.isEmpty && !e.requestID.isEmpty {
            let key = e.messageID + ":" + e.requestID
            if perMsg.contains(key) {
                dupes += 1
                return false
            }
            perMsg.insert(key)
        }

        // 2) Coverage bookkeeping. Must sit after dedupe (above) and
        //    before the cell write (below) — same ordering and reason as
        //    Go's Task 5: a coverage event shares fields (usage, costUSD)
        //    with a real event, but they are not spend, and skipping
        //    dedupe would let a re-scan (AppState's start/refresh/
        //    reloadSources all re-scan) inflate the tally.
        if e.coverageOnly {
            let k = CoverageKey(day: dayOf(e.timestamp, calendar: calendar), vendor: e.vendor)
            var c = coverage[k] ?? Coverage()
            c.turns += 1
            if e.hasUsage { c.withUsage += 1 }
            coverage[k] = c
            return true
        }

        // 3) Track unknowns for diagnostics (still bucket the tokens). A
        //    costed event has no pricing lookup to miss, so it can never
        //    be "unknown".
        if !e.costed && !pricing.has(model: e.model) {
            let uid = !e.messageID.isEmpty ? e.messageID : "\(e.model):\(e.timestamp)"
            unknownMsgs.insert(uid)
        }

        // 4) Bucket into the day/project/source/vendor/model/isSub cell.
        //    A costed contribution carries its dollar figure as-is;
        //    a priced one carries tokens for the pricing table to cost
        //    at snapshot time.
        let cellKey = CellKey(
            day: dayOf(e.timestamp, calendar: calendar),
            project: e.project,
            source: e.source,
            vendor: e.vendor,
            model: e.model,
            isSub: e.isSubagent
        )
        let contribution = e.costed
            ? CellValue(tokens: TokenCounts.zero.adding(e.usage), costedUSD: e.costUSD)
            : CellValue(tokens: TokenCounts.zero.adding(e.usage),
                        pricedTokens: TokenCounts.zero.adding(e.usage))
        cells[cellKey] = (cells[cellKey] ?? .zero).adding(contribution)

        // 5) Accumulate into the per-(day, hour, vendor, model) buckets so
        //    the hourly chart can drill into any day of the window. Days
        //    that age out of the window are pruned at snapshot time.
        let hour = hourOf(e.timestamp, calendar: calendar)
        let hk = HourBucketKey(day: cellKey.day, hour: hour, vendor: e.vendor, model: e.model)
        hourBuckets[hk] = (hourBuckets[hk] ?? .zero).adding(contribution)

        return true
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

        // Aggregate per-(scope, series).
        struct ModelScope: Hashable { let scope: String; let key: SeriesKey }
        var modelTok: [ModelScope: CellValue] = [:]

        // Aggregate per-(scope, project, isSub, model). Model must be
        // preserved for per-project costing because a project may use
        // multiple models with different prices.
        struct ProjScopeModel: Hashable {
            let scope: String; let project: String; let isSub: Bool; let model: String
        }
        var projModelTok: [ProjScopeModel: CellValue] = [:]

        // Per-day-per-model for the daily window.
        struct DayModel: Hashable { let day: CivilDay; let model: String }
        var byDM: [DayModel: CellValue] = [:]

        for (k, v) in cells {
            let sk = SeriesKey(source: k.source, vendor: k.vendor, model: k.model)
            // Day scope.
            if k.day == today {
                modelTok[ModelScope(scope: "day", key: sk), default: .zero] =
                    (modelTok[ModelScope(scope: "day", key: sk)] ?? .zero).adding(v)
                let pk = ProjScopeModel(scope: "day", project: k.project, isSub: k.isSub, model: k.model)
                projModelTok[pk, default: .zero] = (projModelTok[pk] ?? .zero).adding(v)
            }
            // Month scope.
            if k.day.year == nowYear && k.day.month == nowMonth {
                modelTok[ModelScope(scope: "month", key: sk), default: .zero] =
                    (modelTok[ModelScope(scope: "month", key: sk)] ?? .zero).adding(v)
                let pk = ProjScopeModel(scope: "month", project: k.project, isSub: k.isSub, model: k.model)
                projModelTok[pk, default: .zero] = (projModelTok[pk] ?? .zero).adding(v)
            }
            // Daily window (all days, only those in the last 30-day window
            // are shown — the slice below filters).
            byDM[DayModel(day: k.day, model: k.model), default: .zero] =
                (byDM[DayModel(day: k.day, model: k.model)] ?? .zero).adding(v)
        }

        // Apply pricing per (scope, series). `costedUSD` is summed as
        // given; `pricedTokens` (the non-costed subset) goes through the
        // table. A costed cell has no pricing entry to consult.
        for (mk, v) in modelTok {
            var usd = v.costedUSD
            if pricing.has(model: mk.key.model) {
                usd += pricing.cost(model: mk.key.model, usage: v.pricedTokens.toUsage())
            }
            let md = ModelDay(usd: usd, tokens: v.tokens)
            switch mk.scope {
            case "day":   out.day[mk.key] = md
            case "month": out.month[mk.key] = md
            default: break
            }
        }

        // Per-project: walk preserving model so cost is accurate when a
        // project uses multiple models with different prices.
        for (k, v) in projModelTok {
            var usd = v.costedUSD
            if pricing.has(model: k.model) {
                usd += pricing.cost(model: k.model, usage: v.pricedTokens.toUsage())
            }
            switch k.scope {
            case "day":
                var pd = out.dayProj[k.project] ?? ProjectDay()
                if k.isSub { pd.sub = pd.sub.adding(v.tokens); pd.subUSD += usd }
                else       { pd.main = pd.main.adding(v.tokens); pd.mainUSD += usd }
                out.dayProj[k.project] = pd
            case "month":
                var pd = out.monthProj[k.project] ?? ProjectDay()
                if k.isSub { pd.sub = pd.sub.adding(v.tokens); pd.subUSD += usd }
                else       { pd.main = pd.main.adding(v.tokens); pd.mainUSD += usd }
                out.monthProj[k.project] = pd
            default:
                break
            }
        }

        // Daily window: last 30 days, oldest→newest. Tokens are summed
        // across ALL models (priced, costed and unknown) so the token
        // chart reflects raw activity even when a model isn't in the
        // pricing table; cost counts vendor-reported dollars plus priced
        // models, matching the USD chart. We also keep the per-model
        // breakdown for each day so the UI layer can stack bars by model.
        var dayCost: [CivilDay: Double] = [:]
        var dayTokens: [CivilDay: UInt64] = [:]
        var dayCostByModel: [CivilDay: [String: Double]] = [:]
        var dayTokensByModel: [CivilDay: [String: UInt64]] = [:]
        for (k, v) in byDM {
            let total = v.tokens.input &+ v.tokens.output &+ v.tokens.cacheCreate &+ v.tokens.cacheRead
            dayTokens[k.day, default: 0] = (dayTokens[k.day] ?? 0) &+ total
            dayTokensByModel[k.day, default: [:]][k.model] =
                (dayTokensByModel[k.day]?[k.model] ?? 0) &+ total
            let priced = pricing.has(model: k.model)
            var cost = v.costedUSD
            if priced {
                cost += pricing.cost(model: k.model, usage: v.pricedTokens.toUsage())
            }
            // Non-zero-or-priced, not just "priced": a costed model has
            // no pricing entry but must still land in the daily breakdown.
            if priced || cost != 0 {
                dayCost[k.day, default: 0] += cost
                dayCostByModel[k.day, default: [:]][k.model, default: 0] += cost
            }
        }
        // Prune hour buckets that aged out of the window, then walk the
        // survivors once: per-day per-hour per-model USD for the daily
        // window, with today's totals split out into the legacy
        // todayHourly / todayHourlyUSD arrays.
        let cutoff = windowCutoffString()
        hourBuckets = hourBuckets.filter { civilDayString($0.key.day) >= cutoff }

        var hourly = Array(repeating: TokenCounts.zero, count: 24)
        var hourlyUSD = Array(repeating: 0.0, count: 24)
        var hourlyUSDByDay: [CivilDay: [[String: Double]]] = [:]
        for (hk, v) in hourBuckets {
            let priced = pricing.has(model: hk.model)
            var cost = v.costedUSD
            if priced {
                cost += pricing.cost(model: hk.model, usage: v.pricedTokens.toUsage())
            }
            // Non-zero-or-priced, not just "priced": a costed model has
            // no pricing entry but must still land in the stacked chart.
            if priced || cost != 0 {
                var hours = hourlyUSDByDay[hk.day] ?? Array(repeating: [:], count: 24)
                hours[hk.hour][hk.model, default: 0] += cost
                hourlyUSDByDay[hk.day] = hours
            }
            if hk.day == today {
                hourly[hk.hour] = hourly[hk.hour].adding(v.tokens)
                hourlyUSD[hk.hour] += cost
            }
        }
        out.todayHourly = hourly
        out.todayHourlyUSD = hourlyUSD

        out.daily = (0..<Self.dailyWindow).reversed().map { i in
            let date = calendar.date(byAdding: .day, value: -i, to: nowLocal) ?? nowLocal
            let cd = dayOf(date, calendar: calendar)
            return DailyTotal(
                day: civilDayString(cd),
                usd: dayCost[cd] ?? 0,
                tokens: dayTokens[cd] ?? 0,
                usdByModel: dayCostByModel[cd] ?? [:],
                tokensByModel: dayTokensByModel[cd] ?? [:],
                hourlyUSDByModel: hourlyUSDByDay[cd] ?? Array(repeating: [:], count: 24)
            )
        }

        // Coverage is scoped to the displayed month, matching out.month.
        for (k, c) in coverage where k.day.year == nowYear && k.day.month == nowMonth {
            var cur = out.coverage[k.vendor] ?? Coverage()
            cur.turns += c.turns
            cur.withUsage += c.withUsage
            out.coverage[k.vendor] = cur
        }

        return out
    }
}
