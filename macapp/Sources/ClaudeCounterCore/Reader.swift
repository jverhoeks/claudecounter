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
    /// "vendor/label" of the configured source this event came from —
    /// see `SourceEntry.id`. Defaults to the single implicit source
    /// (`Sources.defaults`) so every existing single-source call site
    /// keeps behaving exactly as before; a source-aware scanner
    /// (multi-source wiring) is expected to pass the real value.
    public var source: String
    public var vendor: String
    /// A dollar figure the vendor reported for this event. Grok emits
    /// costUsdTicks (nano-dollars) per turn and per model; that is
    /// authoritative in a way our pricing table can never be, so it is
    /// used as given. Mirrors `reader.Event.CostUSD` in Go.
    public var costUSD: Double
    /// Marks `costUSD` as authoritative. A costed event's tokens are
    /// still recorded but never priced, and its model never counts
    /// toward the unknown tally.
    public var costed: Bool
    /// Bookkeeping only: a turn happened, and `hasUsage` says whether it
    /// carried usable usage data. Never spend. Grok's usage object is
    /// absent on most historical turns, so this is what lets a total
    /// over an old month be presented as a floor.
    public var coverageOnly: Bool
    public var hasUsage: Bool

    public init(timestamp: Date, sessionID: String, cwd: String, project: String,
                model: String, messageID: String, requestID: String, isSubagent: Bool, usage: Usage,
                source: String = "claude/claude", vendor: String = "claude",
                costUSD: Double = 0, costed: Bool = false,
                coverageOnly: Bool = false, hasUsage: Bool = false) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.cwd = cwd
        self.project = project
        self.model = model
        self.messageID = messageID
        self.requestID = requestID
        self.isSubagent = isSubagent
        self.usage = usage
        self.source = source
        self.vendor = vendor
        self.costUSD = costUSD
        self.costed = costed
        self.coverageOnly = coverageOnly
        self.hasUsage = hasUsage
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

// Shared with GrokReader.swift's projectUnderRoot/grokProjectKey, which
// need the same Windows-backslash normalisation on the configured root
// that this applies to the path.
@inline(__always)
func normalizeSlashes(_ path: String) -> String {
    if path.contains("\\") {
        return path.replacingOccurrences(of: "\\", with: "/")
    }
    return path
}

// MARK: - ISO8601 date parsing tolerant of fractional seconds

// Not `private`: CodexReader.swift's line timestamps need the same
// tolerant parsing (rollout files use fractional-second UTC timestamps
// like Claude's), so this is shared at module (internal) visibility
// rather than duplicated.
let iso8601Plain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
let iso8601Frac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func isoDate(_ s: String) -> Date? {
    if let d = iso8601Frac.date(from: s) { return d }
    return iso8601Plain.date(from: s)
}

// MARK: - Reader (port of internal/reader.Reader)

public actor Reader {
    private var offsets: [String: Int64] = [:]
    private(set) public var parseErrors: Int = 0
    /// One `CodexParser` per path currently tracked in `offsets`, keyed
    /// the same way. `CodexParser` is stateful (see its doc comment), so
    /// unlike `ClaudeParser`/`GrokParser` it cannot be recreated on every
    /// `onChange` call — see `parserForChange`. Entries are dropped in
    /// `forget` (and `resetAll`) alongside the matching `offsets` entry,
    /// so a long-running watcher does not accumulate parsers for files
    /// that have gone away. Mirrors Go's `Reader.codexParsers`.
    private var codexParsers: [String: CodexParser] = [:]

    /// Codex paths whose pre-offset bytes could not be replayed by
    /// `seedOffsets` (the file was unreadable, or a read came back
    /// short, despite being long enough to contain them — NOT the
    /// separate "file shrank" case, which `onChange`'s existing
    /// `size < start` branch already resets and fully re-reads on its
    /// own). Without a trustworthy previous cumulative reading, the only
    /// SAFE delta for such a path is "none, forever this run" — a fresh,
    /// unreplayed `CodexParser` resuming mid-file would instead take
    /// `deltaEvent`'s `first` branch and fabricate the session's entire
    /// cumulative-to-date as new spend, on top of whatever the cache
    /// already restored: exactly the bug this quarantine exists to avoid
    /// reintroducing through its own failure path. `onChange` checks
    /// this set first and returns no events without reading the file, so
    /// the path's offset never advances either — a relaunch or manual
    /// Refresh gets another chance to replay it successfully. No Go
    /// equivalent: only the macapp resumes a file from cache across a
    /// process restart. Mirrors this project's rule (see
    /// `CodexParser.deltaEvent`) that a failure must degrade to fewer
    /// cells, never a wrong one.
    private var unreplayableCodexPaths: Set<String> = []

    public init() {}

    /// Drop a file from the offset map (call on Remove/Rename watcher
    /// events), and from `codexParsers`/`unreplayableCodexPaths`
    /// alongside it — a deleted file's running totals are gone for good,
    /// and keeping the entries would both leak memory and, if the path
    /// were ever reused, resurrect stale state for an unrelated session.
    /// Mirrors Go's `Reader.Forget`.
    public func forget(path: String) {
        offsets.removeValue(forKey: path)
        codexParsers.removeValue(forKey: path)
        unreplayableCodexPaths.remove(path)
    }

    /// Replace per-file offsets — used after restoring from cache so the
    /// next OnChange picks up where the old session left off. `vendor` is
    /// the SINGLE vendor this reader's source is configured for — see
    /// `AppState.seedReaders`, which owns exactly one `SourceEntry` (and
    /// therefore one vendor) per reader id. For `vendor == "codex"`,
    /// every non-zero offset also gets its `CodexParser` reconstructed by
    /// replaying bytes `[0, offset)` through a fresh instance and
    /// discarding the resulting events (see `seedCodexParser`) — without
    /// this, resuming a rollout file mid-stream after a relaunch would
    /// hand the next `onChange` call a parser with no running total, no
    /// declared model, and no cwd/hasParent, fabricating the whole
    /// session-to-date total as a fresh delta on top of the cache's
    /// already-restored figure. Claude and Grok are stateless and must
    /// NOT go through this path — passing any other vendor (or "") is a
    /// plain assignment, exactly as before.
    public func seedOffsets(_ newOffsets: [String: Int64], vendor: String) {
        offsets = newOffsets
        guard vendor == "codex" else { return }
        for (path, offset) in newOffsets where offset > 0 {
            seedCodexParser(path: path, offset: offset)
        }
    }

    /// Reconstructs one codex path's `CodexParser` state to exactly what
    /// `offset` implies, by replaying bytes `[0, offset)` through a fresh
    /// instance and discarding every resulting event — the replayed
    /// bytes were already counted (they're behind the cached cells this
    /// same restore just applied to the aggregator), only the parser's
    /// RUNNING STATE (running totals, declared model, cwd, hasParent) is
    /// needed here.
    ///
    /// Three outcomes:
    ///  - Success: `codexParsers[path]` is installed with the replayed
    ///    parser, so the next `onChange` call resumes correctly.
    ///  - The file has shrunk (current size < `offset`) or vanished:
    ///    deliberately left alone — `onChange`'s existing `size < start`
    ///    branch already resets and fully re-reads a shrunk path the
    ///    moment it's next touched, and a vanished file is dropped by
    ///    its existing `fileExists` check. That pre-existing behaviour
    ///    CAN double-count against the cache's restored cells (there's
    ///    no way to selectively un-restore just one file's contribution
    ///    from already-merged cells), a known, out-of-scope-here window;
    ///    a genuine shrink is not the NEW failure mode this method
    ///    exists to guard.
    ///  - Any other read failure (unreadable, or a short read despite
    ///    adequate size): `path` is quarantined via
    ///    `unreplayableCodexPaths` instead — see its doc comment.
    private func seedCodexParser(path: String, offset: Int64) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? Int64((attrs?[.size] as? Int) ?? 0)
        guard size >= offset else { return }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            unreplayableCodexPaths.insert(path)
            return
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: Int(offset)) ?? Data()
        } catch {
            unreplayableCodexPaths.insert(path)
            return
        }
        guard data.count == Int(offset) else {
            unreplayableCodexPaths.insert(path)
            return
        }

        let parser = CodexParser()
        var consumed = 0
        while consumed < data.count {
            guard let nlOffset = nextNewline(in: data, from: consumed) else { break }
            let line = data[consumed..<nlOffset]
            consumed = nlOffset + 1
            if isWhitespaceOnly(line) { continue }
            // Discard both events and parse errors: these bytes were
            // already parsed (and any parse errors already tallied) the
            // run that produced the cached offset — re-tallying them
            // here would double `CacheFile.parseErrors`.
            _ = parser.parse(Data(line), path: path)
        }
        codexParsers[path] = parser
    }

    /// Snapshot of the per-file byte offset map.
    public func allOffsets() -> [String: Int64] {
        return offsets
    }

    /// Drop all offset state and reset diagnostics. Used by manual
    /// Refresh, which re-scans every reachable source from scratch — so
    /// `codexParsers` and `unreplayableCodexPaths` must be cleared too,
    /// or a stale running total (or a stale quarantine) would survive
    /// into a fresh from-offset-zero read and delta the re-scan's first
    /// reading against it (no Go equivalent exists for this method, but
    /// the same invariant `codexParser.Reset`'s doc comment describes
    /// applies here: a path read from offset zero for a reason other than
    /// "never seen before" must not keep its old state).
    public func resetAll() {
        offsets.removeAll(keepingCapacity: true)
        codexParsers.removeAll(keepingCapacity: true)
        unreplayableCodexPaths.removeAll(keepingCapacity: true)
        parseErrors = 0
    }

    /// Resolves the `VendorParser` `onChange` should use for one path.
    /// For the two stateless vendors this is just `parserFor(vendor:)`: a
    /// fresh value is fine since nothing carries over between calls.
    /// Codex is not — this actor keeps one `CodexParser` per path,
    /// created on first sight and reused on every later call, which is
    /// what makes running totals and session_meta survive across a
    /// growing file's `onChange` calls. Mirrors Go's
    /// `Reader.parserForChange`.
    private func parserForChange(vendor: String, path: String) -> VendorParser {
        guard vendor == "codex" else { return parserFor(vendor: vendor) }
        if let p = codexParsers[path] { return p }
        let p = CodexParser()
        codexParsers[path] = p
        return p
    }

    /// Read any new complete lines since the last offset, returning their
    /// parsed events. Updates the offset to point at the byte just past the
    /// last `\n`. Bytes after the last newline (incomplete tail) stay
    /// unconsumed — they are picked up on the next call.
    ///
    /// `source` identifies which configured subscription `path` was
    /// found under; every returned event is stamped with its
    /// `id`/`vendor` HERE, at the one place events are produced, so no
    /// caller can forget to attribute a file's events to the right
    /// source. There is deliberately no defaulted overload — the
    /// caller must always know which source it's scanning.
    public func onChange(path: String, source: SourceEntry) async throws -> [UsageEvent] {
        // See `unreplayableCodexPaths`'s doc comment: a path quarantined
        // there stays untouched (offset included) for the rest of this
        // run rather than risk a fresh, unreplayed `CodexParser`
        // fabricating a double-counted delta.
        if unreplayableCodexPaths.contains(path) { return [] }

        let stored = offsets[path] ?? 0

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            offsets.removeValue(forKey: path)
            codexParsers.removeValue(forKey: path)
            return []
        }

        // parserForChange resolves (and, for codex, creates-or-reuses)
        // the parser instance for this path BEFORE the truncation check
        // below, mirroring Go's Reader.OnChange — Reset must run on the
        // SAME instance whose running totals are stale, not a fresh one.
        let parser = parserForChange(vendor: source.vendor, path: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs[.size] as? Int64) ?? Int64((attrs[.size] as? Int) ?? 0)
        var start = stored
        if size < start {
            // The file shrank or was replaced: a previously-seen codex
            // path is about to be read from byte offset 0 again for a
            // reason other than "never seen before", so its running
            // totals and declared model must not survive into this
            // read. See CodexParser.reset's doc comment.
            start = 0
            if let cp = parser as? CodexParser {
                cp.reset()
            }
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

            switch parser.parse(Data(line), path: path) {
            case .events(let evs) where !evs.isEmpty:
                // Project/subagent are computed AFTER this line's parse,
                // not once before the loop: for Claude/Grok they're a
                // pure function of path/root so it wouldn't matter, but
                // CodexParser's project()/isSubagent() read state that
                // parse() itself may have just set (session_meta on line
                // 1, read by line 2's event) — computing them earlier
                // would see stale (empty) state on a file's first call.
                // Mirrors Go's OnChange, which recomputes both per line.
                let project = parser.project(path, root: source.root)
                let isSub = parser.isSubagent(path, root: source.root)
                for var ev in evs {
                    ev.project = project
                    ev.isSubagent = isSub
                    ev.source = source.id
                    ev.vendor = source.vendor
                    events.append(ev)
                }
            case .events:
                break
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
    /// every scanned file. `source` is stamped onto every event via
    /// `onChange` — see its doc comment.
    public func initialScan(root: String, source: SourceEntry, notBefore: Date) async throws -> [UsageEvent] {
        // Collect candidate paths synchronously first — Swift 6 forbids
        // iterating FileManager.enumerator across async suspension points.
        // Which base names are walkable comes from the source's vendor —
        // same change as Go's Task 4 — so Grok's sessions/ directory
        // doesn't have its non-usage sibling files (e.g. messages.jsonl)
        // scanned as if they were updates.jsonl, and Codex's doesn't
        // treat every *.jsonl under ~/.codex/sessions as a rollout file.
        // `walkable` never reads a parser's state for any vendor —
        // including codex — so the throwaway instance `parserFor`
        // returns is fine here even though real parsing must go through
        // `parserForChange`'s per-path-owned map. Mirrors Go's
        // `walkableFor`.
        let walkable = parserFor(vendor: source.vendor).walkable
        let candidates = Self.candidateFiles(under: root, notBefore: notBefore, walkable: walkable)

        var allEvents: [UsageEvent] = []
        for path in candidates {
            do {
                let evs = try await onChange(path: path, source: source)
                allEvents.append(contentsOf: evs)
            } catch {
                // Don't abort the whole scan if a single file is unreadable.
                continue
            }
        }
        return allEvents
    }

    /// Synchronously enumerate the files under `root` that `walkable`
    /// accepts (by base name) whose mtime is at or after `notBefore`.
    /// Returns absolute paths in the same depth-first lexical order Go's
    /// `filepath.WalkDir` produces — at each directory, entries are
    /// sorted by name and dirs are recursed in place. This matters
    /// because Claude Code's main session file `<uuid>.jsonl` and its
    /// subagents directory `<uuid>/subagents/...` share messageIds for
    /// ~30% of turns; first-seen wins the dedupe, so traversal order
    /// decides whether those shared events are attributed to main or
    /// sub. WalkDir visits the dir `<uuid>` before the file
    /// `<uuid>.jsonl` (because `.` > nothing lexically), so subagent
    /// files are read first → sub wins the dedupe. We mirror that
    /// exactly.
    private static func candidateFiles(under root: String, notBefore: Date,
                                        walkable: (String) -> Bool) -> [String] {
        var paths: [String] = []
        walkDirLikeGo(URL(fileURLWithPath: root, isDirectory: true),
                      notBefore: notBefore, walkable: walkable, into: &paths)
        return paths
    }

    private static func walkDirLikeGo(_ dir: URL, notBefore: Date,
                                       walkable: (String) -> Bool, into paths: inout [String]) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
            options: []
        )) ?? []
        // Sort by lastPathComponent — the bare name. This matches Go's
        // filepath.WalkDir ordering, where the dir entry "<uuid>" sorts
        // before the file "<uuid>.jsonl".
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in sorted {
            let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                walkDirLikeGo(entry, notBefore: notBefore, walkable: walkable, into: &paths)
            } else if values?.isRegularFile == true,
                      walkable(entry.lastPathComponent) {
                if let mtime = values?.contentModificationDate, mtime < notBefore { continue }
                paths.append(entry.path)
            }
        }
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
