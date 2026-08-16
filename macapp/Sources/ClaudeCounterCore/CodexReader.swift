import Foundation

// MARK: - CodexParser (port of internal/reader/codex.go)

/// Resolves the model for a session that never emits
/// `thread_settings_applied` — 25 of 74 files in the corpus probed on
/// 2026-08-16, from an older CLI. `parent_thread_id` discriminates them
/// exactly: across all 49 sessions that DO declare, no-parent always
/// meant gpt-5.6-sol (25 files) and has-parent always meant
/// codex-auto-review (24 files), with zero exceptions.
///
/// Data, not logic, because these mappings are as much a moving target as
/// `Pricing.swift`'s model aliases, which resolve codex-auto-review's
/// pricing the same way, for the same reason. Mirrors Go's
/// `codexFallbackModel`.
let codexFallbackModel: [Bool: String] = [false: "gpt-5.6-sol", true: "codex-auto-review"]

/// Resolves the model in effect for one token_count event. A declared
/// `thread_settings.model` always wins; only a session that has declared
/// none at all falls back to `codexFallbackModel`, keyed on whether
/// session_meta carried a `parent_thread_id`. Mirrors Go's
/// `codexModelForSession`.
func codexModelForSession(declared: String, hasParent: Bool) -> String {
    if !declared.isEmpty { return declared }
    return codexFallbackModel[hasParent] ?? "gpt-5.6-sol"
}

/// Returns a-b, clamped to 0 rather than wrapping, mirroring
/// `GrokUsage.toUsage`'s defensive subtraction. Every caller here is
/// subtracting two values this parser has already reasoned should not
/// invert; the clamp exists for the case where that reasoning is wrong,
/// because these are `UInt64`s and a wrong number here is not a slightly
/// wrong number — it is a wraparound to near 2^64 flowing straight into a
/// dollar figure. Mirrors Go's `saturatingSub`.
func saturatingSub(_ a: UInt64, _ b: UInt64) -> UInt64 {
    a < b ? 0 : a - b
}

/// One rollout line's top-level shape: `session_meta` (once, carrying cwd
/// and parent_thread_id), `event_msg` (carrying, among other things,
/// token_count and thread_settings_applied), and `turn_context` (carries
/// neither a model nor usage and is otherwise ignored).
///
/// Unlike Go, which leaves `payload` as `json.RawMessage` and decodes it
/// per `type` in a second pass, this flattens every payload shape's
/// fields into ONE `Decodable` struct (`CodexPayload`): none of
/// session_meta's keys (session_id, cwd, parent_thread_id) collide with
/// event_msg's (type, info, thread_settings), so a single
/// optional-everything struct decodes whichever shape is actually
/// present and leaves the rest nil.
private struct CodexLine: Decodable {
    let timestamp: Date?
    let type: String?
    let payload: CodexPayload?
}

private struct CodexPayload: Decodable {
    // session_meta
    let sessionId: String?
    let cwd: String?
    let parentThreadId: String?
    // event_msg
    let type: String?
    let info: CodexInfo?
    let threadSettings: CodexThreadSettings?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case parentThreadId = "parent_thread_id"
        case type
        case info
        case threadSettings = "thread_settings"
    }
}

private struct CodexInfo: Decodable {
    let totalTokenUsage: CodexTokenUsage?
    enum CodingKeys: String, CodingKey {
        case totalTokenUsage = "total_token_usage"
    }
}

private struct CodexThreadSettings: Decodable {
    let model: String?
}

/// Mirrors `info.total_token_usage` (and, identically shaped,
/// `info.last_token_usage`, which this parser never reads — see
/// `CodexParser.deltaEvent`). Verified on live records: total_tokens ==
/// input_tokens + output_tokens, so cached_input_tokens is a subset of
/// input_tokens and reasoning_output_tokens a subset of output_tokens.
/// reasoning_output_tokens is therefore never added on top of
/// output_tokens. Mirrors Go's `codexTokenUsage`.
private struct CodexTokenUsage: Decodable {
    let inputTokens: UInt64?
    let cachedInputTokens: UInt64?
    let outputTokens: UInt64?
    let reasoningOutputTokens: UInt64?
    let totalTokens: UInt64?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }
}

/// `CodexParser` is stateful, unlike `ClaudeParser` and `GrokParser`: a
/// delta needs the previous cumulative reading, the model needs the last
/// `thread_settings_applied`, and the project and subagent flag come from
/// session_meta, which appears only on line 1. None of that can be
/// recovered from a single line in isolation.
///
/// Lifecycle (the owning `Reader` actor's responsibility):
///   - One `CodexParser` per file path, kept alive for as long as the
///     Reader tracks that path — see `Reader.parserForChange`.
///   - `parse` is called once per line, in file order. `onChange` may
///     resume a growing file mid-stream from a byte offset on a later
///     call; reusing the SAME `CodexParser` instance across those calls
///     is what keeps the running totals and declared model correct.
///     Using a fresh parser per call would make every resumed read's
///     first delta equal to the session's entire total-so-far — a large
///     silent over-count that grows with activity — and would forget
///     session_meta, losing project and subagent attribution for the
///     rest of the file.
///   - `reset()` must be called, and the zero value substituted, whenever
///     a path starts being read from byte offset 0 for a reason OTHER
///     than "we have never seen this path before": specifically, when
///     the underlying file has shrunk or been replaced. A fresh path
///     needs no explicit reset — its `CodexParser` is simply constructed
///     fresh.
///   - Never share one `CodexParser` instance across two different
///     paths: it would attribute one session's totals, model, and cwd to
///     another.
///
/// A `class`, not a `struct`, precisely because that lifecycle needs
/// reference semantics: `Reader`'s per-path dictionary must hand back the
/// SAME mutable instance on every call for one path, exactly like Go's
/// `*codexParser` pointer. Mirrors Go's `codexParser`, including its
/// lifecycle comment.
public final class CodexParser: VendorParser {
    // Running totals from the most recently seen token_count reading;
    // meaningful only when havePrev is true.
    private var havePrev = false
    private var prevInput: UInt64 = 0
    private var prevCached: UInt64 = 0
    private var prevOutput: UInt64 = 0
    private var prevTotal: UInt64 = 0
    private var model = ""        // most recent declared thread_settings.model; "" if none yet
    private var cwd = ""          // from session_meta; "" until seen
    private var sessionID = ""    // from session_meta; "" until seen
    private var hasParent = false // parent_thread_id was present on session_meta

    public init() {}

    /// Discards all per-file state. Call it (and only it — never
    /// construct a new `CodexParser` mid-file) when the Reader starts
    /// reading a previously-seen path from byte offset 0 again, i.e. the
    /// file shrank or was replaced. See the type's doc comment for the
    /// full lifecycle. Mirrors Go's `codexParser.Reset`.
    public func reset() {
        havePrev = false
        prevInput = 0
        prevCached = 0
        prevOutput = 0
        prevTotal = 0
        model = ""
        cwd = ""
        sessionID = ""
        hasParent = false
    }

    /// Restricts the scan to rollout files. Codex writes other
    /// bookkeeping under ~/.codex/sessions that carries neither a model
    /// nor usage. Mirrors Go's `codexParser.Walkable`.
    public func walkable(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    /// Turns one rollout line into zero or one usage events. A malformed
    /// line is a parse error; every recognised-but-irrelevant line
    /// (turn_context, an event_msg whose payload is neither token_count
    /// nor thread_settings_applied, a token_count with no
    /// total_token_usage) yields nothing without erroring. Mirrors Go's
    /// `codexParser.Parse`.
    public func parse(_ line: Data, path: String) -> ParseResult2 {
        let l: CodexLine
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let str = try decoder.singleValueContainer().decode(String.self)
                if let date = isoDate(str) { return date }
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                    debugDescription: "invalid ISO8601 date: \(str)")
            }
            l = try decoder.decode(CodexLine.self, from: line)
        } catch {
            return .parseError
        }

        switch l.type {
        case "session_meta":
            cwd = l.payload?.cwd ?? ""
            sessionID = l.payload?.sessionId ?? ""
            hasParent = !(l.payload?.parentThreadId ?? "").isEmpty
            return .events([])

        case "event_msg":
            guard let ev = l.payload else { return .events([]) }
            switch ev.type {
            case "thread_settings_applied":
                if let m = ev.threadSettings?.model, !m.isEmpty {
                    model = m
                }
                return .events([])
            case "token_count":
                guard let usage = ev.info?.totalTokenUsage else {
                    // total_token_usage absent: skip the event but leave
                    // the running total untouched, so the next reading
                    // still deltas against the last real one.
                    return .events([])
                }
                return .events(deltaEvent(usage, timestamp: l.timestamp ?? .distantPast))
            default:
                return .events([])
            }

        default:
            // turn_context and anything else carries no model and no usage.
            return .events([])
        }
    }

    /// The central rule this parser exists to implement: total_token_usage
    /// is cumulative per session and was verified monotonic in 69 of 69
    /// corpus files, so consecutive differences telescope to the
    /// session's final total exactly. Summing last_token_usage instead
    /// overshoots it by 0.86% corpus-wide, which is what the superseded
    /// design tried to fix with a dedupe key that does not exist in the
    /// data.
    ///
    /// A repeated reading yields a zero delta and is dropped, which is
    /// why no dedupe key is needed. A decrease means the session
    /// restarted its counter: adopt the new value and contribute
    /// nothing, because a negative cell would be a wrong number rather
    /// than a missing one.
    ///
    /// Day attribution is the local day of THIS event — the closing
    /// reading — via the timestamp the caller passes in, per the
    /// design's rule that a delta belongs to whichever event reports the
    /// new total. Mirrors Go's `codexParser.deltaEvent`.
    private func deltaEvent(_ cur: CodexTokenUsage, timestamp: Date) -> [UsageEvent] {
        let curInput = cur.inputTokens ?? 0
        let curCached = cur.cachedInputTokens ?? 0
        let curOutput = cur.outputTokens ?? 0
        let curTotal = cur.totalTokens ?? 0

        let first = !havePrev
        let decreased = havePrev && curTotal < prevTotal

        var deltaInput: UInt64 = 0
        var deltaCached: UInt64 = 0
        var deltaOutput: UInt64 = 0

        if first {
            // The session's first reading deltas against an implicit
            // baseline of zero, i.e. it is its own value.
            deltaInput = curInput
            deltaCached = curCached
            deltaOutput = curOutput
        } else if decreased {
            // Restart: adopt the new reading as the running total but
            // contribute nothing. Handled below after the totals are saved.
        } else {
            // Saturating, not plain subtraction, even though the
            // total_tokens check above already ruled out a
            // whole-session decrease: these are UInt64s, and the guard
            // here is against a subfield decreasing while the total does
            // not (never observed in the corpus, but not provably
            // impossible for a future CLI version). A wrong number that
            // degrades to zero is recoverable; a wrong number that wraps
            // to near 2^64 and flows straight into a dollar figure is
            // not, and this project's rule is that a failure must
            // degrade to fewer cells, never to a wrong one.
            deltaInput = saturatingSub(curInput, prevInput)
            deltaCached = saturatingSub(curCached, prevCached)
            deltaOutput = saturatingSub(curOutput, prevOutput)
        }

        prevInput = curInput
        prevCached = curCached
        prevOutput = curOutput
        prevTotal = curTotal
        havePrev = true

        if decreased {
            return []
        }
        if !first && deltaInput == 0 && deltaCached == 0 && deltaOutput == 0 {
            // The duplicate case: identical totals telescope to a zero
            // delta with no need for a dedupe key.
            return []
        }

        let inputAfterCache = saturatingSub(deltaInput, deltaCached)

        return [UsageEvent(
            timestamp: timestamp,
            sessionID: sessionID,
            cwd: cwd,
            project: "",
            model: codexModelForSession(declared: model, hasParent: hasParent),
            messageID: "",
            requestID: "",
            isSubagent: hasParent,
            usage: Usage(
                input: inputAfterCache,
                output: deltaOutput,
                // Codex reports no cache-creation figure.
                cacheCreate: 0,
                cacheRead: deltaCached
            )
        )]
    }

    /// Returns the encoded cwd captured from session_meta, not something
    /// derived from `path`: unlike Claude's and Grok's layouts, which
    /// both encode the project into the transcript path itself, Codex's
    /// is ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl — dated, not
    /// project-keyed. The path carries no project information at all, so
    /// the in-file cwd is the only source. This is the one point where
    /// `CodexParser`'s `VendorParser` methods read the parser's state
    /// instead of their `path`/`root` arguments. Mirrors Go's
    /// `codexParser.Project`.
    public func project(_ path: String, root: String) -> String {
        var result = ""
        result.reserveCapacity(cwd.count)
        for ch in cwd {
            result.append(ch == "/" || ch == "." ? "-" : ch)
        }
        return result
    }

    /// Reads the same session_meta state `project` does, for the same
    /// reason: parent_thread_id, not the path, is Codex's subagent
    /// marker. Mirrors Go's `codexParser.IsSubagent`.
    public func isSubagent(_ path: String, root: String) -> Bool {
        hasParent
    }
}
