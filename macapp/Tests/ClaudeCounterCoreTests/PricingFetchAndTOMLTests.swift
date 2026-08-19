import XCTest
@testable import ClaudeCounterCore

final class PricingFetchAndTOMLTests: XCTestCase {

    // MARK: - TOML decode

    func test_toml_decode_threeModels() {
        let body = """
        [models."claude-opus-4-7"]
        input_per_mtok          = 5.00
        output_per_mtok         = 25.00
        cache_creation_per_mtok = 6.25
        cache_read_per_mtok     = 0.50

        [models."claude-sonnet-4-6"]
        input_per_mtok = 3.00
        output_per_mtok = 15.00
        cache_creation_per_mtok = 3.75
        cache_read_per_mtok = 0.30

        # comment line
        [models."claude-haiku-4-5"]
        input_per_mtok          = 1.00
        output_per_mtok         = 5.00
        cache_creation_per_mtok = 1.25
        cache_read_per_mtok     = 0.10
        """
        let table = TOMLPricing.decode(body)
        XCTAssertEqual(table.models.count, 3)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.inputPerMTok, 5.00)
        XCTAssertEqual(table.models["claude-sonnet-4-6"]?.outputPerMTok, 15.00)
        XCTAssertEqual(table.models["claude-haiku-4-5"]?.cacheReadPerMTok, 0.10)
    }

    func test_toml_decode_unknownHeader_isIgnored() {
        let body = """
        [unrelated]
        foo = 1.0

        [models."claude-opus-4-7"]
        input_per_mtok          = 5.00
        """
        let table = TOMLPricing.decode(body)
        XCTAssertNotNil(table.models["claude-opus-4-7"])
    }

    func test_toml_roundTrip() {
        let original = PricingTable.defaults
        let encoded = TOMLPricing.encode(original)
        let decoded = TOMLPricing.decode(encoded)
        XCTAssertEqual(decoded.models.count, original.models.count)
        for name in original.models.keys {
            XCTAssertEqual(decoded.models[name]?.inputPerMTok,
                           original.models[name]?.inputPerMTok)
        }
    }

    // MARK: - schema marker (mirrors pricing.TableSchema / SaveTOML in Go)

    func test_currentSchema_isThree() {
        // Both surfaces must agree value for value — Go's TableSchema is 3
        // (2 admitted openai when parseLiteLLM's provider filter widened;
        // 3 forces one refetch for caches predating claude-opus-5 and
        // claude-sonnet-5 in LiteLLM), and the shared cache at
        // ~/.config/claudecounter/pricing.toml is written by whichever side
        // fetches first.
        XCTAssertEqual(PricingTable.currentSchema, 3)
    }

    func test_toml_decode_noSchemaLine_defaultsToZero() {
        let body = """
        [models."claude-opus-4-7"]
        input_per_mtok = 5.00
        """
        XCTAssertEqual(TOMLPricing.decode(body).schema, 0)
    }

    func test_toml_decode_schemaLineBeforeModels_isRead() {
        let body = """
        schema = 2

        [models."claude-opus-4-7"]
        input_per_mtok = 5.00
        """
        XCTAssertEqual(TOMLPricing.decode(body).schema, 2)
    }

    func test_toml_encode_alwaysWritesCurrentSchema_notInstanceSchema() {
        // encode must stamp PricingTable.currentSchema, not table.schema —
        // otherwise the "Refresh pricing" button (which calls fetch() then
        // writeToAppOverride()) would persist schema 0 forever, since a
        // freshly-parsed table's schema is 0 (see parseLiteLLM's Go
        // counterpart, which never stamps the in-memory Table either).
        let table = PricingTable(models: ["claude-opus-4-7": ModelPrice(
            inputPerMTok: 5, outputPerMTok: 25, cacheCreationPerMTok: 6.25, cacheReadPerMTok: 0.5)],
            schema: 0)
        let encoded = TOMLPricing.encode(table)
        XCTAssertEqual(TOMLPricing.decode(encoded).schema, PricingTable.currentSchema)
    }

    // MARK: - resolution paths

    func test_resolutionPaths_withXDG_includesXDGSubpath() {
        let env = ["XDG_CONFIG_HOME": "/tmp/test-xdg"]
        let paths = PricingTable.resolutionPaths(env: env)
        XCTAssertTrue(paths.contains { $0.path == "/tmp/test-xdg/claudecounter/pricing.toml" })
    }

    func test_resolutionPaths_withoutXDG_includesHomeDotConfig() {
        let env: [String: String] = [:]
        let paths = PricingTable.resolutionPaths(env: env)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(paths.contains { $0.path == "\(home)/.config/claudecounter/pricing.toml" })
    }

    // MARK: - LiteLLM JSON parse

    func test_liteLLM_parse_filtersAnthropic_andConvertsPerMTok() throws {
        // Updated for the provider widening: gpt-4 now survives (openai is
        // priced too — see test_liteLLM_parse_admitsOpenAI_dropsAzure for
        // the dedicated widening coverage). Mirrors Go's TestParseLiteLLM.
        let json = """
        {
          "claude-opus-4-7": {
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000025,
            "cache_creation_input_token_cost": 0.00000625,
            "cache_read_input_token_cost": 0.0000005,
            "litellm_provider": "anthropic"
          },
          "anthropic/claude-haiku-4-5": {
            "input_cost_per_token": 0.000001,
            "output_cost_per_token": 0.000005,
            "litellm_provider": "anthropic"
          },
          "gpt-4": {
            "input_cost_per_token": 0.000030,
            "output_cost_per_token": 0.000060,
            "litellm_provider": "openai"
          }
        }
        """
        let table = try PricingFetcher.parse(Data(json.utf8))
        XCTAssertEqual(table.models.count, 3, "openai is priced now, no longer filtered out")
        XCTAssertEqual(table.models["claude-opus-4-7"]?.inputPerMTok ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.outputPerMTok ?? 0, 25.0, accuracy: 1e-9)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.cacheCreationPerMTok ?? 0, 6.25, accuracy: 1e-9)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.cacheReadPerMTok ?? 0, 0.50, accuracy: 1e-9)
        // The "anthropic/" prefix should have been stripped.
        XCTAssertNotNil(table.models["claude-haiku-4-5"])
        XCTAssertNil(table.models["anthropic/claude-haiku-4-5"])
        XCTAssertEqual(table.models["gpt-4"]?.inputPerMTok ?? 0, 30.0, accuracy: 1e-9)
    }

    // Mirrors Go's TestParseLiteLLM_OpenAI: an anthropic entry, a
    // fully-priced openai entry, a zero-cost openai entry, and an azure
    // entry (still unsupported). Only the priced entries from the two
    // admitted providers should survive.
    func test_liteLLM_parse_admitsOpenAI_dropsAzure() throws {
        let json = """
        {
          "claude-opus-4-8": {
            "litellm_provider": "anthropic",
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000025,
            "cache_creation_input_token_cost": 0.00000625,
            "cache_read_input_token_cost": 0.0000005
          },
          "gpt-5.6-sol": {
            "litellm_provider": "openai",
            "input_cost_per_token": 0.0000015,
            "output_cost_per_token": 0.000006,
            "cache_creation_input_token_cost": 0,
            "cache_read_input_token_cost": 0.00000015
          },
          "gpt-5.6-zero": {
            "litellm_provider": "openai",
            "input_cost_per_token": 0,
            "output_cost_per_token": 0
          },
          "azure-gpt-5.6": {
            "litellm_provider": "azure",
            "input_cost_per_token": 0.0000015,
            "output_cost_per_token": 0.000006
          }
        }
        """
        let table = try PricingFetcher.parse(Data(json.utf8))
        XCTAssertEqual(table.models.count, 2, "anthropic + openai; zero-cost and azure dropped")

        let a = table.models["claude-opus-4-8"]
        XCTAssertEqual(a?.inputPerMTok ?? 0, 5.00, accuracy: 1e-9, "anthropic prices must be unchanged")
        XCTAssertEqual(a?.outputPerMTok ?? 0, 25.00, accuracy: 1e-9)
        XCTAssertEqual(a?.cacheCreationPerMTok ?? 0, 6.25, accuracy: 1e-9)
        XCTAssertEqual(a?.cacheReadPerMTok ?? 0, 0.50, accuracy: 1e-9)

        let o = table.models["gpt-5.6-sol"]
        XCTAssertNotNil(o, "openai entry with all four rates must survive")
        XCTAssertEqual(o?.inputPerMTok ?? 0, 1.50, accuracy: 1e-9)
        XCTAssertEqual(o?.outputPerMTok ?? 0, 6.00, accuracy: 1e-9)
        XCTAssertEqual(o?.cacheCreationPerMTok ?? 0, 0, accuracy: 1e-9)
        XCTAssertEqual(o?.cacheReadPerMTok ?? 0, 0.15, accuracy: 1e-9)

        XCTAssertNil(table.models["gpt-5.6-zero"], "zero-cost openai entry must be dropped")
        XCTAssertNil(table.models["azure-gpt-5.6"], "azure entry must be dropped (unsupported provider)")
    }

    // Replaces the old "openai filtered out entirely" empty-result case:
    // openai-only input is no longer an error (openai is priced now), so
    // the error path is exercised with a still-unsupported provider
    // (azure) plus a zero-cost openai entry. Mirrors Go's
    // TestParseLiteLLM_NoPricedModels.
    func test_liteLLM_parse_emptyResult_throws() {
        let json = """
        {
          "azure-gpt-5.6": {"litellm_provider": "azure", "input_cost_per_token": 0.00001, "output_cost_per_token": 0.00003},
          "gpt-5.6-zero": {"litellm_provider": "openai", "input_cost_per_token": 0, "output_cost_per_token": 0}
        }
        """
        XCTAssertThrowsError(try PricingFetcher.parse(Data(json.utf8))) { err in
            guard let e = err as? PricingFetcher.FetchError, case .noPricedModels = e else {
                return XCTFail("expected .noPricedModels, got \(err)")
            }
        }
    }

    func test_liteLLM_parse_corruptJSON_throws() {
        XCTAssertThrowsError(try PricingFetcher.parse(Data("not json".utf8)))
    }

    // MARK: - fetch with mock URLSession

    func test_fetch_usesMockSession_returnsParsedTable() async throws {
        let body = """
        {
          "claude-opus-4-7": {
            "input_cost_per_token": 0.000005,
            "output_cost_per_token": 0.000025,
            "litellm_provider": "anthropic"
          }
        }
        """
        let mock = MockSession(data: Data(body.utf8), response:
            HTTPURLResponse(url: PricingFetcher.liteLLMURL, statusCode: 200,
                            httpVersion: "HTTP/1.1", headerFields: nil)!)
        let table = try await PricingFetcher.fetch(session: mock)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.inputPerMTok ?? 0, 5.0, accuracy: 1e-9)
    }

    func test_fetch_non200_throwsHTTP() async throws {
        let mock = MockSession(data: Data(), response:
            HTTPURLResponse(url: PricingFetcher.liteLLMURL, statusCode: 503,
                            httpVersion: "HTTP/1.1", headerFields: nil)!)
        do {
            _ = try await PricingFetcher.fetch(session: mock)
            XCTFail("expected throw")
        } catch let e as PricingFetcher.FetchError {
            guard case .http(let code) = e else { return XCTFail("expected .http") }
            XCTAssertEqual(code, 503)
        }
    }
}

private struct MockSession: URLSessionProtocol {
    let data: Data
    let response: URLResponse
    func dataReturning(from url: URL) async throws -> (Data, URLResponse) {
        return (data, response)
    }
}
