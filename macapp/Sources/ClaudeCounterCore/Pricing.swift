import Foundation

/// Token counts for one billable event.
/// Mirrors `pricing.Usage` in the Go implementation. UInt64 end-to-end
/// so accumulation across thousands of events stays exact.
public struct Usage: Equatable, Hashable, Sendable {
    public var input: UInt64
    public var output: UInt64
    public var cacheCreate: UInt64
    public var cacheRead: UInt64

    public init(input: UInt64 = 0, output: UInt64 = 0, cacheCreate: UInt64 = 0, cacheRead: UInt64 = 0) {
        self.input = input
        self.output = output
        self.cacheCreate = cacheCreate
        self.cacheRead = cacheRead
    }
}

/// Per-model pricing in USD per 1M tokens. Matches `pricing.ModelPrice` in Go.
public struct ModelPrice: Equatable, Hashable, Sendable, Codable {
    public var inputPerMTok: Double
    public var outputPerMTok: Double
    public var cacheCreationPerMTok: Double
    public var cacheReadPerMTok: Double

    public init(inputPerMTok: Double, outputPerMTok: Double, cacheCreationPerMTok: Double, cacheReadPerMTok: Double) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheCreationPerMTok = cacheCreationPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
    }
}

/// Lookup of model name → pricing. Mirrors `pricing.Table`.
public struct PricingTable: Equatable, Sendable {
    public var models: [String: ModelPrice]

    public init(models: [String: ModelPrice] = [:]) {
        self.models = models
    }

    /// `true` if we have a price entry for this model.
    public func has(model: String) -> Bool {
        models[model] != nil
    }

    /// Compute USD cost for the given token counts under this model's price.
    /// Returns 0 for unknown models — caller is expected to track unknowns
    /// separately (see Aggregator's unknownMsgs counter).
    ///
    /// Formula matches `internal/pricing.Table.Cost` byte-for-byte:
    ///   cost = sum_i (tokens_i / 1_000_000 * price_per_mtok_i)
    public func cost(model: String, usage: Usage) -> Double {
        guard let p = models[model] else { return 0 }
        let m = 1_000_000.0
        return Double(usage.input)        / m * p.inputPerMTok +
               Double(usage.output)       / m * p.outputPerMTok +
               Double(usage.cacheCreate)  / m * p.cacheCreationPerMTok +
               Double(usage.cacheRead)    / m * p.cacheReadPerMTok
    }
}

// MARK: - Defaults (port of internal/pricing/defaults.go)

extension PricingTable {

    /// ISO date the baked-in prices were captured. Update when bumping prices.
    public static let defaultsDate = "2026-04-24"

    /// Best-effort price table used when no pricing.toml is available and
    /// live fetch also fails.
    /// Source: LiteLLM's model_prices_and_context_window.json (same table
    /// ccusage uses). Cache-creation rate is the 5-minute TTL multiplier
    /// (1.25× input) — LiteLLM does not split by TTL.
    public static let defaults: PricingTable = {
        let opus = ModelPrice(
            inputPerMTok: 5.00,
            outputPerMTok: 25.00,
            cacheCreationPerMTok: 6.25,
            cacheReadPerMTok: 0.50
        )
        let sonnet = ModelPrice(
            inputPerMTok: 3.00,
            outputPerMTok: 15.00,
            cacheCreationPerMTok: 3.75,
            cacheReadPerMTok: 0.30
        )
        let haiku = ModelPrice(
            inputPerMTok: 1.00,
            outputPerMTok: 5.00,
            cacheCreationPerMTok: 1.25,
            cacheReadPerMTok: 0.10
        )
        return PricingTable(models: [
            "claude-opus-4-7":           opus,
            "claude-opus-4-6":           opus,
            "claude-opus-4-5":           opus,
            "claude-sonnet-4-6":         sonnet,
            "claude-sonnet-4-5":         sonnet,
            "claude-haiku-4-5":          haiku,
            "claude-haiku-4-5-20251001": haiku,
        ])
    }()
}
