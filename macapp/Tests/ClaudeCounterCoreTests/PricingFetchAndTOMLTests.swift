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
        XCTAssertEqual(table.models.count, 2, "openai should be filtered out")
        XCTAssertEqual(table.models["claude-opus-4-7"]?.inputPerMTok ?? 0, 5.0, accuracy: 1e-9)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.outputPerMTok ?? 0, 25.0, accuracy: 1e-9)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.cacheCreationPerMTok ?? 0, 6.25, accuracy: 1e-9)
        XCTAssertEqual(table.models["claude-opus-4-7"]?.cacheReadPerMTok ?? 0, 0.50, accuracy: 1e-9)
        // The "anthropic/" prefix should have been stripped.
        XCTAssertNotNil(table.models["claude-haiku-4-5"])
        XCTAssertNil(table.models["anthropic/claude-haiku-4-5"])
    }

    func test_liteLLM_parse_emptyResult_throws() {
        let json = #"{"gpt-4": {"litellm_provider": "openai"}}"#
        XCTAssertThrowsError(try PricingFetcher.parse(Data(json.utf8))) { err in
            guard let e = err as? PricingFetcher.FetchError, case .noAnthropicModels = e else {
                return XCTFail("expected .noAnthropicModels, got \(err)")
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
