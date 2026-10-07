import XCTest
@testable import ClaudeCounterCore

final class PerformanceTests: XCTestCase {

    // A prompt, a two-block reply with a tool call, the tool's (failed)
    // result, an attachment written after the next request went out, and
    // a second reply that the user interrupted.
    private let session = [
        #"{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-10-01T10:00:00.000Z","message":{"role":"user","content":"fix the bug"}}"#,
        #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-10-01T10:00:03.000Z","requestId":"r1","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":""}],"usage":{"input_tokens":2,"output_tokens":400,"cache_read_input_tokens":30000,"cache_creation_input_tokens":1000,"output_tokens_details":{"thinking_tokens":120}}}}"#,
        #"{"type":"assistant","uuid":"a2","parentUuid":"a1","timestamp":"2026-10-01T10:00:07.000Z","requestId":"r1","effort":"high","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{}}],"usage":{"input_tokens":2,"output_tokens":400,"cache_read_input_tokens":30000,"cache_creation_input_tokens":1000}}}"#,
        #"{"type":"user","uuid":"u2","parentUuid":"a2","timestamp":"2026-10-01T10:00:08.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"<tool_use_error>String to replace not found in file.</tool_use_error>"}]}}"#,
        #"{"type":"attachment","uuid":"x1","parentUuid":"u2","timestamp":"2026-10-01T10:00:10.000Z"}"#,
        #"{"type":"assistant","uuid":"a3","parentUuid":"x1","timestamp":"2026-10-01T10:00:10.500Z","requestId":"r2","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":2,"output_tokens":50,"cache_read_input_tokens":31000,"cache_creation_input_tokens":500}}}"#,
        #"{"type":"user","uuid":"u3","parentUuid":"a3","timestamp":"2026-10-01T10:00:12.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
        #"{"type":"assistant","uuid":"e1","parentUuid":"u3","timestamp":"2026-10-01T10:00:13.000Z","requestId":"r3","isApiErrorMessage":true,"message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":0,"output_tokens":0}}}"#,
        "not json",
    ].joined(separator: "\n")

    func test_parse_pairsRequestsWithTheirStart() throws {
        let s = parsePerformance(Data(session.utf8), path: "/p/projects/x/s.jsonl")
        XCTAssertEqual(s.map(\.requestID), ["r1", "r2"])
        let r1 = s[0]
        XCTAssertEqual(r1.firstBlock, 3, accuracy: 1e-6)
        XCTAssertEqual(r1.duration, 7, accuracy: 1e-6)
        XCTAssertEqual(r1.output, 400)
        XCTAssertEqual(r1.context, 31002)
        XCTAssertEqual(r1.thinkingTokens, 120)
        XCTAssertEqual(r1.effort, "high")
        XCTAssertEqual(r1.toolCalls, 1)
        XCTAssertEqual(r1.toolErrors.misuse, 1)
        XCTAssertFalse(r1.isSubagent)
        // r2's direct parent is an attachment written after the request
        // went out; the start is the tool_result before it.
        XCTAssertEqual(s[1].firstBlock, 2.5, accuracy: 1e-6)
        XCTAssertTrue(s[1].interrupted)
    }

    func test_parse_subagentPathIsSubagent() {
        let s = parsePerformance(Data(session.utf8), path: "/p/projects/x/s/subagents/agent-1.jsonl")
        XCTAssertTrue(s.allSatisfy(\.isSubagent))
    }

    func test_parse_flagsCacheRebuildAfterIdle() {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-01T10:00:00Z","message":{"content":"a"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-10-01T10:00:02Z","requestId":"r1","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0}}}"#,
            #"{"type":"user","uuid":"u2","parentUuid":"a1","timestamp":"2026-10-01T12:00:00Z","message":{"content":"b"}}"#,
            #"{"type":"assistant","uuid":"a2","parentUuid":"u2","timestamp":"2026-10-01T12:00:04Z","requestId":"r2","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":100500}}}"#,
        ].joined(separator: "\n") + "\n"
        let s = parsePerformance(Data(lines.utf8), path: "/p/projects/x/s.jsonl")
        XCTAssertEqual(s.map(\.rebuild), [.none, .afterIdle])
    }

    func test_classify() {
        XCTAssertEqual(classifyToolError("<tool_use_error>File has not been read yet."), .misuse)
        XCTAssertEqual(classifyToolError("Exit code 1\n"), .exit)
        XCTAssertEqual(classifyToolError("Permission for this action was denied by the auto mode classifier"), .policy)
        XCTAssertEqual(classifyToolError("ENOENT: no such file or directory, posix_spawn 'rg'"), .environment)
    }

    func test_fit_recoversKnownParameters() throws {
        // duration = 2 s + 10 ms/token + 0.01 s per 1k context, plus
        // one-sided waits on a quarter of the requests.
        var rng = SystemRandomNumberGenerator()
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let samples: [RequestSample] = (0..<2000).map { i in
            let out = UInt64.random(in: 20...4000, using: &rng)
            let ctx = UInt64.random(in: 10_000...300_000, using: &rng)
            var d = 2 + Double(out) * 0.010 + Double(ctx) / 1000 * 0.01 + Double.random(in: -0.2...0.2, using: &rng)
            if i % 4 == 0 { d += Double.random(in: 1...60, using: &rng) }
            return RequestSample(requestID: "r\(i)", time: base, model: "m", isSubagent: false, effort: nil,
                                 firstBlock: 1, duration: d, output: out, context: ctx, cacheRead: 0,
                                 thinkingTokens: nil, toolCalls: 0, toolErrors: .init(), interrupted: false, rebuild: .none)
        }
        let f = try XCTUnwrap(PerformanceStats.fit(samples))
        XCTAssertEqual(f.itlMs, 10, accuracy: 0.5)
        XCTAssertEqual(f.ttft, 2 + 0.5, accuracy: 0.3)        // at the 50k reference context
        XCTAssertEqual(f.contextCostPer100k, 1, accuracy: 0.2)
    }

    func test_quantileAndBuckets() {
        XCTAssertEqual(PerformanceStats.quantile([1, 2, 3, 4], 0.5), 2.5)
        XCTAssertNil(PerformanceStats.quantile([], 0.5))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let wed = ISO8601DateFormatter().date(from: "2026-10-07T15:30:00Z")!
        XCTAssertEqual(PerformanceStats.bucketStart(wed, .week, calendar: cal),
                       ISO8601DateFormatter().date(from: "2026-10-05T00:00:00Z")!)
        let days = PerformanceStats.buckets(from: wed, to: wed.addingTimeInterval(3 * 86400), .day, calendar: cal)
        XCTAssertEqual(days.count, 4)
    }

    func test_report_bucketsLineUpAndThinDataHasNoDrift() {
        let now = ISO8601DateFormatter().date(from: "2026-10-05T12:00:00Z")!
        var samples: [RequestSample] = []
        for i in 0..<300 {
            let t: Date = now.addingTimeInterval(-Double(i) * 3000)
            let effort: String? = i % 2 == 0 ? "high" : nil
            let dur: Double = 2 + Double(i % 50) * 0.1
            samples.append(RequestSample(requestID: "r\(i)", time: t, model: "m", isSubagent: i % 3 == 0,
                                         effort: effort, firstBlock: 2, duration: dur,
                                         output: UInt64(100 + i * 10), context: 50_000, cacheRead: 45_000, thinkingTokens: 70,
                                         toolCalls: 1, toolErrors: ToolErrorCounts(), interrupted: false, rebuild: .none))
        }
        samples.sort { $0.time < $1.time }
        let r = PerformanceReport.build(samples, filters: .init(rangeDays: 30), now: now)
        XCTAssertEqual(r.model, "m")
        XCTAssertEqual(r.requests, 300)
        XCTAssertEqual(r.filters.resolvedBucket, .day)
        for series in [r.cacheHitRate, r.misuseRate, r.outputP50, r.contextP50, r.meanInFlight] {
            XCTAssertEqual(series.count, r.buckets.count)
        }
        XCTAssertEqual(r.counts.reduce(0, +), 300)
        // UInt64 → Double must convert the value, not reinterpret its bits.
        XCTAssertEqual(r.thinkingP50.compactMap { $0 }.first, 70)
        XCTAssertNil(r.ttftDrift)      // 100 per third, under the 500 floor
        XCTAssertNil(r.misuseDrift)
        let main = PerformanceReport.build(samples, filters: .init(rangeDays: 30, agent: .main), now: now)
        XCTAssertEqual(main.requests, 200)
    }

    func test_incrementalFeed_matchesWholeFileParse() {
        let data = Data((session + "\n").utf8)
        let whole = parsePerformance(data, path: "/p/projects/x/s.jsonl")
        // Every split point, including mid-line: the parser must hold an
        // incomplete tail back until its newline arrives.
        for cut in stride(from: 1, to: data.count, by: 37) {
            let p = PerformanceFileParser(path: "/p/projects/x/s.jsonl")
            p.feed(data.prefix(cut))
            p.feed(data.suffix(from: Int(p.offset)))
            XCTAssertEqual(p.samples, whole, "cut at \(cut)")
            XCTAssertEqual(p.offset, Int64(data.count))
        }
    }

    func test_scanner_picksUpAppendedRequestLive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString)/projects/x")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent()) }
        let file = root.appendingPathComponent("s.jsonl")
        let lines = session.split(separator: "\n").map(String.init)
        // First request only, then the rest arrives "live".
        try (lines[0..<3].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        let scanner = PerformanceScanner()
        await scanner.fileChanged(FileChange(path: file.path, kind: .modify))
        var snap = await scanner.snapshot()
        XCTAssertTrue(snap.isEmpty, "inert until the first backfill")

        await scanner.backfill(roots: [root.deletingLastPathComponent().path], notBefore: .distantPast)
        snap = await scanner.snapshot()
        XCTAssertEqual(snap.map(\.requestID), ["r1"])
        XCTAssertEqual(snap[0].toolCalls, 0)

        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data((lines[3...].joined(separator: "\n") + "\n").utf8))
        try h.close()
        await scanner.fileChanged(FileChange(path: file.path, kind: .modify))
        snap = await scanner.snapshot()
        XCTAssertEqual(snap.map(\.requestID), ["r1", "r2"])
        // r1's tool result came in after it was first sampled.
        XCTAssertEqual(snap[0].toolErrors.misuse, 1)

        await scanner.fileChanged(FileChange(path: file.path, kind: .remove))
        snap = await scanner.snapshot()
        XCTAssertTrue(snap.isEmpty)
    }

    func test_walkOrder_putsSubagentDirBeforeMainFile() {
        XCTAssertTrue(walkOrder("/p/x/abc/subagents/agent-1.jsonl", "/p/x/abc.jsonl"))
        XCTAssertFalse(walkOrder("/p/x/abc.jsonl", "/p/x/abc/subagents/agent-1.jsonl"))
    }

    /// Read-only check against the real logs, compared by hand with the
    /// Python extract. Opt in: PERF_PARITY=1 swift test --filter Performance
    func test_parity_realLogs() async throws {
        guard ProcessInfo.processInfo.environment["PERF_PARITY"] == "1" else { throw XCTSkip("set PERF_PARITY=1") }
        let root = NSHomeDirectory() + "/.claude/projects"
        let t0 = Date()
        let scanner = PerformanceScanner()
        await scanner.backfill(roots: [root], notBefore: Date().addingTimeInterval(-90 * 86400))
        let s = await scanner.snapshot()
        print("PARITY requests=\(s.count) seconds=\(String(format: "%.1f", Date().timeIntervalSince(t0)))")
        let byModel = Dictionary(grouping: s, by: \.model)
        for (m, xs) in byModel.sorted(by: { $0.value.count > $1.value.count }) {
            let f = PerformanceStats.fit(xs.filter { $0.time > Date().addingTimeInterval(-7 * 86400) })
            print("PARITY", m, xs.count,
                  "e2e_p50", PerformanceStats.quantile(xs.map(\.duration), 0.5) ?? -1,
                  "ttfb_p50", PerformanceStats.quantile(xs.map(\.firstBlock), 0.5) ?? -1,
                  "misuse", xs.reduce(0) { $0 + $1.toolErrors.misuse },
                  "tools", xs.reduce(0) { $0 + $1.toolCalls },
                  "think_n", xs.compactMap(\.thinkingTokens).count,
                  "think_p50", PerformanceStats.quantile(xs.compactMap(\.thinkingTokens).map { Double($0) }, 0.5) ?? -1,
                  "fit7d", f.map { "\($0.ttft) \($0.tokensPerSecond)" } ?? "-")
        }
    }
}
