import Foundation

// MARK: - Vendor dispatch (port of internal/reader.vendorParser + parserFor)

/// Result of parsing a single JSONL line into zero or more events. Plural
/// because one Grok line (one `turn_completed`) yields a coverage event
/// plus one usage event per model. Mirrors Go's `([]Event, error)` return
/// from `vendorParser.Parse`, folded into one type since Swift has no
/// (slice, error) idiom.
public enum ParseResult2: Equatable, Sendable {
    case events([UsageEvent])
    case parseError
}

/// Everything that differs between one vendor's transcripts and another's.
/// Keeping it behind a protocol rather than a chain of `if vendor == …`
/// keeps each vendor's quirks — which files carry usage, how a project
/// key is derived, how many events one line yields — in one place.
/// Mirrors Go's `vendorParser` interface.
public protocol VendorParser {
    /// Whether a file base name can carry usage. The initial scan skips
    /// everything else, which matters for Grok: its session directories
    /// hold other files whose token fields are cumulative context, not
    /// usage.
    func walkable(_ name: String) -> Bool
    /// Turns one line into zero or more events. `.events([])` is normal
    /// (a line with nothing we want). `.parseError` means the line was
    /// not valid JSON and is counted as a parse error, never as spend.
    func parse(_ line: Data, path: String) -> ParseResult2
    /// The canonical project key for a transcript path, given the
    /// source's configured root.
    func project(_ path: String, root: String) -> String
    /// Whether the path belongs to a subagent transcript rather than a
    /// main session, given the source's configured root.
    func isSubagent(_ path: String, root: String) -> Bool
}

/// Returns the parser for one configured source's vendor. Unknown vendors
/// fall back to `ClaudeParser`, matching Go's `default:` case — there is
/// no vendor whose events should be silently dropped.
///
/// The `codex` case returns a throwaway `CodexParser` — safe here only
/// because every call site that reaches `codex` through this function
/// uses it for something stateless (`walkable`, or an `is CodexParser`
/// type check). `CodexParser` carries running totals and
/// session_meta-derived state across `parse` calls, so a fresh instance
/// per call would be exactly wrong for actual parsing — see its doc
/// comment and `Reader.parserForChange`, which keeps one `CodexParser`
/// per file path instead of asking here for a new one on every line.
public func parserFor(vendor: String) -> VendorParser {
    switch vendor {
    case "grok": return GrokParser()
    case "codex": return CodexParser()
    default: return ClaudeParser()
    }
}

/// Returns the first path segment of `slashPath` below `root`, or
/// `ok == false` when `slashPath` isn't under `root` at all.
///
/// This is root-relative rather than anchored on a literal marker
/// ("/projects/" for Claude, "/sessions/" for Grok): `Sources.load`
/// places no requirement that a configured root be named "projects" or
/// "sessions", so a marker search silently misfiles every event under a
/// root that omits it. Root-relative derivation is a no-op for every
/// shipped configuration: under `~/.claude/projects` the first segment
/// below root already is the encoded project key, and under
/// `~/.grok/sessions` it already is the encoded cwd. Mirrors Go's
/// `projectUnderRoot` — see `eb0c323` there for the bug this replaced.
func projectUnderRoot(root: String, slashPath: String) -> (segment: String, ok: Bool) {
    var slashRoot = normalizeSlashes(root)
    if slashRoot.hasSuffix("/") { slashRoot.removeLast() }
    guard !slashRoot.isEmpty, slashPath.hasPrefix(slashRoot + "/") else {
        return ("", false)
    }
    let rest = slashPath.dropFirst(slashRoot.count + 1)
    if let i = rest.firstIndex(of: "/") {
        return (String(rest[..<i]), true)
    }
    return (String(rest), true)
}

// MARK: - ClaudeParser (today's behaviour, extracted unchanged)

/// `ClaudeParser` is today's behaviour, extracted mostly unchanged — a
/// faithful wrapper over the existing `parseLine`/`isSubagentPath`, not a
/// rewrite. Mirrors Go's `claudeParser`.
///
/// `project` is the one exception: it derives the project key as the
/// first path segment under the source root (`projectUnderRoot`) rather
/// than anchoring on a literal `"/projects/"` marker — see
/// `projectFromPath`, which remains in this file only because
/// `ReaderTests` exercises it directly. Note this is deliberately not
/// `projectFromPath`: a custom Claude root has the same mis-attribution
/// risk `eb0c323` fixed for Grok (a root not literally named "projects"
/// would otherwise silently return "" for every event). Mirrors Go's
/// `claudeParser.Project` after that same commit.
public struct ClaudeParser: VendorParser {
    public init() {}

    public func walkable(_ name: String) -> Bool {
        name.hasSuffix(".jsonl")
    }

    public func parse(_ line: Data, path: String) -> ParseResult2 {
        switch ClaudeCounterCore.parseLine(line) {
        case .event(let ev): return .events([ev])
        case .skip: return .events([])
        case .parseError: return .parseError
        }
    }

    public func project(_ path: String, root: String) -> String {
        let (seg, ok) = projectUnderRoot(root: root, slashPath: normalizeSlashes(path))
        return ok ? seg : ""
    }

    /// "/subagents/" is a fixed subdirectory name under any session
    /// directory regardless of where the root sits, so this needs no
    /// root either — matches Go's `claudeParser.IsSubagent`.
    public func isSubagent(_ path: String, root: String) -> Bool {
        isSubagentPath(path)
    }
}

// MARK: - GrokParser (port of internal/reader/grok.go)

/// Converts Grok's `costUsdTicks`. Confirmed by elimination against a
/// known billing period: only the nano reading is physically possible
/// for one week of usage. Mirrors Go's `nanoDollarsPerUSD`.
private let nanoDollarsPerUSD = 1e9

/// The token+cost block Grok emits, at both the turn level and once per
/// entry of `modelUsage`.
///
/// `inputTokens` INCLUDES `cachedReadTokens` and `outputTokens` INCLUDES
/// `reasoningTokens` — `totalTokens` equals `inputTokens+outputTokens` on
/// every live record, which leaves no room for either to be additive.
/// Mapping them additively would inflate token charts by roughly the
/// cache-hit rate, which on real sessions is most of the input.
private struct GrokUsage: Decodable {
    let inputTokens: UInt64?
    let outputTokens: UInt64?
    let cachedReadTokens: UInt64?
    let costUsdTicks: Double?
    let modelUsage: [String: GrokUsage]?

    func toUsage() -> Usage {
        let cachedRead = cachedReadTokens ?? 0
        let input = inputTokens ?? 0
        let uncachedInput: UInt64
        if input >= cachedRead {
            uncachedInput = input - cachedRead
        } else {
            // Defensive: a vendor that changes the semantics under us
            // must not underflow into a nonsense figure.
            uncachedInput = 0
        }
        return Usage(
            input: uncachedInput,
            output: outputTokens ?? 0,
            // Grok reports no cache-creation figure.
            cacheCreate: 0,
            cacheRead: cachedRead
        )
    }
}

private struct GrokLine: Decodable {
    let timestamp: Int64?
    let params: Params?

    struct Params: Decodable {
        let sessionId: String?
        let update: Update?
    }

    struct Update: Decodable {
        let sessionUpdate: String?
        let prompt_id: String?
        let usage: GrokUsage?
    }
}

/// The session-directory segment (the percent-encoded working directory
/// that sits immediately under the configured root) from a Grok
/// transcript path. `ok` is false when `slashPath` isn't under `root` at
/// all. Both `grokProjectKey` and `isSubagent` need this same segment —
/// project attribution and subagent detection must never drift apart on
/// where that boundary is. Mirrors Go's `grokSessionDir`.
private func grokSessionDir(root: String, slashPath: String) -> (decoded: String, ok: Bool) {
    let (seg, ok) = projectUnderRoot(root: root, slashPath: slashPath)
    guard ok else { return ("", false) }
    // Undecodable is still a stable key; better a slightly ugly row than
    // a project's spend vanishing into the empty-key bucket.
    return (seg.removingPercentEncoding ?? seg, true)
}

/// Derives the project key from the session directory, which is the
/// percent-encoded working directory. Decoding it and re-encoding the
/// Claude way (every '/' and '.' becomes '-') keeps one working
/// directory one row in the per-project table no matter which vendor
/// produced the spend. Mirrors Go's `grokProjectKey`.
public func grokProjectKey(root: String, path: String) -> String {
    let (decoded, ok) = grokSessionDir(root: root, slashPath: normalizeSlashes(path))
    guard ok else { return "" }
    var result = ""
    result.reserveCapacity(decoded.count)
    for ch in decoded {
        result.append(ch == "/" || ch == "." ? "-" : ch)
    }
    return result
}

/// `grokParser` is everything that differs about Grok's transcripts.
/// Mirrors `tui/internal/reader/grok.go`'s `grokParser`, including its
/// comments — they carry the *why*, which is what stops a future edit
/// from re-introducing the double-count.
public struct GrokParser: VendorParser {
    public init() {}

    /// Restricts the scan to updates.jsonl. Grok writes other files under
    /// sessions/, and their `_meta.totalTokens` is a cumulative per-prompt
    /// context total, not usage — summing it would be a large silent
    /// overcount.
    public func walkable(_ name: String) -> Bool { name == "updates.jsonl" }

    /// Emits one coverage event per `turn_completed` plus one usage event
    /// per entry of `modelUsage`.
    ///
    /// The top-level usage block is the sum across `modelUsage`, so it is
    /// used only when `modelUsage` is empty — emitting both would double
    /// every figure. When `modelUsage` is absent the model is unknown to
    /// us, and the cell is recorded under the bare vendor name rather
    /// than dropped: a turn we cannot attribute to a model is still money
    /// spent.
    public func parse(_ line: Data, path: String) -> ParseResult2 {
        let l: GrokLine
        do {
            l = try JSONDecoder().decode(GrokLine.self, from: line)
        } catch {
            return .parseError
        }
        guard let update = l.params?.update else { return .events([]) }
        guard update.sessionUpdate == "turn_completed" else { return .events([]) }

        let ts = Date(timeIntervalSince1970: Double(l.timestamp ?? 0))
        let sessionID = l.params?.sessionId ?? ""
        let promptID = update.prompt_id ?? ""

        // Coverage events carry no MessageID/RequestID pair that dupes a
        // real usage event, so they would slip past the aggregator's
        // dedupe and inflate on any re-scan. prompt_id plus a sentinel
        // reuses that machinery verbatim.
        let cov = UsageEvent(
            timestamp: ts, sessionID: sessionID, cwd: "", project: "",
            model: "", messageID: promptID, requestID: "coverage",
            isSubagent: false, usage: Usage(),
            // A turn counts as covered only when it carries a usable
            // cost. Three records in the live corpus have real tokens
            // and costUsdTicks == 0; treating those as covered would let
            // a known-incomplete figure present itself as complete,
            // which is the exact failure this tally exists to catch.
            coverageOnly: true,
            hasUsage: (update.usage?.costUsdTicks ?? 0) != 0
        )
        var out: [UsageEvent] = [cov]

        guard let usage = update.usage else { return .events(out) }

        func emit(model: String, gu: GrokUsage) {
            out.append(UsageEvent(
                timestamp: ts, sessionID: sessionID, cwd: "", project: "",
                model: model,
                // prompt_id is unique per usage record; pairing it with
                // the model keeps a multi-model turn's cells distinct
                // under the aggregator's existing messageID:requestID
                // dedupe.
                messageID: promptID, requestID: model,
                isSubagent: false, usage: gu.toUsage(),
                costUSD: (gu.costUsdTicks ?? 0) / nanoDollarsPerUSD,
                costed: true
            ))
        }

        if let modelUsage = usage.modelUsage, !modelUsage.isEmpty {
            for (model, mu) in modelUsage {
                emit(model: model, gu: mu)
            }
        } else {
            emit(model: "grok", gu: usage)
        }
        return .events(out)
    }

    public func project(_ path: String, root: String) -> String {
        grokProjectKey(root: root, path: path)
    }

    /// Flags Grok's per-subagent worktree sessions, which live in a
    /// directory named `subagent-<that session's own id>`.
    ///
    /// They are counted, not skipped: a parent turn does NOT include its
    /// subagents' cost. The match is on the final path segment rather
    /// than anywhere in the path, so a user whose own worktree happens to
    /// be named "subagent-foo" does not get their main-session spend
    /// filed under the subagent column.
    public func isSubagent(_ path: String, root: String) -> Bool {
        let (decoded, ok) = grokSessionDir(root: root, slashPath: normalizeSlashes(path))
        guard ok else { return false }
        let last = decoded.lastIndex(of: "/").map { String(decoded[decoded.index(after: $0)...]) } ?? decoded
        return last.hasPrefix("subagent-")
    }
}
