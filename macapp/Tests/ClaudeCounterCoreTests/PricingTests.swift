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
}
