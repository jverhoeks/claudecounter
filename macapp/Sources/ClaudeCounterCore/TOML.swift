import Foundation

/// Minimal TOML reader/writer for the pricing.toml subset:
///
///   [models."<model-name>"]
///   input_per_mtok          = 5.00
///   output_per_mtok         = 25.00
///   cache_creation_per_mtok = 6.25
///   cache_read_per_mtok     = 0.50
///
/// Hand-rolled to avoid pulling a dependency. Does not implement full
/// TOML — just enough to round-trip the format used by the Go binary.
enum TOMLPricing {

    /// Decode a `pricing.toml` body into a PricingTable. Lines that don't
    /// fit the expected shape are ignored (best-effort).
    static func decode(_ body: String) -> PricingTable {
        var models: [String: ModelPrice] = [:]
        var current: String? = nil
        var pending: [String: Double] = [:]
        var schema = 0

        func flush() {
            guard let name = current else { return }
            // Only commit if we collected at least one numeric.
            guard !pending.isEmpty else { return }
            let p = ModelPrice(
                inputPerMTok:        pending["input_per_mtok"] ?? 0,
                outputPerMTok:       pending["output_per_mtok"] ?? 0,
                cacheCreationPerMTok: pending["cache_creation_per_mtok"] ?? 0,
                cacheReadPerMTok:    pending["cache_read_per_mtok"] ?? 0
            )
            models[name] = p
            pending.removeAll(keepingCapacity: true)
        }

        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            // Strip comments + trim.
            let line = stripComment(String(rawLine))
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                // New table header — flush previous, parse new.
                flush()
                if let name = parseModelHeader(line) {
                    current = name
                } else {
                    current = nil
                }
                continue
            }
            if current == nil {
                // Bare top-level key seen before any [models."..."] header —
                // currently only "schema" is recognized. This must appear
                // before the first header: once `current` is non-nil, a
                // "schema = N" line would fall into the model-scoped
                // key/value parsing below and be silently absorbed into
                // that model's `pending` (then dropped, since ModelPrice
                // has no "schema" field) instead of being read here. This
                // mirrors the same ordering requirement `SaveTOML` documents
                // on the Go side.
                if let eq = line.firstIndex(of: "=") {
                    let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                    let valueStr = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if key == "schema", let v = Int(valueStr) {
                        schema = v
                    }
                }
                continue
            }

            // key = number
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let valueStr = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if let v = Double(valueStr) {
                    pending[key] = v
                }
            }
        }
        flush()
        return PricingTable(models: models, schema: schema)
    }

    /// Encode a `PricingTable` to canonical pricing.toml format.
    static func encode(_ table: PricingTable) -> String {
        var lines: [String] = []
        lines.append("# claudecounter pricing.toml — USD per 1M tokens")
        lines.append("")
        // schema must appear before any [models."..."] header — see
        // decode's top-level-key handling above; a schema line following a
        // header would be silently absorbed into that model's fields
        // instead. Always writes PricingTable.currentSchema, not
        // table.schema: table.schema reflects whatever this table was
        // loaded with (0 for a freshly-fetched table — see
        // PricingFetcher.parse), but what we're persisting here is
        // current-as-of-now data, so the file must be stamped current or
        // every future launch would see it as stale and refetch forever.
        // Mirrors Go's SaveTOML writing TableSchema, not t.Schema.
        lines.append("schema = \(PricingTable.currentSchema)")
        lines.append("")
        for name in table.models.keys.sorted() {
            guard let p = table.models[name] else { continue }
            lines.append("[models.\"\(name)\"]")
            lines.append("input_per_mtok          = \(formatNum(p.inputPerMTok))")
            lines.append("output_per_mtok         = \(formatNum(p.outputPerMTok))")
            lines.append("cache_creation_per_mtok = \(formatNum(p.cacheCreationPerMTok))")
            lines.append("cache_read_per_mtok     = \(formatNum(p.cacheReadPerMTok))")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: helpers

    private static func parseModelHeader(_ line: String) -> String? {
        // Expects exactly: [models."<name>"]
        let trimmed = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ".", maxSplits: 1)
        guard parts.count == 2, parts[0] == "models" else { return nil }
        let q = parts[1].trimmingCharacters(in: .whitespaces)
        guard q.first == "\"", q.last == "\"" else { return nil }
        return String(q.dropFirst().dropLast())
    }

    private static func stripComment(_ line: String) -> String {
        // Drop everything after a `#`. (Quoted strings in this format
        // never contain `#`, so simple split is safe enough.)
        if let hash = line.firstIndex(of: "#") {
            return String(line[..<hash])
        }
        return line
    }

    private static func formatNum(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 {
            return String(format: "%.2f", n)
        }
        return String(n)
    }
}

// MARK: - Pricing layering & file IO

extension PricingTable {

    /// Resolution order (first hit wins, falls back to bake-in):
    /// 1. In-app override at `~/Library/Application Support/claudecounter-bar/pricing.toml`
    /// 2. Shared with Go app: `$XDG_CONFIG_HOME/claudecounter/pricing.toml`
    ///    or `~/.config/claudecounter/pricing.toml`
    /// 3. Bake-in defaults (PricingTable.defaults)
    public static func resolveFromDisk(fileManager: FileManager = .default,
                                       env: [String: String] = ProcessInfo.processInfo.environment) -> PricingTable {
        for url in resolutionPaths(fileManager: fileManager, env: env) {
            if let body = try? String(contentsOf: url, encoding: .utf8) {
                let parsed = TOMLPricing.decode(body)
                if !parsed.models.isEmpty {
                    return parsed
                }
            }
        }
        return .defaults
    }

    /// In-app override URL (where Refresh writes).
    public static func appOverrideURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("claudecounter-bar", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pricing.toml", isDirectory: false)
    }

    /// All resolution paths in order. Exposed for tests + diagnostics.
    public static func resolutionPaths(fileManager: FileManager = .default,
                                       env: [String: String]) -> [URL] {
        var paths: [URL] = []
        if let appOverride = try? appOverrideURL(fileManager: fileManager) {
            paths.append(appOverride)
        }
        // Go app's pricing path: $XDG_CONFIG_HOME/claudecounter/pricing.toml
        // or ~/.config/claudecounter/pricing.toml.
        let xdg = env["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespaces) ?? ""
        let configHome: URL = {
            if !xdg.isEmpty {
                return URL(fileURLWithPath: xdg, isDirectory: true)
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(".config", isDirectory: true)
        }()
        paths.append(configHome
            .appendingPathComponent("claudecounter", isDirectory: true)
            .appendingPathComponent("pricing.toml"))
        return paths
    }

    /// Persist this table as TOML to an arbitrary destination. Exposed
    /// separately from `writeToAppOverride` so callers (namely
    /// `AppState.refreshPricingIfStale`) can redirect the write to an
    /// injected URL instead of the real app-override path — see
    /// `AppState.pricingOverrideURL`'s doc comment for why that matters.
    public func write(to url: URL) throws {
        try TOMLPricing.encode(self).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Persist this table as TOML to the in-app override path.
    public func writeToAppOverride(fileManager: FileManager = .default) throws {
        try write(to: try Self.appOverrideURL(fileManager: fileManager))
    }
}
