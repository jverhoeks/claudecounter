import Foundation

// MARK: - Hints
//
// Turns the request samples into a short list of "this is costing you $X —
// here is the one-line fix" cards. Each rule prices its own counterfactual
// from the logs at the app's pricing table (flat rates, so the long-context
// premium is not included — estimates run low for 200k+ turns). The savings
// overlap (compacting earlier also shrinks resume rewrites), so the view
// must not add them up.
//
// Rules read ~/.claude/settings.json to say whether a fix is already in
// place. Read-only: nothing here ever writes the user's Claude settings.

public struct Hint: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case compact, resume, cacheTTL, subagentModel, mainModel, effort
    }
    public var id: Kind
    public var title: String
    /// What the logs show, with the numbers.
    public var finding: String
    /// Estimated saving over the period, USD at API prices.
    public var savingUSD: Double
    /// What to do, in a sentence.
    public var fix: String
    /// Copyable settings fragment or command.
    public var snippet: String?
    /// The trade-off to weigh before applying.
    public var caveat: String
    /// Non-nil when the user's settings already contain the fix.
    public var applied: String?
}

/// The handful of Claude Code settings the hints check against.
public struct ClaudeSettingsSnapshot: Equatable, Sendable {
    public var autoCompactWindow: Int?
    public var promptCacheTtl: String?
    public var subagentModel: String?
    public var model: String?
    public var effortLevel: String?
    public var modelEffort: [String: String] = [:]

    public init(autoCompactWindow: Int? = nil, promptCacheTtl: String? = nil, subagentModel: String? = nil,
                model: String? = nil, effortLevel: String? = nil, modelEffort: [String: String] = [:]) {
        self.autoCompactWindow = autoCompactWindow; self.promptCacheTtl = promptCacheTtl
        self.subagentModel = subagentModel; self.model = model
        self.effortLevel = effortLevel; self.modelEffort = modelEffort
    }

    public static var userSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
    }

    /// Missing or unreadable file → empty snapshot (nothing applied).
    public static func load(path: String = userSettingsPath) -> ClaudeSettingsSnapshot {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .init() }
        let env = obj["env"] as? [String: Any] ?? [:]
        var perModel: [String: String] = [:]
        for (m, v) in obj["modelSettings"] as? [String: Any] ?? [:] {
            if let e = (v as? [String: Any])?["effortLevel"] as? String { perModel[m] = e }
        }
        return ClaudeSettingsSnapshot(
            autoCompactWindow: (obj["autoCompactWindow"] as? NSNumber)?.intValue
                ?? (env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] as? String).flatMap(Int.init),
            promptCacheTtl: obj["promptCacheTtl"] as? String ?? env["CLAUDE_CODE_PROMPT_CACHE_TTL"] as? String,
            subagentModel: env["CLAUDE_CODE_SUBAGENT_MODEL"] as? String,
            model: obj["model"] as? String,
            effortLevel: obj["effortLevel"] as? String,
            modelEffort: perModel)
    }

    /// Effective effort for `model`: per-model setting, else global.
    public func effort(for model: String) -> String? {
        modelEffort[model] ?? effortLevel
    }
}

public enum Hints {

    /// Thresholds below which a hint is noise, not advice.
    static let minSaving = 2.0

    public static func build(_ all: [RequestSample], pricing: PricingTable, settings: ClaudeSettingsSnapshot,
                             days: Int, now: Date = Date()) -> [Hint] {
        let start = now.addingTimeInterval(-Double(days) * 86400)
        let s = all.filter { $0.time >= start }
        guard !s.isEmpty else { return [] }
        let rules: [Hint?] = [
            compact(s, pricing, settings),
            resume(s, pricing),
            cacheTTL(s, pricing, settings),
            subagentModel(s, pricing, settings),
            mainModel(s, pricing, settings),
            effort(s, pricing, settings),
        ]
        return rules.compactMap { $0 }.filter { $0.savingUSD >= minSaving }.sorted { $0.savingUSD > $1.savingUSD }
    }

    // MARK: Rates

    /// USD per token for one token kind, via the public cost function.
    struct Rates { let input, output, read, write5m, write1h: Double }
    static func rates(_ model: String, _ p: PricingTable) -> Rates {
        func one(_ u: Usage) -> Double { p.cost(model: model, usage: u) / 1_000_000 }
        return Rates(input: one(Usage(input: 1_000_000)), output: one(Usage(output: 1_000_000)),
                     read: one(Usage(cacheRead: 1_000_000)), write5m: one(Usage(cacheCreate: 1_000_000)),
                     write1h: one(Usage(cacheCreate: 1_000_000, cacheCreate1h: 1_000_000)))
    }

    static func mainSessions(_ s: [RequestSample]) -> [[RequestSample]] {
        Dictionary(grouping: s.filter { !$0.isSubagent }, by: \.session).values.map { $0.sorted { $0.time < $1.time } }
    }

    static func usd(_ v: Double) -> String { v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
    static func k(_ v: Double) -> String { String(format: "%.0fk", v / 1000) }

    // MARK: 1. Compact earlier

    /// Replays each main session's context growth with auto-compact at
    /// `limit`: past it, one summary call reads the window and the session
    /// carries on from `base`. Both versions are priced with the same
    /// read-prefix / write-growth / output model, so the difference is fair
    /// even where that model is rough.
    static func compactSaving(_ sessions: [[RequestSample]], _ p: PricingTable, limit: Double,
                              base: Double = 40_000, summary: Double = 5_000) -> (saving: Double, compactions: Int) {
        var saved = 0.0, n = 0
        for rows in sessions {
            let r = rates(rows[0].model, p)
            func turn(_ prev: Double, _ new: Double, _ out: Double) -> Double {
                min(prev, new) * r.read + max(new - prev, 0) * r.write1h + out * r.output
            }
            var prevA = 0.0, prevS = 0.0, a = 0.0, b = 0.0
            for x in rows {
                let ctx = Double(x.context), out = Double(x.output)
                a += turn(prevA, ctx, out)
                let grow = ctx >= prevA ? ctx - prevA : 0
                var sim = ctx >= prevA ? prevS + grow : min(prevS, ctx)   // a real /compact or /clear resets too
                if sim > limit {
                    b += turn(prevS, prevS, summary) + base * r.write1h
                    n += 1
                    prevS = base
                    sim = base + grow
                }
                b += turn(prevS, sim, out)
                prevA = ctx; prevS = sim
            }
            saved += a - b
        }
        return (saved, n)
    }

    static func compact(_ s: [RequestSample], _ p: PricingTable, _ cfg: ClaudeSettingsSnapshot) -> Hint? {
        let main = s.filter { !$0.isSubagent }
        guard let median = PerformanceStats.quantile(main.map { Double($0.context) }, 0.5), median > 120_000 else { return nil }
        let total = s.reduce(0) { $0 + $1.cost(p) }
        let big = s.filter { $0.context > 200_000 }.reduce(0) { $0 + $1.cost(p) }
        let peak = Double(main.map(\.context).max() ?? 0)
        let (saving, n) = compactSaving(mainSessions(s), p, limit: 190_000)
        let applied = cfg.autoCompactWindow.flatMap { $0 <= 250_000 ? "autoCompactWindow is \(k(Double($0))) — new sessions compact early; this period's spend is from before." : nil }
        return Hint(
            id: .compact, title: "Compact before the context gets huge",
            finding: "Main-session turns ran at a median \(k(median)) context (peak \(k(peak))); \(Int((total > 0 ? big / total : 0) * 100))% of spend went on turns above 200k. Every turn re-reads the whole context.",
            savingUSD: saving,
            fix: "Auto-compact at 200k instead of Opus 5.5's ~967k default (about \(n) compactions in this period), or /compact at natural breakpoints.",
            snippet: "\"autoCompactWindow\": 200000",
            caveat: "Compaction replaces history with a summary; long intricate sessions can lose earlier decisions.",
            applied: applied)
    }

    // MARK: 2. Resuming after a break

    static func resume(_ s: [RequestSample], _ p: PricingTable) -> Hint? {
        let rebuilds = s.filter { $0.rebuild == .afterIdle }
        guard rebuilds.count >= 3 else { return nil }
        // What the cache rewrite cost, minus what writing a fresh 40k start would have.
        let cost = rebuilds.reduce(0.0) { acc, x in
            let r = rates(x.model, p)
            let w1 = Double(x.cacheWrite1h), w5 = Double(x.cacheWrite) - w1
            let fresh = min(Double(x.cacheWrite), 40_000) * r.write1h
            return acc + max(w1 * r.write1h + w5 * r.write5m - fresh, 0)
        }
        let median = PerformanceStats.quantile(rebuilds.map { Double($0.cacheWrite) }, 0.5) ?? 0
        return Hint(
            id: .resume, title: "Don't resume big sessions after a break",
            finding: "\(rebuilds.count) times a session sat idle over an hour and the whole cache (median \(k(median)) tokens) was written again at the cache-write rate.",
            savingUSD: cost,
            fix: "Before stepping away, run /compact so less has to be rewritten; after a long break, /clear and continue from a short handoff note.",
            snippet: "/compact",
            caveat: "A fresh start loses whatever the handoff note doesn't capture.",
            applied: nil)
    }

    // MARK: 3. Cache TTL

    static func cacheTTL(_ s: [RequestSample], _ p: PricingTable, _ cfg: ClaudeSettingsSnapshot) -> Hint? {
        var waste = 0.0, bridged = 0.0, quick = 0, total1h = 0
        for rows in mainSessions(s) {
            for (a, b) in zip(rows, rows.dropFirst()) where a.cacheWrite1h > 0 {
                let r = rates(a.model, p)
                let gap = b.time.timeIntervalSince(a.time)
                total1h += 1
                if gap < 300 {
                    // A 5-minute write would have been read in time.
                    waste += Double(a.cacheWrite1h) * (r.write1h - r.write5m); quick += 1
                } else if gap < 3600 {
                    // Here the 1h TTL avoided rewriting what b read.
                    bridged += Double(b.cacheRead) * (r.write5m - r.read)
                }
            }
        }
        guard total1h > 0, waste > 2 * bridged else { return nil }
        return Hint(
            id: .cacheTTL, title: "Use the 5-minute prompt cache",
            finding: "\(Int(Double(quick) / Double(total1h) * 100))% of 1-hour cache writes were read again within 5 minutes, so the cheaper 5-minute cache would have done. The 1-hour TTL bridged longer pauses worth only ~\(usd(bridged)).",
            savingUSD: waste - bridged,
            fix: "Set the main conversation's cache TTL to 5 minutes (1h is the automatic choice on a subscription).",
            snippet: "\"promptCacheTtl\": \"5m\"",
            caveat: "Any pause over 5 minutes then means rewriting the cache.",
            applied: cfg.promptCacheTtl == "5m" ? "promptCacheTtl is 5m." : nil)
    }

    // MARK: 4. Subagent model

    static let cheapSubagentModel = "claude-sonnet-5"

    static func subagentModel(_ s: [RequestSample], _ p: PricingTable, _ cfg: ClaudeSettingsSnapshot) -> Hint? {
        let cheap = rates(cheapSubagentModel, p).input
        guard cheap > 0 else { return nil }
        var saving = 0.0, spend = 0.0
        var byModel: [String: Double] = [:]
        for x in s where x.isSubagent {
            let c = x.cost(p), r = rates(x.model, p).input
            guard r > cheap else { continue }
            spend += c; byModel[x.model, default: 0] += c
            saving += c * (1 - cheap / r)
        }
        guard spend > 0 else { return nil }
        let top = byModel.sorted { $0.value > $1.value }.prefix(3).map { "\(short($0.key)) \(usd($0.value))" }.joined(separator: ", ")
        return Hint(
            id: .subagentModel, title: "Run subagents on Sonnet",
            finding: "Subagents spent \(usd(spend)) on models pricier than Sonnet (\(top)). Most subagent work is search and summarising.",
            savingUSD: saving,
            fix: "Default subagents to Sonnet; give a specific agent a bigger model in its frontmatter (model: opus) when it needs one.",
            snippet: "\"env\": { \"CLAUDE_CODE_SUBAGENT_MODEL\": \"\(cheapSubagentModel)\" }",
            caveat: "Harder delegated tasks (reviews, design) may do worse on a smaller model.",
            applied: cfg.subagentModel.map { "CLAUDE_CODE_SUBAGENT_MODEL is \($0)." })
    }

    // MARK: 5. Main model

    static func mainModel(_ s: [RequestSample], _ p: PricingTable, _ cfg: ClaudeSettingsSnapshot) -> Hint? {
        let main = s.filter { !$0.isSubagent }
        let models = Set(main.map(\.model))
        // Cheapest Opus actually in use is the reference; anything over 1.5× its input price is "premium".
        guard let ref = models.filter({ $0.contains("opus") }).min(by: { rates($0, p).input < rates($1, p).input }) else { return nil }
        let refIn = rates(ref, p).input
        guard refIn > 0 else { return nil }
        var spend = 0.0, saving = 0.0, n = 0
        var names = Set<String>()
        for x in main {
            let r = rates(x.model, p).input
            guard r > 1.5 * refIn else { continue }
            let c = x.cost(p)
            spend += c; saving += c * (1 - refIn / r); n += 1; names.insert(short(x.model))
        }
        guard n > 0 else { return nil }
        return Hint(
            id: .mainModel, title: "Keep \(short(ref)) as the default model",
            finding: "\(n) main-session requests (\(usd(spend))) ran on \(names.sorted().joined(separator: ", ")), at over 1.5× \(short(ref))'s price per token.",
            savingUSD: saving,
            fix: "Make \(short(ref)) the default and switch with /model only for the problems that need the bigger model.",
            snippet: "\"model\": \"\(ref)\"",
            caveat: "The bigger model may solve hard problems in fewer turns; switch per task rather than never.",
            applied: cfg.model == ref ? "model is \(ref)." : nil)
    }

    // MARK: 6. Effort

    static func effort(_ s: [RequestSample], _ p: PricingTable, _ cfg: ClaudeSettingsSnapshot) -> Hint? {
        let high = s.filter { ["high", "xhigh"].contains($0.effort ?? "") }
        let medium = s.filter { $0.effort == "medium" }
        // Need both sides to measure what dropping a level does to output.
        guard high.count >= 200, medium.count >= 200,
              let hiOut = PerformanceStats.quantile(high.map { Double($0.output) }, 0.5),
              let medOut = PerformanceStats.quantile(medium.map { Double($0.output) }, 0.5),
              hiOut > medOut else { return nil }
        let shrink = 1 - medOut / hiOut
        var saving = 0.0
        var byModel: [String: Int] = [:]
        for x in high {
            saving += Double(x.output) * rates(x.model, p).output * shrink
            byModel[x.model, default: 0] += 1
        }
        let top = byModel.max { $0.value < $1.value }!.key
        return Hint(
            id: .effort, title: "Lower the effort level",
            finding: "\(high.count) requests ran at high/xhigh effort (mostly \(short(top))). They produced a median \(Int(hiOut)) output tokens vs \(Int(medOut)) at medium.",
            savingUSD: saving,
            fix: "Run \(short(top)) at medium by default and raise it with /effort for hard problems.",
            snippet: "\"modelSettings\": { \"\(top)\": { \"effortLevel\": \"medium\" } }",
            caveat: "Only counts output tokens; harder problems may need the extra thinking.",
            applied: cfg.effort(for: top) == "medium" ? "\(short(top)) is set to medium." : nil)
    }

    static func short(_ m: String) -> String { m.hasPrefix("claude-") ? String(m.dropFirst(7)) : m }
}
