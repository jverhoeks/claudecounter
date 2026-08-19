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

    /// Schema of the cache this table was loaded from: 0 for any cache
    /// written before the field existed (no "schema" key in the file at
    /// all, or a freshly-parsed LiteLLM fetch — see PricingFetcher.parse,
    /// which never stamps this either) or the schema recorded by a
    /// previous `writeToAppOverride`/Go `SaveTOML`. Mirrors `pricing.Table.Schema`.
    public var schema: Int

    /// currentSchema is bumped whenever PricingFetcher.parse's provider
    /// filter widens (or otherwise changes which models a fetch can
    /// produce). A cache saved under an older schema is stale in a way
    /// `!models.isEmpty` can't detect: it's a complete, valid table — just
    /// missing an entire provider's worth of models, which would silently
    /// price them at $0 forever. `AppState.refreshPricingIfStale` compares
    /// a loaded table's schema against this constant and refetches once
    /// when it's behind, rather than trusting any non-empty cache
    /// indefinitely. Mirrors `pricing.TableSchema` in Go — keep in sync.
    public static let currentSchema = 2

    public init(models: [String: ModelPrice] = [:], schema: Int = 0) {
        self.models = models
        self.schema = schema
    }

    /// `true` if model can be priced — directly or via alias. A model
    /// found only through the alias (e.g. codex-auto-review, resolving to
    /// gpt-5.6-luna) now counts as known here, which is the deliberate,
    /// desired effect on Aggregator's unknown tally: it is genuinely
    /// priced, so it should not be counted as unpriced. Mirrors
    /// `pricing.Table.Has` in Go.
    public func has(model: String) -> Bool {
        resolve(model: model) != nil
    }

    /// Compute USD cost for the given token counts under this model's price.
    /// Returns 0 for unknown models — caller is expected to track unknowns
    /// separately (see Aggregator's unknownMsgs counter).
    ///
    /// Formula matches `internal/pricing.Table.Cost` byte-for-byte:
    ///   cost = sum_i (tokens_i / 1_000_000 * price_per_mtok_i)
    public func cost(model: String, usage: Usage) -> Double {
        guard let p = resolve(model: model) else { return 0 }
        let m = 1_000_000.0
        return Double(usage.input)        / m * p.inputPerMTok +
               Double(usage.output)       / m * p.outputPerMTok +
               Double(usage.cacheCreate)  / m * p.cacheCreationPerMTok +
               Double(usage.cacheRead)    / m * p.cacheReadPerMTok
    }

    /// Returns the ModelPrice a model should be priced against: model's
    /// own entry if the table has one, otherwise its alias's entry (which
    /// may itself be absent), and failing both, whatever the same lookups
    /// find for the name with any [1m] long-context suffix removed. A
    /// direct entry always wins over the alias —
    /// see test_alias_directEntryWinsOverAlias — so a future LiteLLM
    /// release adding a real row for an aliased or [1m] name is never
    /// shadowed by the fallback. Mirrors `pricing.Table.resolve` in Go.
    private func resolve(model: String) -> ModelPrice? {
        if let p = lookup(model) { return p }
        if model.hasSuffix(longContextSuffix) {
            return lookup(String(model.dropLast(longContextSuffix.count)))
        }
        return nil
    }

    /// Tries model's own entry, then its alias's. Mirrors
    /// `pricing.Table.lookup` in Go.
    private func lookup(_ model: String) -> ModelPrice? {
        if let p = models[model] { return p }
        return models[aliasedModel(model)]
    }
}

/// Marks a turn that ran with the 1M-token context window enabled: Claude
/// Code logs those as e.g. "claude-opus-5[1m]". No pricing source keys
/// models this way — LiteLLM has no [1m] rows at all — so before this was
/// stripped, every such turn resolved to nothing and billed at $0.
///
/// Stripping is the correct fix rather than a separate rate because the
/// current 1M-context models price flat: LiteLLM carries no
/// *_above_200k_tokens premium for claude-opus-5, claude-opus-4-8,
/// claude-sonnet-5, claude-fable-5 or claude-mythos-5 (its only "above"
/// field is cache_creation_input_token_cost_above_1hr, a cache-TTL rate
/// unrelated to context length). If a future model does tier by context
/// length, that needs a real [1m] row, not this fallback. Mirrors
/// `pricing.longContextSuffix` in Go — keep in sync.
private let longContextSuffix = "[1m]"

/// modelAliases maps a display model name with no LiteLLM entry of its own
/// to the model it actually bills at. Codex's auto-review runs on GPT-5.6
/// Luna ($0.20/Mtok in, $1.20/Mtok out, owner-confirmed, matching LiteLLM
/// exactly) but the reader emits the display name codex-auto-review, which
/// has no pricing row — see aliasedModel. The displayed model name stays
/// codex-auto-review everywhere; only pricing is redirected.
///
/// This is a map rather than branching logic because the model behind a
/// display name like this is a moving target: a future Codex release edits
/// a map entry here, not the code that resolves it. Mirrors
/// `pricing.modelAliases` in Go — keep in sync.
private let modelAliases: [String: String] = ["codex-auto-review": "gpt-5.6-luna"]

/// aliasedModel resolves model through modelAliases, unconditionally. Every
/// model outside the map maps to itself, so has/cost can call this without
/// special-casing which names are aliased. Mirrors `pricing.aliasedModel`
/// in Go.
private func aliasedModel(_ model: String) -> String {
    modelAliases[model] ?? model
}

// MARK: - Defaults (port of internal/pricing/defaults.go)

extension PricingTable {

    /// ISO date the baked-in prices were captured. Update when bumping prices.
    public static let defaultsDate = "2026-08-19"

    /// Best-effort price table used when no pricing.toml is available and
    /// live fetch also fails.
    /// Source: LiteLLM's model_prices_and_context_window.json (same table
    /// ccusage uses). Cache-creation rate is the 5-minute TTL multiplier
    /// (1.25× input) — LiteLLM does not split by TTL.
    public static let defaults: PricingTable = {
        // Every Opus from 4.5 through 5: $5/$25/$6.25/$0.50 per 1M.
        let opus = ModelPrice(
            inputPerMTok: 5.00,
            outputPerMTok: 25.00,
            cacheCreationPerMTok: 6.25,
            cacheReadPerMTok: 0.50
        )
        // Sonnet's standard rate. Sonnet 5 carries a promotional $2/$10
        // through 2026-08-31, which LiteLLM tracks; these baked-in
        // defaults deliberately hold the list price, since a fallback
        // table outlives the intro window and under-reporting after it
        // lapses is worse than over-reporting during it.
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
        let fable = ModelPrice(
            inputPerMTok: 10.00,
            outputPerMTok: 50.00,
            cacheCreationPerMTok: 12.50,
            cacheReadPerMTok: 1.00
        )
        return PricingTable(models: [
            "claude-fable-5":            fable,
            "claude-mythos-5":           fable,
            "claude-opus-5":             opus,
            "claude-sonnet-5":           sonnet,
            "claude-opus-4-8":           opus,
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
