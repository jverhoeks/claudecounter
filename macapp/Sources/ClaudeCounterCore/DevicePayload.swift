import Foundation

/// The document the mac app publishes for the desk device. Version 1.
/// Built only from values `AppState` already holds; see the design at
/// docs/superpowers/specs/2026-09-04-m5stack-device-display-design.md.
///
/// The device reads `spend`, `models`, `usage`, `warnPct` and `context`.
public struct DevicePayload: Codable, Equatable, Sendable {

    public struct Spend: Codable, Equatable, Sendable {
        public var day: Double
        public var week: Double
        public var month: Double
        public init(day: Double, week: Double, month: Double) {
            self.day = day; self.week = week; self.month = month
        }
    }

    public struct ModelSpend: Codable, Equatable, Sendable {
        public var vendor: String
        public var model: String
        public var day: Double
        public var week: Double
        public var month: Double
        public init(vendor: String, model: String, day: Double, week: Double, month: Double) {
            self.vendor = vendor; self.model = model
            self.day = day; self.week = week; self.month = month
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        public var vendor: String
        public var window: String
        public var pct: Int
        public var stale: Bool
        public init(vendor: String, window: String, pct: Int, stale: Bool) {
            self.vendor = vendor; self.window = window; self.pct = pct; self.stale = stale
        }
    }

    public struct Context: Codable, Equatable, Sendable {
        public var session: String
        public var pct: Int
        public var warn: Bool
        public init(session: String, pct: Int, warn: Bool) {
            self.session = session; self.pct = pct; self.warn = warn
        }
    }

    public static let currentVersion = 1
    public static let maxModels = 20

    public var v: Int
    public var at: String
    public var spend: [String: Spend]
    public var models: [ModelSpend]
    public var usage: [Usage]
    public var warnPct: Int
    /// Highest-context active session, or nil when none is active.
    /// Encoded as an explicit `null` so the device can distinguish
    /// "no session" from a malformed body.
    public var context: Context?

    enum CodingKeys: String, CodingKey { case v, at, spend, models, usage, warnPct, context }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(at, forKey: .at)
        try c.encode(spend, forKey: .spend)
        try c.encode(models, forKey: .models)
        try c.encode(usage, forKey: .usage)
        try c.encode(warnPct, forKey: .warnPct)
        try c.encode(context, forKey: .context) // encodes nil as null
    }

    /// Compact, sorted-key JSON so two payloads with equal content
    /// produce byte-equal bodies. `DevicePublisher` relies on that to
    /// skip unchanged sends.
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    public static func build(totals: Totals,
                             statuses: [LimitStatus],
                             gauges: [PlanGauge],
                             sessions: [SessionStat],
                             warnPct: Int,
                             now: Date) -> DevicePayload {
        // Vendor sums over each period. A vendor appears if it has any
        // spend in the month; day/week default to 0.
        var spend: [String: Spend] = [:]
        for (k, v) in totals.month where v.usd > 0 {
            spend[k.vendor, default: Spend(day: 0, week: 0, month: 0)].month += v.usd
        }
        for (k, v) in totals.day where spend[k.vendor] != nil { spend[k.vendor]!.day += v.usd }
        for (k, v) in totals.week where spend[k.vendor] != nil { spend[k.vendor]!.week += v.usd }
        for (vendor, s) in spend {
            spend[vendor] = Spend(day: cents(s.day), week: cents(s.week), month: cents(s.month))
        }

        // Per-model rows: positive month spend only, then day/week
        // looked up by the same key.
        var models: [ModelSpend] = []
        for (k, v) in totals.month where v.usd > 0 {
            models.append(ModelSpend(vendor: k.vendor, model: k.model,
                                     day: cents(totals.day[k]?.usd ?? 0),
                                     week: cents(totals.week[k]?.usd ?? 0),
                                     month: cents(v.usd)))
        }
        models.sort { a, b in
            if a.month != b.month { return a.month > b.month }
            return a.model < b.model
        }
        if models.count > maxModels { models.removeSubrange(maxModels...) }

        // Usage rows in exactly the order the popover renders them:
        // short band then weekly band, GaugeRows' vendor order inside.
        var usage: [Usage] = []
        for band in [GaugeBand.short, .weekly] {
            for row in GaugeRows.build(band: band, statuses: statuses, gauges: gauges) {
                usage.append(Usage(vendor: row.vendor, window: row.windowLabel,
                                   pct: Int(row.pct.rounded()), stale: row.isStale))
            }
        }

        let top = sessions.max { $0.contextPct < $1.contextPct }
        let context = top.map {
            Context(session: shortProjectName($0.project),
                    pct: Int(($0.contextPct * 100).rounded()),
                    warn: $0.warnings.contains(.context))
        }

        return DevicePayload(v: currentVersion, at: iso(now), spend: spend, models: models,
                             usage: usage, warnPct: warnPct, context: context)
    }

    private static func cents(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}
