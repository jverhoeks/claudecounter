import Foundation

/// Everything the Performance tab draws, computed in one pass off the
/// main thread. Pure: samples + filters in, numbers out — the view only
/// lays them out.
public struct PerformanceReport: Sendable {

    public enum Agent: String, CaseIterable, Sendable { case all, main, subagent }

    public struct Filters: Equatable, Sendable {
        public var model: String?
        public var rangeDays: Int
        /// nil = pick from the range: hourly up to a week, daily beyond.
        public var bucket: PerformanceStats.Bucket?
        public var agent: Agent
        /// nil = all; "none" = requests whose client recorded no effort.
        public var effort: String?
        public init(model: String? = nil, rangeDays: Int = 30, bucket: PerformanceStats.Bucket? = nil,
                    agent: Agent = .all, effort: String? = nil) {
            self.model = model; self.rangeDays = rangeDays; self.bucket = bucket
            self.agent = agent; self.effort = effort
        }
        public var resolvedBucket: PerformanceStats.Bucket { bucket ?? (rangeDays <= 7 ? .hour : .day) }
    }

    public static let percentiles: [(q: Double, label: String)] = [(0.5, "p50"), (0.9, "p90"), (0.95, "p95"), (0.99, "p99")]
    public static let efforts = ["none", "low", "medium", "high", "xhigh"]
    public static let contextBins: [(lo: UInt64, hi: UInt64, label: String)] = [
        (0, 25_000, "<25k"), (25_000, 50_000, "25–50k"), (50_000, 100_000, "50–100k"),
        (100_000, 150_000, "100–150k"), (150_000, 250_000, "150–250k"), (250_000, .max, "250k+"),
    ]

    /// One row of the cross-model table.
    public struct ModelRow: Identifiable, Sendable {
        public var id: String { model }
        public var model: String
        public var requests: Int
        public var e2eP50: Double?
        public var firstBlockP50: Double?
        public var fit: PerformanceStats.Fit?
        public var misuse: Double?
        public var ttftDrift: PerformanceStats.Drift?
        public var itlDrift: PerformanceStats.Drift?
        public var misuseDrift: PerformanceStats.Drift?
    }

    public var filters: Filters
    public var model: String
    public var models: [ModelRow]
    public var requests: Int
    public var subagentShare: Double

    // KPIs for the selected model
    public var e2eP50: Double?, e2eP90: Double?
    public var firstBlockP50: Double?, firstBlockP90: Double?
    public var fit: PerformanceStats.Fit?
    public var cacheHit: Double?
    public var rebuilds: Int
    public var toolCalls: Int
    public var misuse: Double?
    public var ttftDrift: PerformanceStats.Drift?
    public var itlDrift: PerformanceStats.Drift?
    public var misuseDrift: PerformanceStats.Drift?
    public var contextBefore: Double?, contextAfter: Double?

    // Per bucket — every array is `buckets.count` long; nil = too few samples.
    public var buckets: [Date]
    public var counts: [Int]
    public var e2e: [String: [Double?]]          // percentile label / "mean"
    public var firstBlock: [String: [Double?]]
    public var fits: [PerformanceStats.Fit?]
    public var peakInFlight: [Int?]
    public var meanInFlight: [Double?]
    public var outputPerMinute: [Double?]
    public var cacheHitRate: [Double?]
    public var rebuildCount: [Int]
    public var misuseRate: [Double?]
    public var exitRate: [Double?]
    public var outputP50: [Double?]
    public var thinkingP50: [Double?]
    public var contextP50: [Double?]
    public var contextP90: [Double?]
    public var effortShare: [String: [Double?]]
    public var subagentShareByBucket: [Double?]

    // Whole range
    public var hourE2E: [Double?]          // 24, local hour
    public var hourFirstBlock: [Double?]
    public var misuseByContext: [Double?]  // per `contextBins`

    public static func effortKey(_ s: RequestSample) -> String {
        guard let e = s.effort, efforts.contains(e) else { return "none" }
        return e
    }

    public static func build(_ all: [RequestSample], filters: Filters, now: Date = Date(),
                             calendar: Calendar = .current) -> PerformanceReport {
        let start = now.addingTimeInterval(-Double(filters.rangeDays) * 86400)
        let inScope = all.filter { s in
            s.time >= start
                && (filters.agent == .all || s.isSubagent == (filters.agent == .subagent))
                && (filters.effort == nil || effortKey(s) == filters.effort)
        }
        let byModel = Dictionary(grouping: inScope, by: \.model)

        let rows: [ModelRow] = byModel.map { m, xs in
            let (a, b) = thirds(xs)
            let fa = PerformanceStats.fit(a), fb = PerformanceStats.fit(b)
            return ModelRow(model: m, requests: xs.count,
                            e2eP50: PerformanceStats.quantile(xs.map(\.duration), 0.5),
                            firstBlockP50: PerformanceStats.quantile(xs.map(\.firstBlock), 0.5),
                            fit: PerformanceStats.fit(xs), misuse: PerformanceStats.misuseRate(xs),
                            ttftDrift: drift(fa, fb, \.ttft, \.ttftSD),
                            itlDrift: drift(fa, fb, \.itlMs, \.itlSD),
                            misuseDrift: misuseDrift(a, b))
        }.sorted { $0.requests > $1.requests }

        // Default to whichever model was used most in the last two weeks.
        let recent = Dictionary(grouping: inScope.filter { $0.time > now.addingTimeInterval(-14 * 86400) }, by: \.model)
        let model = filters.model.flatMap { byModel[$0] != nil ? $0 : nil }
            ?? recent.max { $0.value.count < $1.value.count }?.key
            ?? rows.first?.model ?? ""
        let xs = byModel[model] ?? []

        let unit = filters.resolvedBucket
        let first = xs.first?.time ?? start
        let buckets = PerformanceStats.buckets(from: max(start, first), to: now, unit, calendar: calendar)
        let groups = PerformanceStats.group(xs, starts: buckets, unit, calendar: calendar)
        let conc = PerformanceStats.concurrency(xs, starts: buckets, unit, calendar: calendar)
        let lengths = buckets.indices.map { i in
            (i + 1 < buckets.count ? buckets[i + 1]
                : calendar.date(byAdding: unit == .hour ? .hour : .day, value: unit == .week ? 7 : 1, to: buckets[i])!)
                .timeIntervalSince(buckets[i])
        }

        func pct(_ key: KeyPath<RequestSample, Double>) -> [String: [Double?]] {
            var out: [String: [Double?]] = [:]
            for (q, label) in percentiles {
                out[label] = groups.map { g in
                    g.count >= PerformanceStats.minSamples(for: q) ? PerformanceStats.quantile(g.map { $0[keyPath: key] }, q) : nil
                }
            }
            out["mean"] = groups.map { g in g.count >= 20 ? g.reduce(0) { $0 + $1[keyPath: key] } / Double(g.count) : nil }
            return out
        }
        func rate(_ g: [RequestSample], _ count: (RequestSample) -> Int) -> Double? {
            let t = g.reduce(0) { $0 + $1.toolCalls }
            return t >= 100 ? Double(g.reduce(0) { $0 + count($1) }) / Double(t) : nil
        }
        func median(_ g: [RequestSample], _ v: (RequestSample) -> Double?) -> Double? {
            let vals = g.compactMap(v)
            return vals.count >= 20 ? PerformanceStats.quantile(vals, 0.5) : nil
        }

        var hours = [[RequestSample]](repeating: [], count: 24)
        for s in xs { hours[calendar.component(.hour, from: s.time)].append(s) }

        let (a, b) = thirds(xs)
        let fa = PerformanceStats.fit(a), fb = PerformanceStats.fit(b)

        return PerformanceReport(
            filters: filters, model: model, models: rows,
            requests: xs.count,
            subagentShare: xs.isEmpty ? 0 : Double(xs.filter(\.isSubagent).count) / Double(xs.count),
            e2eP50: PerformanceStats.quantile(xs.map(\.duration), 0.5),
            e2eP90: PerformanceStats.quantile(xs.map(\.duration), 0.9),
            firstBlockP50: PerformanceStats.quantile(xs.map(\.firstBlock), 0.5),
            firstBlockP90: PerformanceStats.quantile(xs.map(\.firstBlock), 0.9),
            fit: PerformanceStats.fit(xs),
            cacheHit: PerformanceStats.cacheHitRate(xs),
            rebuilds: xs.filter { $0.rebuild != .none }.count,
            toolCalls: xs.reduce(0) { $0 + $1.toolCalls },
            misuse: PerformanceStats.misuseRate(xs),
            ttftDrift: drift(fa, fb, \.ttft, \.ttftSD),
            itlDrift: drift(fa, fb, \.itlMs, \.itlSD),
            misuseDrift: misuseDrift(a, b),
            contextBefore: PerformanceStats.quantile(a.map { Double($0.context) }, 0.5),
            contextAfter: PerformanceStats.quantile(b.map { Double($0.context) }, 0.5),
            buckets: buckets,
            counts: groups.map(\.count),
            e2e: pct(\.duration),
            firstBlock: pct(\.firstBlock),
            fits: groups.map(PerformanceStats.fit),
            peakInFlight: conc.enumerated().map { groups[$0.offset].isEmpty ? nil : $0.element.peak },
            meanInFlight: conc.enumerated().map { groups[$0.offset].isEmpty ? nil : $0.element.mean },
            outputPerMinute: groups.indices.map { i in
                groups[i].isEmpty ? nil : Double(groups[i].reduce(UInt64(0)) { $0 &+ $1.output }) / (lengths[i] / 60)
            },
            cacheHitRate: groups.map(PerformanceStats.cacheHitRate),
            rebuildCount: groups.map { $0.filter { $0.rebuild != .none }.count },
            misuseRate: groups.map { rate($0) { $0.toolErrors.misuse } },
            exitRate: groups.map { rate($0) { $0.toolErrors.exit } },
            outputP50: groups.map { median($0) { Double($0.output) } },
            thinkingP50: groups.map { median($0) { $0.thinkingTokens.map { Double($0) } } },
            contextP50: groups.map { g in g.count >= 20 ? PerformanceStats.quantile(g.map { Double($0.context) }, 0.5) : nil },
            contextP90: groups.map { g in g.count >= 20 ? PerformanceStats.quantile(g.map { Double($0.context) }, 0.9) : nil },
            effortShare: Dictionary(uniqueKeysWithValues: efforts.map { e in
                (e, groups.map { g in g.isEmpty ? nil : Double(g.filter { effortKey($0) == e }.count) / Double(g.count) })
            }),
            subagentShareByBucket: groups.map { g in g.isEmpty ? nil : Double(g.filter(\.isSubagent).count) / Double(g.count) },
            hourE2E: hours.map { $0.count >= 20 ? PerformanceStats.quantile($0.map(\.duration), 0.5) : nil },
            hourFirstBlock: hours.map { $0.count >= 20 ? PerformanceStats.quantile($0.map(\.firstBlock), 0.5) : nil },
            misuseByContext: contextBins.map { bin in rate(xs.filter { $0.context >= bin.lo && $0.context < bin.hi }) { $0.toolErrors.misuse } }
        )
    }

    private static func misuseDrift(_ a: [RequestSample], _ b: [RequestSample]) -> PerformanceStats.Drift? {
        let calls = { (x: [RequestSample]) in x.reduce(0) { $0 + $1.toolCalls } }
        guard min(calls(a), calls(b)) >= minDriftSamples else { return nil }
        return PerformanceStats.misuseDrift(a, b)
    }

    /// First and last third of a time-sorted sample — what "has it changed?"
    /// compares. Thirds rather than halves so the two never touch.
    static func thirds(_ xs: [RequestSample]) -> ([RequestSample], [RequestSample]) {
        let n = xs.count / 3
        return (Array(xs.prefix(n)), Array(xs.suffix(n)))
    }

    /// Below this many requests (or tool calls) per third, a drift
    /// figure is noise dressed up as a percentage — a 381-request month
    /// produced "−188%" — so none is shown.
    public static let minDriftSamples = 500

    private static func drift(_ a: PerformanceStats.Fit?, _ b: PerformanceStats.Fit?,
                              _ v: KeyPath<PerformanceStats.Fit, Double>,
                              _ sd: KeyPath<PerformanceStats.Fit, Double>) -> PerformanceStats.Drift? {
        guard let a, let b, min(a.n, b.n) >= minDriftSamples else { return nil }
        return PerformanceStats.drift(a[keyPath: v], a[keyPath: sd], b[keyPath: v], b[keyPath: sd])
    }
}
