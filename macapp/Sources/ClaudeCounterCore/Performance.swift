import Foundation

// MARK: - What the logs can and cannot tell us
//
// Claude Code appends one JSONL record per assistant *content block*, and
// writes it when the block completes — never per streamed token. So the
// timeline of one API request is:
//
//   user record (prompt or tool_result)   ← request sent
//   assistant record, block 0             ← first block complete
//   assistant record, block n             ← last block complete
//
// "Time to first block" and end-to-end duration are therefore measured
// directly, but true time-to-first-token and inter-token latency are not.
// They are *estimated* per bucket by fitting
//
//   duration = a + ITL · output_tokens + c · context_k
//
// over many requests: the intercept at a fixed context is the TTFT
// estimate, the slope is seconds per output token. The context term is
// what stops "my sessions got longer" from reading as "the model got
// slower". See `PerformanceStats.fit`.
//
// Deliberately separate from Reader/Aggregator/Cache: pairing a request
// with the user record that started it needs parentUuid and user lines,
// which the spend pipeline neither reads nor should start carrying. This
// file never writes to disk; its only cache is in memory.

/// One API request, reconstructed from a session file.
public struct RequestSample: Equatable, Sendable {
    public var requestID: String
    /// When the first content block completed.
    public var time: Date
    public var model: String
    public var isSubagent: Bool
    /// perTurnEffort, else effort; nil on clients that don't record it.
    public var effort: String?
    /// Request sent → first block complete, seconds.
    public var firstBlock: Double
    /// Request sent → last block complete, seconds.
    public var duration: Double
    public var output: UInt64
    /// input + cache read + cache write: the whole prompt.
    public var context: UInt64
    public var cacheRead: UInt64
    public var thinkingTokens: UInt64?
    /// Tool calls this request issued, and how their results came back.
    public var toolCalls: Int
    public var toolErrors: ToolErrorCounts
    public var interrupted: Bool
    public var rebuild: CacheRebuild
    // Pricing inputs for Hints. Defaulted so existing callers stay valid.
    public var input: UInt64 = 0
    public var cacheWrite: UInt64 = 0
    /// Part of `cacheWrite` written with the 1-hour TTL (billed 2× input).
    public var cacheWrite1h: UInt64 = 0
    /// Session file the request came from.
    public var session: String = ""

    /// What the request cost at `pricing`'s rates (flat; no long-context premium).
    public func cost(_ pricing: PricingTable) -> Double {
        pricing.cost(model: model, usage: Usage(input: input, output: output, cacheCreate: cacheWrite,
                                                 cacheRead: cacheRead, cacheCreate1h: cacheWrite1h))
    }

    /// Request start, derived. Used for concurrency.
    public var start: Date { time.addingTimeInterval(-firstBlock) }
}

public struct ToolErrorCounts: Equatable, Sendable {
    public var misuse = 0, exit = 0, policy = 0, environment = 0
    public init() {}
}

/// A main-session turn whose cache read collapsed and whose prefix was
/// written again. `afterIdle` = more than an hour since the previous turn,
/// i.e. the 1h cache TTL ran out; `midFlow` = the context changed under it.
public enum CacheRebuild: Int, Sendable { case none, midFlow, afterIdle }

// MARK: - Tool error classes

/// Which tool errors count against the model. Only `.misuse` is the
/// model's own mistake (a stale Edit string, a file it never read, a bad
/// path). Policy blocks and environment failures are not, and a nonzero
/// exit is ambiguous — grep finding nothing exits 1.
public enum ToolErrorClass: Sendable { case misuse, exit, policy, environment }

public func classifyToolError(_ body: String) -> ToolErrorClass {
    let head = body.prefix(400)
    let policy = ["Permission", "denied", "doesn't want to proceed", "classifier", "Blocked:",
                  "cannot be checked", "contains multiple operations", "cannot spawn", "unable to fetch",
                  "protocol is blocked", "outside allowed roots", "requires approval",
                  "changes directory before running git"]
    if policy.contains(where: { head.contains($0) }) { return .policy }
    let env = ["posix_spawn", "ENOTFOUND", "ECONNREFUSED", "ETIMEDOUT", "ECONNRESET", "ENOSPC",
               "timed out", "rate limit", "status code 5", "status code 429"]
    if env.contains(where: { head.contains($0) }) { return .environment }
    if body.hasPrefix("Exit code") { return .exit }
    return .misuse
}

// MARK: - Per-file parsing

/// Minimal view of a session record. Decodable rather than
/// JSONSerialization so the (often huge) tool_result bodies and tool_use
/// inputs are skipped without being materialised as Foundation objects.
private struct PerfLine: Decodable {
    let type: String?
    let uuid: String?
    let parentUuid: String?
    let timestamp: String?
    let requestId: String?
    let isSidechain: Bool?
    let isApiErrorMessage: Bool?
    let effort: String?
    let perTurnEffort: String?
    let message: Message?

    struct Message: Decodable {
        let model: String?
        let usage: Usage?
        let content: Content?
    }
    struct Usage: Decodable {
        let input_tokens: UInt64?
        let output_tokens: UInt64?
        let cache_creation_input_tokens: UInt64?
        let cache_read_input_tokens: UInt64?
        let output_tokens_details: Details?
        let cache_creation: CacheCreation?
        struct Details: Decodable { let thinking_tokens: UInt64? }
        struct CacheCreation: Decodable { let ephemeral_1h_input_tokens: UInt64? }
    }
    /// `message.content` is either a bare string (typed prompt) or an
    /// array of blocks. Anything else decodes as empty rather than failing
    /// the whole line.
    struct Content: Decodable {
        var text: String?
        var blocks: [Block] = []
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { text = s }
            else if let b = try? c.decode([Block].self) { blocks = b }
        }
    }
    struct Block: Decodable {
        var type: String?
        var text: String?
        var isError: Bool?
        var body: String?
        enum CodingKeys: String, CodingKey { case type, text, is_error, content }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decode(String.self, forKey: .type)
            text = try? c.decode(String.self, forKey: .text)
            isError = try? c.decode(Bool.self, forKey: .is_error)
            // tool_result content: a string, or [{type:text,text:…}].
            if let s = try? c.decode(String.self, forKey: .content) { body = s }
            else if let parts = try? c.decode([Part].self, forKey: .content) {
                body = parts.compactMap(\.text).joined(separator: "\n")
            }
        }
        struct Part: Decodable { let text: String? }
    }
}

/// Turn one whole session file into request samples. Pure — tests feed
/// fixture bytes; the scanner uses `PerformanceFileParser` directly so it
/// can resume a growing file.
public func parsePerformance(_ data: Data, path: String) -> [RequestSample] {
    let p = PerformanceFileParser(path: path)
    p.feed(data)
    return p.samples
}

/// Incremental parser for one session file. Lines can arrive in any
/// number of `feed` calls (the watcher reports a file each time a block
/// is appended); only complete lines are consumed, the same rule as
/// `Reader.onChange`. A request's sample is recomputed whenever one of
/// its blocks or tool results arrives, because both keep coming after
/// the first block is written.
///
/// Holds only what pairing needs — uuid → (type, parent, time) and each
/// block's usage — never the decoded content, so a long session's tool
/// bodies are not kept alive. Not thread-safe; owned by one actor.
public final class PerformanceFileParser {
    public let path: String
    /// Bytes consumed so far: the next `feed` must start here.
    public private(set) var offset: Int64 = 0

    private struct Node { let isUser: Bool; let parent: String?; let time: Date }
    private struct Block {
        let parent: String?, time: Date, model: String?
        let input: UInt64, output: UInt64, cacheRead: UInt64, cacheWrite: UInt64, cacheWrite1h: UInt64
        let thinking: UInt64?, sidechain: Bool, effort: String?
    }
    private struct Outcome { var tools = 0; var errors = ToolErrorCounts(); var interrupted = false }

    private let isSub: Bool
    private let decoder = JSONDecoder()
    private var nodes: [String: Node] = [:]
    private var requestOf: [String: String] = [:]      // assistant uuid → requestId
    private var blocks: [String: [Block]] = [:]
    private var ridOrder: [String] = []
    private var outcomes: [String: Outcome] = [:]
    private var byRequest: [String: RequestSample] = [:]

    public init(path: String) {
        self.path = path
        self.isSub = isSubagentPath(path)
    }

    /// Consume the complete lines in `data`, which must be the file's
    /// bytes from `offset` on. Returns whether any sample changed.
    @discardableResult
    public func feed(_ input: Data) -> Bool {
        // nextNewline walks 0-based indices; a Data slice isn't.
        let data = input.startIndex == 0 ? input : Data(input)
        var touched = Set<String>()
        var consumed = 0
        while consumed < data.count {
            guard let nl = nextNewline(in: data, from: consumed) else { break }
            let slice = data[consumed..<nl]
            consumed = nl + 1
            if isWhitespaceOnly(slice) { continue }
            if let rid = ingest(slice) { touched.insert(rid) }
        }
        offset += Int64(consumed)
        for rid in touched { byRequest[rid] = sample(rid) }
        return !touched.isEmpty
    }

    /// Samples in file order, with cache rebuilds flagged.
    public var samples: [RequestSample] {
        var out = ridOrder.compactMap { byRequest[$0] }
        // Cache rebuilds only make sense along one main session's sequence.
        guard !isSub else { return out }
        out.sort { $0.time < $1.time }
        for i in out.indices.dropFirst() {
            let a = out[i - 1], b = out[i]
            let prevRead = Double(a.cacheRead)
            let written = Double(b.context - b.cacheRead)
            if prevRead >= 20_000 && Double(b.cacheRead) < 0.5 * prevRead && written >= 0.5 * prevRead {
                out[i].rebuild = b.time.timeIntervalSince(a.time) > 3600 ? .afterIdle : .midFlow
            }
        }
        return out
    }

    /// Record one line; returns the request it affects, if any.
    private func ingest(_ slice: Data) -> String? {
        guard let line = try? decoder.decode(PerfLine.self, from: slice),
              let uuid = line.uuid, let ts = line.timestamp, let t = isoDate(ts) else { return nil }
        let type = line.type ?? ""
        nodes[uuid] = Node(isUser: type == "user", parent: line.parentUuid, time: t)

        if type == "assistant" {
            guard let rid = line.requestId, !(line.isApiErrorMessage ?? false) else { return nil }
            requestOf[uuid] = rid
            let u = line.message?.usage
            if blocks[rid] == nil { ridOrder.append(rid) }
            blocks[rid, default: []].append(Block(
                parent: line.parentUuid, time: t, model: line.message?.model,
                input: u?.input_tokens ?? 0, output: u?.output_tokens ?? 0,
                cacheRead: u?.cache_read_input_tokens ?? 0, cacheWrite: u?.cache_creation_input_tokens ?? 0,
                cacheWrite1h: u?.cache_creation?.ephemeral_1h_input_tokens ?? 0,
                thinking: u?.output_tokens_details?.thinking_tokens,
                sidechain: line.isSidechain ?? false, effort: line.perTurnEffort ?? line.effort))
            return rid
        }

        // Tool results and interrupts are user records whose parent is the
        // assistant record that made the call — that's how an outcome is
        // charged to the request that caused it.
        guard type == "user", let p = line.parentUuid, let rid = requestOf[p],
              let content = line.message?.content else { return nil }
        var o = outcomes[rid] ?? Outcome()
        if content.text?.hasPrefix("[Request interrupted by user") == true { o.interrupted = true }
        for b in content.blocks {
            if b.text?.hasPrefix("[Request interrupted by user") == true { o.interrupted = true }
            guard b.type == "tool_result" else { continue }
            o.tools += 1
            guard b.isError == true else { continue }
            switch classifyToolError(b.body ?? "") {
            case .misuse: o.errors.misuse += 1
            case .exit: o.errors.exit += 1
            case .policy: o.errors.policy += 1
            case .environment: o.errors.environment += 1
            }
        }
        outcomes[rid] = o
        return rid
    }

    private func sample(_ rid: String) -> RequestSample? {
        guard let bl = blocks[rid], let first = bl.first, let last = bl.last,
              let model = last.model, model != "<synthetic>" else { return nil }
        // Request start: walk up the parent chain to the nearest user
        // record written before the first block. Attachment and system
        // records sit in between and are often written *after* the
        // request went out, so the direct parent is not good enough.
        var p = first.parent.flatMap { nodes[$0] }
        var hops = 0
        while let cur = p, hops < 40 {
            if cur.isUser && cur.time.timeIntervalSince(first.time) <= -0.02 { break }
            p = cur.parent.flatMap { nodes[$0] }
            hops += 1
        }
        guard let start = p, start.isUser else { return nil }
        let duration = last.time.timeIntervalSince(start.time)
        guard duration > 0 else { return nil }
        let o = outcomes[rid] ?? Outcome()
        // Top-level output_tokens, not the iterations[] sum the spend
        // reader uses: this is about how long *this* request streamed.
        return RequestSample(
            requestID: rid, time: first.time, model: model,
            isSubagent: isSub || first.sidechain, effort: first.effort,
            firstBlock: first.time.timeIntervalSince(start.time), duration: duration,
            output: last.output, context: last.input &+ last.cacheRead &+ last.cacheWrite,
            cacheRead: last.cacheRead,
            thinkingTokens: bl.reversed().lazy.compactMap(\.thinking).first,
            toolCalls: o.tools, toolErrors: o.errors, interrupted: o.interrupted, rebuild: .none,
            input: last.input, cacheWrite: last.cacheWrite, cacheWrite1h: last.cacheWrite1h, session: path)
    }
}

// MARK: - Scanner

/// Request samples for every Claude session file, kept current.
///
/// `backfill` reads the last N days once (on first use — the cost is
/// seconds of CPU, so it isn't paid at launch for a tab nobody opened).
/// After that `fileChanged` — fed by AppState's existing FSEvents watcher,
/// the same events the spend reader gets — resumes each touched file
/// from its offset, so a request appears within moments of its last
/// block being written.
///
/// Parsers are kept only for the most recently touched files; an evicted
/// file is simply re-read in full on its next change. Nothing is written
/// to disk: a cold backfill is quick, and staying out of Cache.swift
/// keeps this from ever touching the spend data.
public actor PerformanceScanner {
    private struct FileState {
        var parser: PerformanceFileParser?
        var samples: [RequestSample]
        var touched: Date
    }
    private var files: [String: FileState] = [:]
    private var notBefore = Date.distantPast
    private var merged: [RequestSample]?
    private var version = 0
    public private(set) var isActive = false

    /// Ticks once per change batch; the view rebuilds its report off it.
    public nonisolated let updates: AsyncStream<Int>
    private let continuation: AsyncStream<Int>.Continuation

    /// Live parsers kept in memory. Active sessions are a handful; this
    /// is generous headroom without holding state for thousands of files.
    static let liveParsers = 64

    public init() {
        (updates, continuation) = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(1))
    }

    /// Read every session file modified since `notBefore`. Calling it
    /// again (Rescan) starts over.
    public func backfill(roots: [String], notBefore: Date,
                         progress: @Sendable @escaping (Int, Int) -> Void = { _, _ in }) async {
        self.notBefore = notBefore
        let paths = roots.flatMap {
            Reader.candidateFiles(under: $0, notBefore: notBefore, walkable: { $0.hasSuffix(".jsonl") })
        }.map(canonicalPath)
        let total = paths.count
        progress(0, total)
        var done = 0
        var fresh: [String: FileState] = [:]
        let recent = Date().addingTimeInterval(-3600)
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: (String, PerformanceFileParser, Date).self) { group in
            var next = 0
            func enqueue() {
                guard next < paths.count else { return }
                let path = paths[next]; next += 1
                group.addTask {
                    let parser = PerformanceFileParser(path: path)
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) {
                        parser.feed(data)
                    }
                    let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
                    return (path, parser, mtime ?? .distantPast)
                }
            }
            for _ in 0..<width { enqueue() }
            for await (path, parser, mtime) in group {
                // Keep a parser only for files still being written to.
                fresh[path] = FileState(parser: mtime > recent ? parser : nil, samples: parser.samples, touched: mtime)
                done += 1
                if done % 50 == 0 || done == total { progress(done, total) }
                enqueue()
            }
        }
        files = fresh
        isActive = true
        evictParsers()
        changed()
    }

    /// A watcher event for `path`. Ignored until the first backfill —
    /// before that nobody is looking, and the backfill will read it.
    public func fileChanged(_ change: FileChange) {
        guard isActive, change.path.hasSuffix(".jsonl") else { return }
        let path = canonicalPath(change.path)
        if change.kind == .remove {
            if files.removeValue(forKey: path) != nil { changed() }
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        var state = files[path] ?? FileState(parser: nil, samples: [], touched: Date())
        // No live parser (new or evicted file), or the file shrank: start over.
        if state.parser == nil || size < state.parser!.offset {
            state.parser = PerformanceFileParser(path: path)
        }
        let parser = state.parser!
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(parser.offset))
        let data = (try? handle.readToEnd()) ?? Data()
        let didChange = parser.feed(data)
        state.touched = Date()
        if didChange || files[path] == nil {
            state.samples = parser.samples
            files[path] = state
            evictParsers()
            changed()
        } else {
            files[path] = state
        }
    }

    /// Every sample since the backfill horizon, deduped and time-sorted.
    /// Main and subagent files repeat some requests; the first in walk
    /// order wins — the order the spend reader dedupes in — so the result
    /// is the same whether a file arrived by backfill or live.
    public func snapshot() -> [RequestSample] {
        if let merged { return merged }
        var seen = Set<String>()
        var out: [RequestSample] = []
        for path in files.keys.sorted(by: walkOrder) {
            for s in files[path]!.samples where s.time >= notBefore {
                if seen.insert(s.requestID).inserted { out.append(s) }
            }
        }
        out.sort { $0.time < $1.time }
        merged = out
        return out
    }

    private func changed() {
        merged = nil
        version += 1
        continuation.yield(version)
    }

    private func evictParsers() {
        let live = files.filter { $0.value.parser != nil }
        guard live.count > Self.liveParsers else { return }
        for (path, _) in live.sorted(by: { $0.value.touched > $1.value.touched }).dropFirst(Self.liveParsers) {
            files[path]?.parser = nil
        }
    }
}

/// The one spelling a file is keyed by, whichever way it was reached.
/// FSEvents reports symlink-resolved paths (/var → /private/var) while the
/// walk returns them as configured; keyed apart, a backfilled entry would
/// go stale beside its live twin and win the dedupe. resolvingSymlinksInPath
/// strips a leading /private, so applying it to both sides is what makes
/// them agree.
func canonicalPath(_ path: String) -> String {
    (path as NSString).resolvingSymlinksInPath
}

/// `Reader.candidateFiles`' depth-first, name-sorted walk order, as a
/// comparator: compare path components pairwise. A directory "<uuid>"
/// sorts before its sibling file "<uuid>.jsonl", so subagent files come
/// before their main session, exactly as in the walk.
func walkOrder(_ a: String, _ b: String) -> Bool {
    let x = a.split(separator: "/"), y = b.split(separator: "/")
    for (p, q) in zip(x, y) where p != q { return p < q }
    return x.count < y.count
}

// MARK: - Statistics

public enum PerformanceStats {

    /// Linear-interpolated quantile, `q` in 0...1. nil for no data.
    public static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let p = Double(s.count - 1) * q
        let lo = Int(p.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (p - Double(lo))
    }

    /// Smallest sample count a percentile is shown at: a p99 of twenty
    /// requests is just their maximum.
    public static func minSamples(for q: Double) -> Int {
        q >= 0.99 ? 200 : q >= 0.95 ? 100 : 20
    }

    public struct Fit: Equatable, Sendable {
        /// Estimated time to first token at `referenceContextK`, seconds.
        public var ttft: Double
        public var ttftSD: Double
        /// Estimated inter-token latency, milliseconds per output token.
        public var itlMs: Double
        public var itlSD: Double
        /// Seconds added per 100k tokens of context.
        public var contextCostPer100k: Double
        public var n: Int
        public var tokensPerSecond: Double { 1000 / itlMs }
    }

    public static let referenceContextK = 50.0

    /// Trimmed least squares of duration = a + s·output + c·context_k.
    /// The worst 1% of durations go first (stalls of hours — laptop
    /// sleep, resumed sessions — would otherwise flatten the slope), then
    /// three rounds keep the best-fitting 80%: tool waits and queueing
    /// only ever add time, so the residuals are one-sided. The ±σ comes
    /// from the trimmed set and so understates the true uncertainty.
    public static func fit(_ samples: [RequestSample]) -> Fit? {
        guard samples.count >= 100 else { return nil }
        let outs = samples.map { Double($0.output) }
        guard let lo = outs.min(), let hi = outs.max(), hi - lo >= 200 else { return nil }
        let cap = quantile(samples.map(\.duration), 0.99) ?? .infinity
        var rows = samples.filter { $0.duration <= cap }.map { (Double($0.output), Double($0.context) / 1000, $0.duration) }
        var beta = [0.0, 0.0, 0.0]
        var inv: [Double] = []
        for round in 0..<4 {
            var xtx = [Double](repeating: 0, count: 9), xty = [0.0, 0.0, 0.0]
            for (o, c, y) in rows {
                let v = [1, o, c]
                for i in 0..<3 {
                    xty[i] += v[i] * y
                    for j in 0..<3 { xtx[i * 3 + j] += v[i] * v[j] }
                }
            }
            guard let m = invert3(xtx) else { return nil }
            inv = m
            // Spelled out with explicit types: as one-line closures these
            // exceeded CI's type-checker time limit.
            for i in 0..<3 {
                let a: Double = m[i * 3] * xty[0]
                let b: Double = m[i * 3 + 1] * xty[1]
                let c: Double = m[i * 3 + 2] * xty[2]
                beta[i] = a + b + c
            }
            if round == 3 { break }
            let (b0, b1, b2) = (beta[0], beta[1], beta[2])
            let res: [Double] = rows.map { (r: (Double, Double, Double)) -> Double in
                let predicted: Double = b0 + b1 * r.0 + b2 * r.1
                return abs(r.2 - predicted)
            }
            let lim = quantile(res, 0.8) ?? .infinity
            rows = zip(rows, res).filter { $0.1 <= lim }.map(\.0)
        }
        guard beta[1] > 0, rows.count > 3 else { return nil }
        var ssr = 0.0
        for r in rows {
            let e: Double = r.2 - (beta[0] + beta[1] * r.0 + beta[2] * r.1)
            ssr += e * e
        }
        let s2 = ssr / Double(rows.count - 3)
        let cov = inv.map { $0 * s2 }
        let k = referenceContextK
        return Fit(ttft: beta[0] + beta[2] * k,
                   ttftSD: max(0, cov[0] + k * k * cov[8] + 2 * k * cov[2]).squareRoot(),
                   itlMs: 1000 * beta[1], itlSD: 1000 * max(0, cov[4]).squareRoot(),
                   contextCostPer100k: beta[2] * 100, n: samples.count)
    }

    private static func invert3(_ m: [Double]) -> [Double]? {
        let (a, b, c, d, e, f, g, h, k) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let A = e * k - f * h, B = -(d * k - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-12 else { return nil }
        return [A, -(b * k - c * h), b * f - c * e,
                B, a * k - c * g, -(a * f - c * d),
                C, -(a * h - b * g), a * e - b * d].map { $0 / det }
    }

    /// Change between an earlier and a later estimate, called significant
    /// only when it exceeds twice the combined standard error.
    public struct Drift: Equatable, Sendable {
        public var before: Double, after: Double, twoSigma: Double
        public var relative: Double { before == 0 ? 0 : (after - before) / before }
        public var significant: Bool { abs(after - before) > twoSigma }
    }

    public static func drift(_ a: Double, _ sa: Double, _ b: Double, _ sb: Double) -> Drift {
        Drift(before: a, after: b, twoSigma: 2 * (sa * sa + sb * sb).squareRoot())
    }

    /// Two-proportion test on misuse per tool call.
    public static func misuseDrift(_ a: [RequestSample], _ b: [RequestSample]) -> Drift {
        let ta = Double(a.reduce(0) { $0 + $1.toolCalls }), tb = Double(b.reduce(0) { $0 + $1.toolCalls })
        let ma = Double(a.reduce(0) { $0 + $1.toolErrors.misuse }), mb = Double(b.reduce(0) { $0 + $1.toolErrors.misuse })
        let pa = ta > 0 ? ma / ta : 0, pb = tb > 0 ? mb / tb : 0
        let pool = (ta + tb) > 0 ? (ma + mb) / (ta + tb) : 0
        let se = (pool * (1 - pool) * (1 / max(ta, 1) + 1 / max(tb, 1))).squareRoot()
        return Drift(before: pa, after: pb, twoSigma: 2 * se)
    }

    public static func misuseRate(_ s: [RequestSample]) -> Double? {
        let t = s.reduce(0) { $0 + $1.toolCalls }
        return t == 0 ? nil : Double(s.reduce(0) { $0 + $1.toolErrors.misuse }) / Double(t)
    }

    public static func cacheHitRate(_ s: [RequestSample]) -> Double? {
        let p = s.reduce(UInt64(0)) { $0 &+ $1.context }
        return p == 0 ? nil : Double(s.reduce(UInt64(0)) { $0 &+ $1.cacheRead }) / Double(p)
    }

    // MARK: Buckets

    public enum Bucket: String, CaseIterable, Sendable {
        case hour, day, week
        var component: Calendar.Component { self == .hour ? .hour : .day }
        var step: Int { self == .week ? 7 : 1 }
    }

    public static func bucketStart(_ d: Date, _ b: Bucket, calendar: Calendar = .current) -> Date {
        switch b {
        case .hour: return calendar.dateInterval(of: .hour, for: d)?.start ?? d
        case .day: return calendar.startOfDay(for: d)
        case .week:
            let day = calendar.startOfDay(for: d)
            let back = (calendar.component(.weekday, from: day) + 5) % 7  // Monday-based
            return calendar.date(byAdding: .day, value: -back, to: day) ?? day
        }
    }

    /// Every bucket from `from` to `to`, gap-filled, so charts break on
    /// idle buckets instead of drawing a line across them.
    public static func buckets(from: Date, to: Date, _ b: Bucket, calendar: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var cur = bucketStart(from, b, calendar: calendar)
        while cur <= to && out.count < 5000 {
            out.append(cur)
            cur = calendar.date(byAdding: b.component, value: b.step, to: cur) ?? to.addingTimeInterval(1)
        }
        return out
    }

    /// Samples grouped onto `starts` (which must come from `buckets`).
    public static func group(_ s: [RequestSample], starts: [Date], _ b: Bucket,
                             calendar: Calendar = .current) -> [[RequestSample]] {
        var idx: [Date: Int] = [:]
        for (i, d) in starts.enumerated() { idx[d] = i }
        var out = [[RequestSample]](repeating: [], count: starts.count)
        for x in s { if let i = idx[bucketStart(x.time, b, calendar: calendar)] { out[i].append(x) } }
        return out
    }

    /// Peak and mean number of requests in flight per bucket.
    public static func concurrency(_ s: [RequestSample], starts: [Date], _ b: Bucket,
                                   calendar: Calendar = .current) -> [(peak: Int, mean: Double)] {
        guard !starts.isEmpty else { return [] }
        var idx: [Date: Int] = [:]
        for (i, d) in starts.enumerated() { idx[d] = i }
        let ends = starts.indices.map { i in
            i + 1 < starts.count ? starts[i + 1]
                : calendar.date(byAdding: b.component, value: b.step, to: starts[i]) ?? starts[i]
        }
        var busy = [Double](repeating: 0, count: starts.count)
        var peak = [Int](repeating: 0, count: starts.count)
        var events: [(Date, Int)] = []
        for x in s {
            let a = x.start, e = x.time.addingTimeInterval(x.duration - x.firstBlock)
            events.append((a, 1)); events.append((e, -1))
            var i = idx[bucketStart(a, b, calendar: calendar)] ?? 0
            while i < starts.count && starts[i] < e {
                let lo = max(a, starts[i]), hi = min(e, ends[i])
                if hi > lo { busy[i] += hi.timeIntervalSince(lo) }
                i += 1
            }
        }
        events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var cur = 0
        for (t, d) in events {
            cur += d
            if let i = idx[bucketStart(t, b, calendar: calendar)] { peak[i] = max(peak[i], cur) }
        }
        return starts.indices.map { (peak[$0], busy[$0] / ends[$0].timeIntervalSince(starts[$0])) }
    }
}
