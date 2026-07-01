import Foundation

// MARK: - Warnings

/// The set of warning conditions a live session can be in. Rendered as
/// badge glyphs in the popover; the `.context` and `.cache` members also
/// drive macOS notifications (see `Notifications.swift`).
public struct SessionWarnings: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Conversation has grown past the turn-count threshold.
    public static let turns   = SessionWarnings(rawValue: 1 << 0)
    /// Latest turn's context is near the (inferred) window limit.
    public static let context = SessionWarnings(rawValue: 1 << 1)
    /// Session has spent a lot re-creating prompt cache.
    public static let cache   = SessionWarnings(rawValue: 1 << 2)

    public var isEmpty: Bool { rawValue == 0 }
}

// MARK: - Thresholds

/// Tunable limits that turn raw session metrics into warnings. Sourced
/// from `AppSettings` at snapshot time so the user can retune without a
/// tracker rebuild.
public struct SessionThresholds: Sendable, Equatable {
    /// A session is "active" if its last turn is within this window.
    public var activeWindow: TimeInterval
    /// `.turns` fires when main-turn count exceeds this.
    public var turnWarnCount: Int
    /// `.context` fires when context / window exceeds this fraction.
    public var contextWarnPct: Double
    /// `.cache` fires when cache-creation cost in the trailing 5 minutes
    /// exceeds this many USD. A *rate*, not a session total — a healthy
    /// session's cumulative cache-creation cost only ever grows, so a
    /// cumulative threshold would pin the warning on permanently. The rate
    /// instead flags a session actively thrashing its prompt cache and
    /// clears once it settles.
    public var cacheWarnUSD: Double

    public init(activeWindow: TimeInterval = 30 * 60,
                turnWarnCount: Int = 150,
                contextWarnPct: Double = 0.80,
                cacheWarnUSD: Double = 2.00) {
        self.activeWindow = activeWindow
        self.turnWarnCount = turnWarnCount
        self.contextWarnPct = contextWarnPct
        self.cacheWarnUSD = cacheWarnUSD
    }

    public static let defaults = SessionThresholds()
}

// MARK: - Context window inference

/// Best-effort context-window limit for a session. Defaults to the
/// standard 200k window; if a session has ever presented a context larger
/// than that, it must be running under the 1M beta, so return 1M. Mirrors
/// the claudeinsights "infer 1M window from peak" rule rather than
/// hardcoding a per-model table that would drift as models ship.
public func inferredContextWindow(peakContextTokens: UInt64) -> UInt64 {
    peakContextTokens > 200_000 ? 1_000_000 : 200_000
}

// MARK: - Snapshot type

/// A UI/notification-facing snapshot of one live session. Immutable and
/// `Sendable` so it crosses the actor boundary into `@MainActor` state.
public struct SessionStat: Equatable, Sendable, Identifiable {
    public var id: String { sessionID }
    public let sessionID: String
    public let project: String
    public let model: String
    /// Total session cost (main + subagent turns).
    public let costUSD: Double
    /// Cost of turns within the trailing 5 minutes.
    public let cost5mUSD: Double
    /// Cache-creation cost within the trailing 5 minutes (the `.cache`
    /// warning metric).
    public let cacheCreate5mUSD: Double
    /// Latest main turn's context occupancy (input + cache read + cache create).
    public let contextTokens: UInt64
    /// Inferred window limit for the session's model(s).
    public let contextWindow: UInt64
    /// `contextTokens / contextWindow`, clamped to 0…1.
    public let contextPct: Double
    /// Total cost attributable to cache creation over the whole session
    /// (cumulative; shown for context, not used for the warning).
    public let cacheCreateCostUSD: Double
    /// Number of billable main (non-subagent) turns.
    public let turns: Int
    /// Wall-clock age, first turn → last turn, in seconds.
    public let ageSeconds: Int
    public let warnings: SessionWarnings

    public init(sessionID: String, project: String, model: String,
                costUSD: Double, cost5mUSD: Double, cacheCreate5mUSD: Double,
                contextTokens: UInt64, contextWindow: UInt64, contextPct: Double,
                cacheCreateCostUSD: Double, turns: Int, ageSeconds: Int,
                warnings: SessionWarnings) {
        self.sessionID = sessionID
        self.project = project
        self.model = model
        self.costUSD = costUSD
        self.cost5mUSD = cost5mUSD
        self.cacheCreate5mUSD = cacheCreate5mUSD
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPct = contextPct
        self.cacheCreateCostUSD = cacheCreateCostUSD
        self.turns = turns
        self.ageSeconds = ageSeconds
        self.warnings = warnings
    }
}

// MARK: - Tracker

/// Per-session accumulator over the same `UsageEvent` stream the
/// `Aggregator` consumes. Kept separate because the aggregator sums tokens
/// and discards "latest turn" / session identity — both of which this
/// feature needs (context size = latest main turn; age = main-turn count).
///
/// Fed only on non-duplicate events (see `Aggregator.apply` return value),
/// so turn counts and costs are never double-counted.
public actor SessionTracker {

    /// Trailing window used for the "last 5 minutes" cost column.
    private static let recentWindow: TimeInterval = 5 * 60
    /// Sessions idle longer than this are dropped at snapshot — they can
    /// never be "active" and keeping them would grow memory unbounded.
    private static let pruneAge: TimeInterval = 6 * 3600

    private var pricing: PricingTable
    private var sessions: [String: SessionAgg] = [:]

    public init(pricing: PricingTable) {
        self.pricing = pricing
    }

    public func setPricing(_ table: PricingTable) {
        self.pricing = table
    }

    public func reset() {
        sessions.removeAll(keepingCapacity: true)
    }

    /// Per-session running state. Cost is accumulated incrementally;
    /// context/turns come only from main turns; the trailing `recent`
    /// list is pruned to the 5-minute window on every apply.
    private struct SessionAgg {
        var sessionID: String
        var project: String
        var latestMainModel: String
        var firstTS: Date
        var lastTS: Date
        var mainTurns: Int
        var subTurns: Int
        var totalCostUSD: Double
        var cacheCreateCostUSD: Double
        var latestMainTS: Date
        var latestMainContextTokens: UInt64
        var peakContextTokens: UInt64
        var recent: [(ts: Date, usd: Double, cacheUSD: Double)]
    }

    /// Fold one event into its session. `ev` must already be de-duplicated.
    public func apply(_ ev: UsageEvent) {
        let usd = pricing.cost(model: ev.model, usage: ev.usage)
        let cacheUSD = pricing.cost(model: ev.model,
                                    usage: Usage(cacheCreate: ev.usage.cacheCreate))

        var s = sessions[ev.sessionID] ?? SessionAgg(
            sessionID: ev.sessionID,
            project: ev.project,
            latestMainModel: ev.model,
            firstTS: ev.timestamp,
            lastTS: ev.timestamp,
            mainTurns: 0,
            subTurns: 0,
            totalCostUSD: 0,
            cacheCreateCostUSD: 0,
            latestMainTS: .distantPast,
            latestMainContextTokens: 0,
            peakContextTokens: 0,
            recent: []
        )

        // A subagent's transcript can be the first line seen for a
        // session; keep the project label but never let it define context.
        if s.project.isEmpty { s.project = ev.project }

        s.firstTS = min(s.firstTS, ev.timestamp)
        s.lastTS = max(s.lastTS, ev.timestamp)
        s.totalCostUSD += usd
        s.cacheCreateCostUSD += cacheUSD

        s.recent.append((ts: ev.timestamp, usd: usd, cacheUSD: cacheUSD))
        // Prune trailing list against the newest timestamp seen so it stays
        // bounded even for a long-lived session.
        let cutoff = s.lastTS.addingTimeInterval(-Self.recentWindow)
        s.recent.removeAll { $0.ts < cutoff }

        if ev.isSubagent {
            s.subTurns += 1
        } else {
            s.mainTurns += 1
            let ctx = ev.usage.input &+ ev.usage.cacheRead &+ ev.usage.cacheCreate
            s.peakContextTokens = max(s.peakContextTokens, ctx)
            // Latest MAIN turn by TIMESTAMP — not apply order. The Reader
            // applies subagent files before the main file for dedup, so
            // apply order does not track wall-clock recency.
            if ev.timestamp >= s.latestMainTS {
                s.latestMainTS = ev.timestamp
                s.latestMainModel = ev.model
                s.latestMainContextTokens = ctx
            }
        }

        sessions[ev.sessionID] = s
    }

    /// Active sessions as of `now`, sorted by trailing-5-minute cost
    /// (hottest first). Prunes long-idle sessions as a side effect.
    public func snapshot(now: Date, thresholds: SessionThresholds) -> [SessionStat] {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastTS) <= Self.pruneAge }

        var out: [SessionStat] = []
        let recentCutoff = now.addingTimeInterval(-Self.recentWindow)
        for (_, s) in sessions {
            guard now.timeIntervalSince(s.lastTS) <= thresholds.activeWindow else { continue }

            let cost5m = s.recent.reduce(0.0) { $0 + ($1.ts >= recentCutoff ? $1.usd : 0) }
            let cacheCreate5m = s.recent.reduce(0.0) { $0 + ($1.ts >= recentCutoff ? $1.cacheUSD : 0) }
            let window = inferredContextWindow(peakContextTokens: s.peakContextTokens)
            let pct = window > 0
                ? min(1.0, Double(s.latestMainContextTokens) / Double(window))
                : 0

            var w: SessionWarnings = []
            if s.mainTurns > thresholds.turnWarnCount { w.insert(.turns) }
            if pct > thresholds.contextWarnPct { w.insert(.context) }
            if cacheCreate5m > thresholds.cacheWarnUSD { w.insert(.cache) }

            out.append(SessionStat(
                sessionID: s.sessionID,
                project: s.project,
                model: s.latestMainModel,
                costUSD: s.totalCostUSD,
                cost5mUSD: cost5m,
                cacheCreate5mUSD: cacheCreate5m,
                contextTokens: s.latestMainContextTokens,
                contextWindow: window,
                contextPct: pct,
                cacheCreateCostUSD: s.cacheCreateCostUSD,
                turns: s.mainTurns,
                ageSeconds: max(0, Int(s.lastTS.timeIntervalSince(s.firstTS))),
                warnings: w
            ))
        }
        return out.sorted { $0.cost5mUSD > $1.cost5mUSD }
    }
}
