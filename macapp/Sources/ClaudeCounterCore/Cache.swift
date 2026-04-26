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
    /// writers always emit. Empty when day rolled over and no events
    /// have been seen yet today.
    public let hourBuckets: [HourEntry]?
    public let hourBucketsDay: String?

    public static let currentVersion = 2

    public struct CellEntry: Codable, Sendable {
        public let day: String       // YYYY-MM-DD (matches civilDayString)
        public let project: String
        public let model: String
        public let isSub: Bool
        public let input: UInt64
        public let output: UInt64
        public let cacheCreate: UInt64
        public let cacheRead: UInt64

        public init(day: String, project: String, model: String, isSub: Bool,
                    input: UInt64, output: UInt64,
                    cacheCreate: UInt64, cacheRead: UInt64) {
            self.day = day; self.project = project; self.model = model
            self.isSub = isSub
            self.input = input; self.output = output
            self.cacheCreate = cacheCreate; self.cacheRead = cacheRead
        }
    }

    /// One row of the today-only hourly distribution. Keyed by
    /// (hour 0–23, model). Tokens are the same UInt64 quartet as
    /// `CellEntry`; hour-USD is computed at snapshot time.
    public struct HourEntry: Codable, Sendable {
        public let hour: Int
        public let model: String
        public let input: UInt64
        public let output: UInt64
        public let cacheCreate: UInt64
        public let cacheRead: UInt64

        public init(hour: Int, model: String,
                    input: UInt64, output: UInt64,
                    cacheCreate: UInt64, cacheRead: UInt64) {
            self.hour = hour; self.model = model
            self.input = input; self.output = output
            self.cacheCreate = cacheCreate; self.cacheRead = cacheRead
        }
    }

    public init(version: Int = currentVersion, writtenAt: Date,
                cells: [CellEntry], perMsg: [String],
                offsets: [String: Int64], parseErrors: Int, dupes: Int,
                unknownMsgs: [String],
                hourBuckets: [HourEntry]? = nil,
                hourBucketsDay: String? = nil) {
        self.version = version
        self.writtenAt = writtenAt
        self.cells = cells
        self.perMsg = perMsg
        self.offsets = offsets
        self.parseErrors = parseErrors
        self.dupes = dupes
        self.unknownMsgs = unknownMsgs
        self.hourBuckets = hourBuckets
        self.hourBucketsDay = hourBucketsDay
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
    public static func snapshot(aggregator: Aggregator,
                                offsets: [String: Int64],
                                parseErrors: Int,
                                writtenAt: Date = Date()) async -> CacheFile {
        let state = await aggregator.exportState()
        let entries = state.cells.map { (key, t) in
            CellEntry(
                day: civilDayString(key.day),
                project: key.project,
                model: key.model,
                isSub: key.isSub,
                input: t.input, output: t.output,
                cacheCreate: t.cacheCreate, cacheRead: t.cacheRead
            )
        }
        let hourState = await aggregator.exportHourBuckets()
        let hourEntries = hourState.entries.map {
            HourEntry(
                hour: $0.hour, model: $0.model,
                input: $0.tokens.input,
                output: $0.tokens.output,
                cacheCreate: $0.tokens.cacheCreate,
                cacheRead: $0.tokens.cacheRead
            )
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
            hourBucketsDay: hourState.day.map { civilDayString($0) }
        )
    }

    /// Apply this cache to an aggregator. Returns the per-file offsets
    /// the caller should seed back into the Reader.
    public func restore(into aggregator: Aggregator) async -> [String: Int64] {
        var cells: [Aggregator.CellKey: TokenCounts] = [:]
        for e in self.cells {
            guard let cd = parseCivilDayString(e.day) else { continue }
            let key = Aggregator.CellKey(
                day: cd, project: e.project, model: e.model, isSub: e.isSub
            )
            cells[key] = TokenCounts(
                input: e.input, output: e.output,
                cacheCreate: e.cacheCreate, cacheRead: e.cacheRead
            )
        }
        await aggregator.load(
            cells: cells,
            perMsg: Set(perMsg),
            unknownMsgs: Set(unknownMsgs),
            dupes: dupes
        )

        // Hour buckets — only meaningful if the cached `hourBucketsDay`
        // is still today. Snapshot's apply path will lazily reset on
        // day rollover, so passing yesterday's data is harmless, but
        // we filter here to keep the wire-format meaningful.
        let day = hourBucketsDay.flatMap(parseCivilDayString)
        let entries: [(hour: Int, model: String, tokens: TokenCounts)] =
            (hourBuckets ?? []).map { e in
                (e.hour, e.model, TokenCounts(
                    input: e.input, output: e.output,
                    cacheCreate: e.cacheCreate, cacheRead: e.cacheRead))
            }
        await aggregator.loadHourBuckets(day: day, entries: entries)

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
