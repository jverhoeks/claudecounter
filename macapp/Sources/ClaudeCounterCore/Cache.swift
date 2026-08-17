import Foundation

/// Persisted aggregator state. Lives at
/// `~/Library/Application Support/claudecounter-bar/cache.json`.
///
/// **Version history**
/// - 1: initial. Cells + perMsg + offsets only.
/// - 2: adds `hourBuckets` + `hourBucketsDay` so today's per-hour
///   distribution survives a relaunch. Without this, today's older
///   hours rendered as flat baseline after every restart because
///   cached events got deduped before reaching the hour-bucket update.
/// - 3: hour buckets are now per-(day, hour, model) across the whole
///   30-day window (each `HourEntry` carries its own `day`; the
///   file-level `hourBucketsDay` is gone) so the hourly chart can
///   drill into any day of the monthly chart. Old caches are
///   invalidated on load → one full rescan rebuilds the history.
/// - 4: cells are keyed by (day, project, source, vendor, model, isSub)
///   so multiple configured sources stay distinct. Old caches are
///   invalidated on load → one full rescan re-tags every cell with the
///   source it came from. Without the bump, cached cells would carry no
///   source and silently merge into one series.
/// - 5: cells and hour buckets carry a vendor-reported `usd` alongside
///   the token quartet, and the file carries per-(day, vendor) coverage
///   counts. Old caches are invalidated on load → one full rescan. Without
///   the bump, a restored Grok cell would have no cost and every past day
///   would render as $0.00 while looking correct.
public struct CacheFile: Codable, Sendable {
    public let version: Int
    public let writtenAt: Date
    public let cells: [CellEntry]
    public let perMsg: [String]
    public let offsets: [String: Int64]
    public let parseErrors: Int
    public let dupes: Int
    public let unknownMsgs: [String]

    /// Optional in JSON for forward-compat / older caches; current
    /// writers always emit.
    public let hourBuckets: [HourEntry]?
    /// Optional for the same reason. Absent means "no coverage data",
    /// which restores as every vendor reading complete — correct for
    /// caches written before Grok existed.
    public let coverage: [CoverageEntry]?

    /// The `SourceEntry.id` ("vendor/label") of every source this cache's
    /// cells/offsets actually reflect — populated on save from the
    /// reachable source list `AppState.flushCache` just scanned. Used
    /// only by `AppState.start()`'s catch-up scan, to decide per source
    /// whether the cheap incremental `notBefore` (derived from
    /// `writtenAt`) applies, or the same full backfill window a cold
    /// start uses.
    ///
    /// Optional, not a version bump: a version bump would invalidate
    /// this whole cache on load (see the version-history note above),
    /// discarding the Claude/Grok cells and offsets it already has
    /// correctly, and forcing a full rescan of EVERYTHING just to
    /// backfill the one vendor that's actually new. `coveredSources`
    /// lets an old cache keep every cell/offset it already has while
    /// still driving a one-time full scan for the source(s) it doesn't
    /// know about.
    ///
    /// `nil` MUST mean "covers nothing" — an old cache written before
    /// this field existed has no way to declare what it covered, so
    /// every configured source must be treated as uncovered and get one
    /// full backfill. That is exactly what makes the currently-shipped
    /// silent-backfill bug self-heal on the very next launch: the field
    /// is simply absent from disk, decodes to `nil`, and every source —
    /// old and new alike — takes the full-window path once. The
    /// following save writes a real `coveredSources` list and every
    /// source after that goes back to the cheap incremental path.
    public let coveredSources: [String]?

    public static let currentVersion = 5

    public struct CellEntry: Codable, Sendable {
        public let day: String       // YYYY-MM-DD (matches civilDayString)
        public let project: String
        public let source: String
        public let vendor: String
        public let model: String
        public let isSub: Bool
        public let input: UInt64
        public let output: UInt64
        public let cacheCreate: UInt64
        public let cacheRead: UInt64
        /// `CellValue.costedUSD`, persisted as-is.
        public let usd: Double
        /// Whether this cell's dollar figure is vendor-reported. Together
        /// with `usd` this is what lets `pricedTokens` be reconstructed on
        /// restore without a second token quartet on disk:
        /// `pricedTokens = costed ? .zero : tokens`.
        ///
        /// That reconstruction is exact only if a cell never mixes the two
        /// kinds of contribution. `CellKey` carrying `vendor` is necessary
        /// for that (so two vendors sharing a model name land in different
        /// cells) but not sufficient on its own — it also requires that one
        /// vendor's events are *uniformly* costed or uniformly priced,
        /// never both across a cell's lifetime. Nothing in this schema
        /// enforces that; it holds because of how the readers construct
        /// events: the Grok reader (`grok.go`'s `Parse`) marks every usage
        /// event it emits `Costed = true` unconditionally, and a turn with
        /// no usage produces only a coverage-only event (no cell write at
        /// all) rather than a priced one. So no cell keyed by vendor+model
        /// ever sees both kinds. If a future reader ever emits both costed
        /// and non-costed events for the same vendor+model, this
        /// reconstruction silently mis-restores — preserve that invariant
        /// rather than relaxing it.
        public let costed: Bool

        public init(day: String, project: String, source: String, vendor: String,
                    model: String, isSub: Bool,
                    input: UInt64, output: UInt64,
                    cacheCreate: UInt64, cacheRead: UInt64,
                    usd: Double = 0, costed: Bool = false) {
            self.day = day; self.project = project
            self.source = source; self.vendor = vendor
            self.model = model
            self.isSub = isSub
            self.input = input; self.output = output
            self.cacheCreate = cacheCreate; self.cacheRead = cacheRead
            self.usd = usd; self.costed = costed
        }
    }

    /// One row of the hourly distribution. Keyed by (day YYYY-MM-DD,
    /// hour 0–23, vendor, model). Tokens are the same UInt64 quartet as
    /// `CellEntry`; `usd` and `costed` reconstruct `pricedTokens` the same
    /// way, under the same precondition — see `CellEntry.costed` for the
    /// full exactness argument. Vendor is part of the key for the same
    /// reason it was added to `HourBucketKey`: without it, two vendors
    /// sharing a model name would mix into one bucket and the single
    /// `costed` Bool could no longer describe it exactly.
    public struct HourEntry: Codable, Sendable {
        public let day: String
        public let hour: Int
        public let vendor: String
        public let model: String
        public let input: UInt64
        public let output: UInt64
        public let cacheCreate: UInt64
        public let cacheRead: UInt64
        public let usd: Double
        public let costed: Bool

        public init(day: String, hour: Int, vendor: String, model: String,
                    input: UInt64, output: UInt64,
                    cacheCreate: UInt64, cacheRead: UInt64,
                    usd: Double = 0, costed: Bool = false) {
            self.day = day; self.hour = hour; self.vendor = vendor; self.model = model
            self.input = input; self.output = output
            self.cacheCreate = cacheCreate; self.cacheRead = cacheRead
            self.usd = usd; self.costed = costed
        }
    }

    /// One (day, vendor) coverage tally. Persisted because cells persist:
    /// a restored month whose coverage reset to zero would present a
    /// known-partial Grok figure as complete.
    public struct CoverageEntry: Codable, Sendable {
        public let day: String
        public let vendor: String
        public let turns: Int
        public let withUsage: Int

        public init(day: String, vendor: String, turns: Int, withUsage: Int) {
            self.day = day; self.vendor = vendor
            self.turns = turns; self.withUsage = withUsage
        }
    }

    public init(version: Int = currentVersion, writtenAt: Date,
                cells: [CellEntry], perMsg: [String],
                offsets: [String: Int64], parseErrors: Int, dupes: Int,
                unknownMsgs: [String],
                hourBuckets: [HourEntry]? = nil,
                coverage: [CoverageEntry]? = nil,
                coveredSources: [String]? = nil) {
        self.version = version
        self.writtenAt = writtenAt
        self.cells = cells
        self.perMsg = perMsg
        self.offsets = offsets
        self.parseErrors = parseErrors
        self.dupes = dupes
        self.unknownMsgs = unknownMsgs
        self.hourBuckets = hourBuckets
        self.coverage = coverage
        self.coveredSources = coveredSources
    }
}

/// Persistence helper. Reads/writes `cache.json` under the app's
/// Application Support directory.
public struct CacheStore: Sendable {

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Default location: `~/Library/Application Support/claudecounter-bar/cache.json`.
    public static func defaultURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("claudecounter-bar", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json", isDirectory: false)
    }

    /// Decode `cache.json` from disk. Returns nil if the file is missing.
    /// Throws on present-but-corrupt files (caller decides whether to
    /// delete and retry).
    public func load() throws -> CacheFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CacheFile.self, from: data)
    }

    /// Encode and write `cache.json` atomically.
    public func save(_ cache: CacheFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: url, options: .atomic)
    }

    /// Delete the cache file (used after manual Refresh / version mismatch).
    public func invalidate() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Bridge between Aggregator state and CacheFile

extension CacheFile {

    /// Build a `CacheFile` from current aggregator + reader state.
    /// `coveredSources` defaults to `[]`, not the source list — a call
    /// site that forgets to pass it gets a cache that (like a pre-fix
    /// cache decoding to `nil`) declares itself covering nothing, so the
    /// next launch does one full backfill per source rather than
    /// silently suppressing history for whatever that call site missed.
    public static func snapshot(aggregator: Aggregator,
                                offsets: [String: Int64],
                                parseErrors: Int,
                                coveredSources: [String] = [],
                                writtenAt: Date = Date()) async -> CacheFile {
        let state = await aggregator.exportState()
        let entries = state.cells.map { (key, v) in
            CellEntry(
                day: civilDayString(key.day),
                project: key.project,
                source: key.source,
                vendor: key.vendor,
                model: key.model,
                isSub: key.isSub,
                input: v.tokens.input, output: v.tokens.output,
                cacheCreate: v.tokens.cacheCreate, cacheRead: v.tokens.cacheRead,
                usd: v.costedUSD, costed: v.pricedTokens == .zero
            )
        }
        let hourEntries = await aggregator.exportHourBuckets().map {
            HourEntry(
                day: civilDayString($0.day),
                hour: $0.hour, vendor: $0.vendor, model: $0.model,
                input: $0.value.tokens.input,
                output: $0.value.tokens.output,
                cacheCreate: $0.value.tokens.cacheCreate,
                cacheRead: $0.value.tokens.cacheRead,
                usd: $0.value.costedUSD, costed: $0.value.pricedTokens == .zero
            )
        }
        let coverageEntries = state.coverage.map {
            CoverageEntry(day: civilDayString($0.day), vendor: $0.vendor,
                          turns: $0.coverage.turns, withUsage: $0.coverage.withUsage)
        }
        return CacheFile(
            writtenAt: writtenAt,
            cells: entries,
            perMsg: Array(state.perMsg),
            offsets: offsets,
            parseErrors: parseErrors,
            dupes: state.dupes,
            unknownMsgs: Array(state.unknownMsgs),
            hourBuckets: hourEntries,
            coverage: coverageEntries,
            coveredSources: coveredSources
        )
    }

    /// Apply this cache to an aggregator. Returns the per-file offsets
    /// the caller should seed back into the Reader.
    public func restore(into aggregator: Aggregator) async -> [String: Int64] {
        var cells: [Aggregator.CellKey: CellValue] = [:]
        for e in self.cells {
            guard let cd = parseCivilDayString(e.day) else { continue }
            let key = Aggregator.CellKey(
                day: cd, project: e.project, source: e.source, vendor: e.vendor,
                model: e.model, isSub: e.isSub
            )
            let tokens = TokenCounts(
                input: e.input, output: e.output,
                cacheCreate: e.cacheCreate, cacheRead: e.cacheRead
            )
            // `pricedTokens` is recovered exactly, not merely
            // approximated — see `CellEntry.costed` for the full
            // precondition (vendor in the key, plus one vendor's events
            // never mixing costed and priced under one model).
            cells[key] = CellValue(
                tokens: tokens, costedUSD: e.usd,
                pricedTokens: e.costed ? .zero : tokens
            )
        }
        let coverage: [(day: CivilDay, vendor: String, coverage: Coverage)] =
            (self.coverage ?? []).compactMap { e in
                guard let cd = parseCivilDayString(e.day) else { return nil }
                return (cd, e.vendor, Coverage(turns: e.turns, withUsage: e.withUsage))
            }
        await aggregator.load(
            cells: cells,
            perMsg: Set(perMsg),
            unknownMsgs: Set(unknownMsgs),
            dupes: dupes,
            coverage: coverage
        )

        // Hour buckets — every entry carries its own day; the
        // aggregator drops anything older than the display window.
        let entries: [(day: CivilDay, hour: Int, vendor: String, model: String, value: CellValue)] =
            (hourBuckets ?? []).compactMap { e in
                guard let cd = parseCivilDayString(e.day) else { return nil }
                let tokens = TokenCounts(
                    input: e.input, output: e.output,
                    cacheCreate: e.cacheCreate, cacheRead: e.cacheRead)
                let value = CellValue(
                    tokens: tokens, costedUSD: e.usd,
                    pricedTokens: e.costed ? .zero : tokens
                )
                return (cd, e.hour, e.vendor, e.model, value)
            }
        await aggregator.loadHourBuckets(entries: entries)

        return offsets
    }
}

@inline(__always)
func parseCivilDayString(_ s: String) -> CivilDay? {
    let parts = s.split(separator: "-")
    guard parts.count == 3,
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
        return nil
    }
    return CivilDay(year: y, month: m, day: d)
}
