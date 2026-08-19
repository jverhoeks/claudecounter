import XCTest
@testable import ClaudeCounterCore

final class PricingTests: XCTestCase {

    // MARK: - Cost math

    func test_cost_zeroUsage_isZero() {
        let table = PricingTable.defaults
        let usage = Usage(input: 0, output: 0, cacheCreate: 0, cacheRead: 0)
        XCTAssertEqual(table.cost(model: "claude-opus-4-7", usage: usage), 0.0, accuracy: 1e-12)
    }

    func test_cost_unknownModel_isZero() {
        let table = PricingTable.defaults
        let usage = Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 0, cacheRead: 0)
        XCTAssertEqual(table.cost(model: "claude-fictional-9-9", usage: usage), 0.0, accuracy: 1e-12)
    }

    func test_cost_opus_oneMillionInOut_matchesGoFormula() {
        // Opus 4.x: $5/M input, $25/M output, $6.25/M cache_create, $0.50/M cache_read.
        // 1M in + 1M out → $5 + $25 = $30
        let table = PricingTable.defaults
        let usage = Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 0, cacheRead: 0)
        XCTAssertEqual(table.cost(model: "claude-opus-4-7", usage: usage), 30.0, accuracy: 1e-9)
    }

    func test_cost_sonnet_allFourTokenTypes_matchesGoFormula() {
        // Sonnet: $3/M in, $15/M out, $3.75/M cache_create, $0.30/M cache_read.
        // 1M in + 1M out + 1M cc + 1M cr → 3 + 15 + 3.75 + 0.30 = 22.05
        let table = PricingTable.defaults
        let usage = Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 1_000_000, cacheRead: 1_000_000)
        XCTAssertEqual(table.cost(model: "claude-sonnet-4-6", usage: usage), 22.05, accuracy: 1e-9)
    }

    func test_cost_haiku_partialTokens_isPropertional() {
        // Haiku: $1/M in. 500k in → $0.50
        let table = PricingTable.defaults
        let usage = Usage(input: 500_000, output: 0, cacheCreate: 0, cacheRead: 0)
        XCTAssertEqual(table.cost(model: "claude-haiku-4-5", usage: usage), 0.50, accuracy: 1e-9)
    }

    // MARK: - has(model:)

    func test_has_knownModel_isTrue() {
        XCTAssertTrue(PricingTable.defaults.has(model: "claude-opus-4-7"))
        XCTAssertTrue(PricingTable.defaults.has(model: "claude-sonnet-4-6"))
        XCTAssertTrue(PricingTable.defaults.has(model: "claude-haiku-4-5"))
    }

    func test_has_unknownModel_isFalse() {
        XCTAssertFalse(PricingTable.defaults.has(model: "claude-fictional-9-9"))
        XCTAssertFalse(PricingTable.defaults.has(model: ""))
    }

    // MARK: - defaults coverage

    func test_defaults_coversFullModelFamily() {
        let expected = [
            "claude-opus-4-7",
            "claude-opus-4-6",
            "claude-opus-4-5",
            "claude-sonnet-4-6",
            "claude-sonnet-4-5",
            "claude-haiku-4-5",
            "claude-haiku-4-5-20251001",
        ]
        for model in expected {
            XCTAssertTrue(PricingTable.defaults.has(model: model), "missing \(model)")
        }
    }

    func test_defaultsDate_isPresent() {
        XCTAssertFalse(PricingTable.defaultsDate.isEmpty)
    }

    // MARK: - model aliases (mirrors pricing.modelAliases / resolve in Go)

    // Covers the defect this alias exists to fix: codex-auto-review has no
    // LiteLLM entry of its own, so it must be found only by resolving
    // through the alias to gpt-5.6-luna, the model it actually bills at.
    func test_alias_hasResolvesCodexAutoReview_whenAliasedModelPresent() {
        let table = PricingTable(models: [
            "gpt-5.6-luna": ModelPrice(inputPerMTok: 0.20, outputPerMTok: 1.20,
                                        cacheCreationPerMTok: 0, cacheReadPerMTok: 0)
        ])
        XCTAssertTrue(table.has(model: "codex-auto-review"),
                      "has(codex-auto-review) should resolve via alias to gpt-5.6-luna")
    }

    func test_alias_hasIsFalse_whenAliasedModelAbsent() {
        let table = PricingTable(models: [
            "claude-opus-4-8": ModelPrice(inputPerMTok: 5, outputPerMTok: 25,
                                           cacheCreationPerMTok: 0, cacheReadPerMTok: 0)
        ])
        XCTAssertFalse(table.has(model: "codex-auto-review"),
                       "gpt-5.6-luna is not in the table, so the alias must not resolve")
    }

    // Cost("codex-auto-review", u) must equal Cost("gpt-5.6-luna", u)
    // exactly, for a usage with non-zero input, output, and cache-read
    // tokens.
    func test_alias_costMatchesAliasedModel() {
        let table = PricingTable(models: [
            "gpt-5.6-luna": ModelPrice(inputPerMTok: 0.20, outputPerMTok: 1.20,
                                        cacheCreationPerMTok: 0, cacheReadPerMTok: 0.02)
        ])
        let usage = Usage(input: 5_900_000, output: 120_000, cacheCreate: 0, cacheRead: 30_600_000)
        let got = table.cost(model: "codex-auto-review", usage: usage)
        let want = table.cost(model: "gpt-5.6-luna", usage: usage)
        XCTAssertEqual(got, want)
        XCTAssertNotEqual(got, 0)
    }

    // Guards against an alias applied too eagerly: if a table happens to
    // carry its own entry for an alias's key (e.g. a future LiteLLM
    // release adds a real codex-auto-review row), that direct entry must
    // win rather than being shadowed by the redirect to gpt-5.6-luna.
    func test_alias_directEntryWinsOverAlias() {
        let table = PricingTable(models: [
            "codex-auto-review": ModelPrice(inputPerMTok: 99, outputPerMTok: 99,
                                             cacheCreationPerMTok: 0, cacheReadPerMTok: 0),
            "gpt-5.6-luna": ModelPrice(inputPerMTok: 0.20, outputPerMTok: 1.20,
                                       cacheCreationPerMTok: 0, cacheReadPerMTok: 0)
        ])
        XCTAssertTrue(table.has(model: "codex-auto-review"))
        let usage = Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 0, cacheRead: 0)
        XCTAssertEqual(table.cost(model: "codex-auto-review", usage: usage), 99.0 + 99.0,
                      accuracy: 1e-9, "direct entry must win over the alias")
    }

    // Guards against the alias resolution path interfering with ordinary,
    // non-aliased lookups.
    func test_alias_claudeModelsUnaffected() {
        let table = PricingTable(models: [
            "claude-opus-4-8": ModelPrice(inputPerMTok: 5, outputPerMTok: 25,
                                           cacheCreationPerMTok: 0, cacheReadPerMTok: 0)
        ])
        XCTAssertTrue(table.has(model: "claude-opus-4-8"))
        XCTAssertFalse(table.has(model: "claude-sonnet-4-6"),
                       "not in this table and not an alias key")
        let usage = Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 0, cacheRead: 0)
        XCTAssertEqual(table.cost(model: "claude-opus-4-8", usage: usage), 5.0 + 25.0, accuracy: 1e-9)
    }

    // MARK: - Claude 5 family and the [1m] long-context suffix

    // Covers the release defect these entries exist to fix: claude-opus-5
    // and claude-sonnet-5 were the two most-used models in real logs yet
    // had no defaults row, so any install without a pricing override (or
    // with a failed live fetch) priced ~85% of its traffic at $0.
    // Mirrors Go's TestDefaults_CoversClaude5Family.
    func test_defaults_coversClaude5Family() {
        let table = PricingTable.defaults
        for model in ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5"] {
            XCTAssertTrue(table.has(model: model), "defaults missing price for \(model)")
        }
        let opus5 = table.models["claude-opus-5"]
        XCTAssertEqual(opus5?.inputPerMTok, 5.00)
        XCTAssertEqual(opus5?.outputPerMTok, 25.00)
        // Mythos 5 bills at the Fable tier, above Opus.
        let mythos = table.models["claude-mythos-5"]
        XCTAssertEqual(mythos?.inputPerMTok, 10.00)
        XCTAssertEqual(mythos?.outputPerMTok, 50.00)
    }

    // Turns logged with the 1M-context window (e.g. "claude-opus-5[1m]")
    // have no row in any pricing source, so without the suffix strip they
    // billed at $0. Mirrors Go's TestLongContextSuffix_PricesAtBaseRate.
    func test_longContextSuffix_pricesAtBaseRate() {
        let table = PricingTable.defaults
        let usage = Usage(input: 1_000_000, output: 1_000_000, cacheCreate: 0, cacheRead: 0)
        for base in ["claude-opus-5", "claude-opus-4-8", "claude-sonnet-5"] {
            let long = base + "[1m]"
            XCTAssertTrue(table.has(model: long), "has(\(long)) must be true")
            XCTAssertEqual(table.cost(model: long, usage: usage),
                           table.cost(model: base, usage: usage),
                           accuracy: 1e-9,
                           "\(long) must price at the base rate")
        }
        // The strip must not invent prices for unknown models.
        XCTAssertFalse(table.has(model: "claude-nonexistent-9[1m]"))
    }

    // A real [1m] row must win over the stripped fallback, so a future
    // pricing source that does tier by context length is not shadowed.
    func test_longContextSuffix_directRowWinsOverStrip() {
        let table = PricingTable(models: [
            "claude-opus-5": ModelPrice(inputPerMTok: 5, outputPerMTok: 0,
                                        cacheCreationPerMTok: 0, cacheReadPerMTok: 0),
            "claude-opus-5[1m]": ModelPrice(inputPerMTok: 10, outputPerMTok: 0,
                                            cacheCreationPerMTok: 0, cacheReadPerMTok: 0)
        ])
        let usage = Usage(input: 1_000_000, output: 0, cacheCreate: 0, cacheRead: 0)
        XCTAssertEqual(table.cost(model: "claude-opus-5[1m]", usage: usage), 10.0,
                       accuracy: 1e-9, "direct [1m] row must win over the fallback")
    }
}
