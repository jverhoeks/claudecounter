import Foundation

/// Fetch the latest Anthropic and OpenAI pricing from LiteLLM's
/// model_prices_and_context_window.json — the same source ccusage and
/// our bake-in defaults reference. Same network source as `--refresh-pricing`
/// in the Go binary, but JSON-based instead of HTML-scraped (more stable).
public enum PricingFetcher {

    public static let liteLLMURL = URL(string:
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    public enum FetchError: Error, LocalizedError {
        case http(Int)
        case parseFailed(String)
        case noPricedModels

        public var errorDescription: String? {
            switch self {
            case .http(let code):       return "Pricing fetch HTTP \(code)"
            case .parseFailed(let msg): return "Pricing parse failed: \(msg)"
            case .noPricedModels:       return "No priced models found in upstream pricing"
            }
        }
    }

    /// Fetch and parse the upstream JSON into a `PricingTable`. Throws
    /// on non-200, parse error, or empty result. Caller decides what to
    /// do — typical recipe: keep the existing in-memory table on failure
    /// and surface the error to the user.
    public static func fetch(session: URLSessionProtocol = URLSession.shared,
                             url: URL = liteLLMURL) async throws -> PricingTable {
        let (data, response) = try await session.dataReturning(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FetchError.http(http.statusCode)
        }
        return try parse(data)
    }

    /// Parse LiteLLM's JSON shape into a PricingTable. Filters to entries
    /// whose `litellm_provider` is `anthropic` or `openai`, normalises any
    /// `anthropic/` model-name prefix, and converts per-token prices to
    /// per-mtok by multiplying by 1_000_000. Mirrors `parseLiteLLM` in Go.
    public static func parse(_ data: Data) throws -> PricingTable {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.parseFailed("root is not an object")
        }
        var models: [String: ModelPrice] = [:]
        for (rawName, rawValue) in root {
            guard let entry = rawValue as? [String: Any] else { continue }
            // Anthropic and OpenAI both. Verified against the live LiteLLM
            // table: 26 anthropic and 145 openai entries survive the
            // non-zero-cost filter below, with no name collisions between
            // the two sets and no "/"-containing OpenAI names — so the
            // prefix-strip below needs no OpenAI equivalent.
            //
            // Caveat worth knowing: 52 of those OpenAI entries omit
            // cache_read_input_token_cost, which defaults to 0 here and
            // would price cached reads free. Neither model Codex currently
            // uses (gpt-5.6-sol, gpt-5.6-luna) is among them, but cached
            // reads dominate Codex volume, so a future model landing in
            // that set would under-report rather than fail loudly.
            let provider = (entry["litellm_provider"] as? String)?.lowercased() ?? ""
            guard provider == "anthropic" || provider == "openai" else { continue }

            let modelName = normaliseModelName(rawName)
            let input = perMTok(entry["input_cost_per_token"])
            let output = perMTok(entry["output_cost_per_token"])
            let cacheCreate = perMTok(entry["cache_creation_input_token_cost"])
            let cacheRead = perMTok(entry["cache_read_input_token_cost"])

            // Only include models with at least an input price — LiteLLM has
            // some entries with placeholder zeros that aren't useful.
            guard input > 0 || output > 0 else { continue }

            models[modelName] = ModelPrice(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheCreationPerMTok: cacheCreate,
                cacheReadPerMTok: cacheRead
            )
        }
        guard !models.isEmpty else { throw FetchError.noPricedModels }
        return PricingTable(models: models)
    }

    private static func normaliseModelName(_ name: String) -> String {
        if name.hasPrefix("anthropic/") {
            return String(name.dropFirst("anthropic/".count))
        }
        return name
    }

    private static func perMTok(_ raw: Any?) -> Double {
        // LiteLLM stores costs per single token; convert to per 1M tokens.
        if let n = raw as? Double { return n * 1_000_000 }
        if let n = raw as? Int { return Double(n) * 1_000_000 }
        if let s = raw as? String, let n = Double(s) { return n * 1_000_000 }
        return 0
    }
}

/// Test seam over URLSession.
public protocol URLSessionProtocol: Sendable {
    func dataReturning(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {
    public func dataReturning(from url: URL) async throws -> (Data, URLResponse) {
        try await self.data(from: url)
    }
}
