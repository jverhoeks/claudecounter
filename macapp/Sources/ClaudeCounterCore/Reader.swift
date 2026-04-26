import Foundation

/// One billable assistant turn parsed from a Claude Code JSONL line.
/// Mirrors `reader.Event` in the Go implementation.
public struct UsageEvent: Equatable, Sendable {
    public var timestamp: Date
    public var sessionID: String
    public var cwd: String
    public var project: String       // canonical project key (segment under projects/)
    public var model: String
    public var messageID: String     // Anthropic message id; combined with requestID for dedupe
    public var requestID: String     // Anthropic request id
    public var isSubagent: Bool      // path contains "/subagents/"
    public var usage: Usage

    public init(timestamp: Date, sessionID: String, cwd: String, project: String,
                model: String, messageID: String, requestID: String, isSubagent: Bool, usage: Usage) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.cwd = cwd
        self.project = project
        self.model = model
        self.messageID = messageID
        self.requestID = requestID
        self.isSubagent = isSubagent
        self.usage = usage
    }
}

/// Result of parsing a single JSONL line.
public enum ParseResult: Equatable, Sendable {
    case event(UsageEvent)
    case skip          // valid JSON but no usage data we care about
    case parseError    // JSON couldn't be decoded
}

// MARK: - Line parsing (port of internal/reader.parseLine)

/// `rawLine` mirrors only the fields we read from a JSONL event.
private struct RawLine: Decodable {
    let type: String?
    let timestamp: Date?
    let sessionId: String?
    let cwd: String?
    let requestId: String?
    let message: RawMessage?

    struct RawMessage: Decodable {
        let id: String?
        let model: String?
        let usage: RawUsage?
    }

    struct RawUsage: Decodable {
        let input_tokens: UInt64?
        let output_tokens: UInt64?
        let cache_creation_input_tokens: UInt64?
        let cache_read_input_tokens: UInt64?
    }
}

/// Parse a single JSONL line. Returns:
/// - `.event(ev)` — a usable usage event
/// - `.skip` — line had no `message.usage` (or model was `<synthetic>`)
/// - `.parseError` — line wasn't valid JSON
///
/// Mirrors ccusage's permissive filter: any line with `message.usage` is
/// included regardless of `type` or model name.
public func parseLine(_ data: Data) -> ParseResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let str = try decoder.singleValueContainer().decode(String.self)
        if let date = isoDate(str) { return date }
        throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
            debugDescription: "invalid ISO8601 date: \(str)")
    }

    let raw: RawLine
    do {
        raw = try decoder.decode(RawLine.self, from: data)
    } catch {
        return .parseError
    }

    guard let msg = raw.message, let u = msg.usage, let model = msg.model else {
        return .skip
    }
    if model == "<synthetic>" {
        return .skip
    }

    let usage = Usage(
        input: u.input_tokens ?? 0,
        output: u.output_tokens ?? 0,
        cacheCreate: u.cache_creation_input_tokens ?? 0,
        cacheRead: u.cache_read_input_tokens ?? 0
    )

    let ev = UsageEvent(
        timestamp: raw.timestamp ?? .distantPast,
        sessionID: raw.sessionId ?? "",
        cwd: raw.cwd ?? "",
        project: "",
        model: model,
        messageID: msg.id ?? "",
        requestID: raw.requestId ?? "",
        isSubagent: false,
        usage: usage
    )
    return .event(ev)
}

// MARK: - Path attribution (port of internal/reader.projectFromPath + isSubagent rule)

/// Returns the canonical project key from a transcript file path.
/// For `.../projects/<encoded>/<session>.jsonl` or
/// `.../projects/<encoded>/<session>/subagents/agent-*.jsonl` this returns
/// `"<encoded>"` — the segment immediately under `projects/`.
public func projectFromPath(_ path: String) -> String {
    let normalized = normalizeSlashes(path)
    guard let range = normalized.range(of: "/projects/") else { return "" }
    let rest = normalized[range.upperBound...]
    if let next = rest.firstIndex(of: "/") {
        return String(rest[..<next])
    }
    return String(rest)
}

/// `true` when the path indicates a Task-tool subagent transcript.
/// Path is normalised to forward slashes first so Windows-style paths work.
public func isSubagentPath(_ path: String) -> Bool {
    return normalizeSlashes(path).contains("/subagents/")
}

@inline(__always)
private func normalizeSlashes(_ path: String) -> String {
    if path.contains("\\") {
        return path.replacingOccurrences(of: "\\", with: "/")
    }
    return path
}

// MARK: - ISO8601 date parsing tolerant of fractional seconds

private let iso8601Plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private let iso8601Frac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func isoDate(_ s: String) -> Date? {
    if let d = iso8601Frac.date(from: s) { return d }
    return iso8601Plain.date(from: s)
}

// MARK: - Reader (port of internal/reader.Reader)

public actor Reader {
    private var offsets: [String: Int64] = [:]
    private(set) public var parseErrors: Int = 0

    public init() {}

    /// Drop a file from the offset map (call on Remove/Rename watcher events).
    public func forget(path: String) {
        offsets.removeValue(forKey: path)
    }

    /// Replace per-file offsets — used after restoring from cache so the
    /// next OnChange picks up where the old session left off.
    public func seedOffsets(_ newOffsets: [String: Int64]) {
        offsets = newOffsets
    }

    /// Snapshot of the per-file byte offset map.
    public func allOffsets() -> [String: Int64] {
        return offsets
    }

    /// Drop all offset state and reset diagnostics. Used by manual Refresh.
    public func resetAll() {
        offsets.removeAll(keepingCapacity: true)
        parseErrors = 0
    }

    /// Read any new complete lines since the last offset, returning their
    /// parsed events. Updates the offset to point at the byte just past the
    /// last `\n`. Bytes after the last newline (incomplete tail) stay
    /// unconsumed — they are picked up on the next call.
    public func onChange(path: String) async throws -> [UsageEvent] {
        let stored = offsets[path] ?? 0

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            offsets.removeValue(forKey: path)
            return []
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        var start = stored
        if size < start {
            // File was truncated/rotated under us — restart from zero.
            start = 0
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.readToEnd() ?? Data()

        // Walk newline-terminated lines. Bytes after the last \n are not consumed.
        var consumed = 0
        var events: [UsageEvent] = []

        while consumed < data.count {
            guard let nlOffset = nextNewline(in: data, from: consumed) else { break }
            let line = data[consumed..<nlOffset]
            consumed = nlOffset + 1

            if isWhitespaceOnly(line) { continue }

            switch parseLine(Data(line)) {
            case .event(var ev):
                ev.project = projectFromPath(path)
                ev.isSubagent = isSubagentPath(path)
                events.append(ev)
            case .skip:
                continue
            case .parseError:
                parseErrors += 1
                continue
            }
        }

        offsets[path] = start + Int64(consumed)
        return events
    }

    /// Walk `root/**/*.jsonl` and read every file whose mtime is at or
    /// after `notBefore`. Recursion is required to pick up subagent
    /// transcripts at `<project>/<session>/subagents/agent-*.jsonl`.
    /// After this returns, the reader's offset map reflects the end of
    /// every scanned file.
    public func initialScan(root: String, notBefore: Date) async throws -> [UsageEvent] {
        // Collect candidate paths synchronously first — Swift 6 forbids
        // iterating FileManager.enumerator across async suspension points.
        let candidates = Self.candidateJSONLs(under: root, notBefore: notBefore)

        var allEvents: [UsageEvent] = []
        for path in candidates {
            do {
                let evs = try await onChange(path: path)
                allEvents.append(contentsOf: evs)
            } catch {
                // Don't abort the whole scan if a single file is unreadable.
                continue
            }
        }
        return allEvents
    }

    /// Synchronously enumerate `*.jsonl` files under `root` whose mtime
    /// is at or after `notBefore`. Returns absolute paths.
    private static func candidateJSONLs(under root: String, notBefore: Date) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []) else { return [] }

        var paths: [String] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if let mtime = values?.contentModificationDate, mtime < notBefore { continue }
            paths.append(url.path)
        }
        return paths
    }
}

// MARK: - Internal helpers

@inline(__always)
private func nextNewline(in data: Data, from start: Int) -> Int? {
    var i = start
    while i < data.count {
        if data[i] == 0x0A { return i }
        i += 1
    }
    return nil
}

@inline(__always)
private func isWhitespaceOnly(_ slice: Data) -> Bool {
    for byte in slice {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0D: continue
        default: return false
        }
    }
    return true
}
