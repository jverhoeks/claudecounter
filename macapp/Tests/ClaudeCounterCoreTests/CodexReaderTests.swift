import XCTest
@testable import ClaudeCounterCore

/// Swift mirror of `tui/internal/reader/codex_test.go`. Same fixture
/// (byte-identical copy in Fixtures/, verified via `shasum -a 256` against
/// `tui/internal/reader/testdata/codex_rollout.jsonl`), same numeric
/// expectations — the two parsers must agree line for line.
///
/// Also covers two failure modes the Go suite can't exercise, because Go's
/// `codexParser` ownership lives in `Reader.parserForChange` rather than in
/// the parser type itself: resuming a growing file across separate
/// `onChange` calls, and never leaking one file's running totals into
/// another's.
final class CodexReaderTests: XCTestCase {

    private func fixtureURL(named: String) throws -> URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: named, withExtension: nil, subdirectory: "Fixtures")
            ?? bundle.url(forResource: named, withExtension: nil) else {
            throw NSError(domain: "CodexReaderTests", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "fixture \(named) not found"])
        }
        return url
    }

    /// Runs testdata/codex_rollout.jsonl through a single `CodexParser`
    /// instance, line by line, exactly the way `onChange` would for one
    /// file — `CodexParser` is stateful, so reusing one instance across
    /// all lines is the point of the test, not an implementation detail
    /// to route around. Mirrors Go's `parseCodexFixture`.
    private func parseCodexFixture() throws -> (events: [UsageEvent], parseErrors: Int) {
        let url = try fixtureURL(named: "codex_rollout.jsonl")
        let body = try String(contentsOf: url, encoding: .utf8)
        let p = CodexParser()
        var events: [UsageEvent] = []
        var parseErrors = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            switch p.parse(Data(line.utf8), path: "irrelevant") {
            case .events(let evs): events.append(contentsOf: evs)
            case .parseError: parseErrors += 1
            }
        }
        return (events, parseErrors)
    }

    // MARK: - TestCodexParser_DeltasTelescope
    //
    // Line 2 (first reading, no baseline yet): delta is its own value.
    //   In  = 1000 - 400 = 600
    //   Out = 100 - 0    = 100
    // Line 4 (second reading, deltas against line 2's totals):
    //   deltaInput  = 3000 - 1000 = 2000
    //   deltaCached = 1400 - 400  = 1000
    //   In  = 2000 - 1000 = 1000   (equivalently (3000-1400) - (1000-400) = 1600-600 = 1000)
    //   Out = 300 - 100 = 200
    func test_codexParser_deltasTelescope() throws {
        let (events, parseErrors) = try parseCodexFixture()
        XCTAssertEqual(parseErrors, 1, "the malformed line must be the only parse error")
        XCTAssertEqual(events.count, 3, "line 2, line 4, line 7 — lines 5, 6 contribute none")

        let first = events[0], second = events[1]
        XCTAssertEqual(first.usage.input, 600, "line 2 In")
        XCTAssertEqual(first.usage.output, 100, "line 2 Out")
        XCTAssertEqual(first.usage.cacheRead, 400, "line 2 CacheRead")

        XCTAssertEqual(second.usage.input, 1000, "line 4 In")
        XCTAssertEqual(second.usage.output, 200, "line 4 Out")
        XCTAssertEqual(second.usage.cacheRead, 1000, "line 4 CacheRead")
    }

    /// Line 5 repeats line 4's totals exactly: a duplicate telescopes to
    /// a zero delta with no need for a dedupe key.
    func test_codexParser_duplicateReadingYieldsNoEvent() throws {
        let (events, _) = try parseCodexFixture()
        XCTAssertEqual(events.count, 3, "line 5's duplicate must not appear")
    }

    /// Covers both halves of the restart rule: line 6 (a decrease from
    /// 3300 to 11 total_tokens) contributes no event, and the recovery
    /// reading on line 7 deltas against the DECREASED baseline (11), not
    /// the pre-decrease one (3300).
    ///
    /// Hand-computed: line 7's totals are {input:110, cached:55, output:11}.
    /// Against the adopted baseline from line 6 {input:10, cached:5, output:1}:
    ///   deltaInput  = 110 - 10 = 100
    ///   deltaCached = 55 - 5   = 50
    ///   In  = (110-55) - (10-5) = 55 - 5 = 50   (equivalently 100 - 50 = 50)
    ///   Out = 11 - 1 = 10
    func test_codexParser_decreaseYieldsNoNegativeDelta() throws {
        let (events, _) = try parseCodexFixture()
        XCTAssertEqual(events.count, 3, "line 6's decrease must not appear")
        let third = events[2]
        XCTAssertEqual(third.usage.input, 50, "delta against the decreased baseline of 11, not 3300")
        XCTAssertEqual(third.usage.output, 10)
        XCTAssertEqual(third.usage.cacheRead, 50)
    }

    /// Line 2's event (before thread_settings_applied on line 3) resolves
    /// through the fallback, and line 4's event (after) carries the
    /// declared model — both happen to be gpt-5.6-sol here, but for
    /// different reasons.
    func test_codexParser_modelFallsBackBeforeFirstDeclaration() throws {
        let (events, _) = try parseCodexFixture()
        XCTAssertEqual(events[0].model, "gpt-5.6-sol", "fallback: no parent_thread_id")
        XCTAssertEqual(events[1].model, "gpt-5.6-sol", "declared by thread_settings_applied")
    }

    /// Uses a fixture that never declares thread_settings_applied at all
    /// and whose session_meta carries a parent_thread_id, and asserts
    /// both the model fallback and isSubagent key off that field.
    func test_codexParser_parentThreadIdImpliesAutoReview() {
        let lines = [
            #"{"timestamp":"2026-08-09T09:00:00.000Z","type":"session_meta","payload":{"session_id":"s2","cwd":"/Users/me/src/proj","parent_thread_id":"parent-1"}}"#,
            #"{"timestamp":"2026-08-09T09:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550}}}}"#,
        ]
        let p = CodexParser()
        var events: [UsageEvent] = []
        for line in lines {
            switch p.parse(Data(line.utf8), path: "irrelevant") {
            case .events(let evs): events.append(contentsOf: evs)
            case .parseError: XCTFail("Parse error")
            }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "codex-auto-review")
        XCTAssertTrue(events[0].isSubagent, "IsSubagent must be true when parent_thread_id is present")
        XCTAssertTrue(p.isSubagent("", root: ""), "CodexParser.isSubagent() must read the retained state")
    }

    /// Exercises the case where the declared model and the
    /// parent_thread_id-keyed fallback DISAGREE: this session has
    /// parent_thread_id set (so the fallback alone would say
    /// codex-auto-review) but also declares a third model, distinct from
    /// both fallback values, via thread_settings_applied — so only a
    /// declared-wins implementation can produce the expected result.
    func test_codexParser_declaredModelWinsOverFallback() {
        let lines = [
            #"{"timestamp":"2026-08-09T09:10:00.000Z","type":"session_meta","payload":{"session_id":"s3","cwd":"/Users/me/src/proj","parent_thread_id":"parent-2"}}"#,
            #"{"timestamp":"2026-08-09T09:10:05.000Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6-nightly","model_provider_id":"openai"}}}"#,
            #"{"timestamp":"2026-08-09T09:10:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550}}}}"#,
        ]
        let p = CodexParser()
        var events: [UsageEvent] = []
        for line in lines {
            switch p.parse(Data(line.utf8), path: "irrelevant") {
            case .events(let evs): events.append(contentsOf: evs)
            case .parseError: XCTFail("Parse error")
            }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].model, "gpt-6-nightly",
                       "declared model must win over the parent_thread_id fallback of codex-auto-review")
    }

    /// Asserts the project key comes from session_meta's cwd, encoded the
    /// way Claude encodes project directories — every '/' and '.' becomes
    /// '-' — and NOT from the transcript path, which for Codex carries no
    /// project information at all (its layout is YYYY/MM/DD/rollout-*.jsonl).
    func test_codexParser_projectFromSessionMetaCwd() {
        let p = CodexParser()
        let line = #"{"timestamp":"2026-08-09T08:34:15.910Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/proj","originator":"codex-tui"}}"#
        switch p.parse(Data(line.utf8), path: "/Users/me/.codex/sessions/2026/08/09/rollout-abc.jsonl") {
        case .parseError: XCTFail("Parse error")
        default: break
        }
        // A deliberately unrelated path+root: proves project() reads
        // retained state, not its arguments.
        XCTAssertEqual(p.project("/some/other/path.jsonl", root: "/some/other/root"), "-Users-me-src-proj")
    }

    func test_codexParser_malformedLineIsAParseError() throws {
        let (_, parseErrors) = try parseCodexFixture()
        XCTAssertEqual(parseErrors, 1, "the fixture's single malformed line is the only parse error")
    }

    func test_codexParser_walkableMatchesRolloutPrefix() {
        let p = CodexParser()
        XCTAssertTrue(p.walkable("rollout-2026-08-09T08-34-15-910Z-abc.jsonl"),
                      "a rollout-*.jsonl file must be walkable")
        for name in ["history.jsonl", "rollout-foo.json", "notes.txt"] {
            XCTAssertFalse(p.walkable(name), "\(name) must not be walkable")
        }
    }

    func test_parserFor_codexReturnsCodexParser() {
        XCTAssertTrue(parserFor(vendor: "codex") is CodexParser)
    }

    // MARK: - Task 5's required stateful-ownership tests
    //
    // These have no Go equivalent: Go's `codexParser` ownership lives in
    // `Reader.parserForChange` (a map owned by the actor/struct), not in
    // the parser type, so these exercise `Reader.onChange` end-to-end
    // rather than `CodexParser` in isolation.

    /// `onChange` resumes a growing file mid-file from a byte offset, so
    /// the SAME `CodexParser` instance must be reused across calls for one
    /// path — a fresh instance per call would compute the next delta
    /// against an implicit zero baseline instead of the retained running
    /// total (a silent over-count that grows with watcher activity), and
    /// would lose project/subagent attribution, since session_meta is
    /// only ever seen once, on line 1.
    func test_codexParserState_resumesAcrossOnChangeCalls() async throws {
        let path = NSTemporaryDirectory() + "codex-resume-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let line1 = #"{"timestamp":"2026-08-09T08:34:15.910Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/proj","parent_thread_id":"parent-1"}}"#
        let line2 = #"{"timestamp":"2026-08-09T08:34:16.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"total_tokens":1100}}}}"#
        try (line1 + "\n" + line2 + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let source = SourceEntry(vendor: "codex", label: "codex", root: NSTemporaryDirectory())
        let reader = Reader()
        let first = try await reader.onChange(path: path, source: source)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].usage.input, 600, "line 2's own value: 1000-400")
        XCTAssertEqual(first[0].usage.output, 100)
        XCTAssertEqual(first[0].usage.cacheRead, 400)
        XCTAssertEqual(first[0].project, "-Users-me-src-proj")
        XCTAssertTrue(first[0].isSubagent)

        // Append another token_count line and resume from the byte
        // offset — session_meta is NOT repeated, matching real rollout
        // files, where it appears only once.
        let line3 = #"{"timestamp":"2026-08-09T08:36:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":1400,"output_tokens":300,"total_tokens":3300}}}}"#
        try appendLine(path: path, line: line3)

        let second = try await reader.onChange(path: path, source: source)
        XCTAssertEqual(second.count, 1)
        // A fresh-parser-per-call implementation would compute this delta
        // against an implicit zero baseline (3000, 1400, 300) instead of
        // against line 2's RETAINED totals (delta 1000/1000/200) — this
        // is the assertion that catches it.
        XCTAssertEqual(second[0].usage.input, 1000, "delta against the retained running total, not a fresh baseline")
        XCTAssertEqual(second[0].usage.output, 200)
        XCTAssertEqual(second[0].usage.cacheRead, 1000)
        // session_meta was only ever seen in the FIRST onChange call —
        // project/subagent must still be correct on this second call.
        XCTAssertEqual(second[0].project, "-Users-me-src-proj",
                       "project must survive from session_meta seen only in an earlier onChange call")
        XCTAssertTrue(second[0].isSubagent,
                      "subagent flag must survive from session_meta seen only in an earlier onChange call")
    }

    /// Two rollout files under one root, the second with LOWER cumulative
    /// totals than the first. If `CodexParser` instances were shared (or
    /// keyed wrong) across paths, the second file's first reading would be
    /// computed as a delta against the first file's running total instead
    /// of its own zero baseline.
    func test_codexParserState_resetsBetweenFiles() async throws {
        let root = NSTemporaryDirectory() + "codex-reset-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let pathA = root + "/rollout-a.jsonl"
        let pathB = root + "/rollout-b.jsonl"

        let sessionA = #"{"timestamp":"2026-08-09T08:34:15.910Z","type":"session_meta","payload":{"session_id":"sA","cwd":"/Users/me/src/proj-a"}}"#
        let tokenA = #"{"timestamp":"2026-08-09T08:34:16.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000,"cached_input_tokens":4000,"output_tokens":900,"total_tokens":9900}}}}"#
        try (sessionA + "\n" + tokenA + "\n").write(toFile: pathA, atomically: true, encoding: .utf8)

        let sessionB = #"{"timestamp":"2026-08-09T09:00:00.000Z","type":"session_meta","payload":{"session_id":"sB","cwd":"/Users/me/src/proj-b"}}"#
        let tokenB = #"{"timestamp":"2026-08-09T09:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"total_tokens":110}}}}"#
        try (sessionB + "\n" + tokenB + "\n").write(toFile: pathB, atomically: true, encoding: .utf8)

        let source = SourceEntry(vendor: "codex", label: "codex", root: root)
        let reader = Reader()

        let evsA = try await reader.onChange(path: pathA, source: source)
        XCTAssertEqual(evsA.count, 1)
        XCTAssertEqual(evsA[0].usage.input, 5000, "9000-4000")

        let evsB = try await reader.onChange(path: pathB, source: source)
        XCTAssertEqual(evsB.count, 1)
        // A leaked/shared parser would compute saturatingSub(100-40,
        // 9000-4000) = 0 (clamped) instead of the correct first-reading
        // value of 100-40 = 60.
        XCTAssertEqual(evsB[0].usage.input, 60, "must not delta against file A's running total")
        XCTAssertEqual(evsB[0].usage.output, 10)
        XCTAssertEqual(evsB[0].usage.cacheRead, 40)
    }

    /// A previously-seen codex path read from byte offset 0 again (the
    /// file shrank or was replaced) must not let its running totals or
    /// declared model survive into the re-read — mirrors
    /// `test_onChange_truncatedFile_restartsFromZero` but for a vendor
    /// whose parser is stateful.
    func test_codexParserState_resetsOnTruncation() async throws {
        let path = NSTemporaryDirectory() + "codex-trunc-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let session = #"{"timestamp":"2026-08-09T08:34:15.910Z","type":"session_meta","payload":{"session_id":"s1","cwd":"/Users/me/src/proj"}}"#
        let bigToken = #"{"timestamp":"2026-08-09T08:34:16.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000,"cached_input_tokens":4000,"output_tokens":900,"total_tokens":9900}}}}"#
        try (session + "\n" + bigToken + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let source = SourceEntry(vendor: "codex", label: "codex", root: NSTemporaryDirectory())
        let reader = Reader()
        _ = try await reader.onChange(path: path, source: source)

        // Truncate and rewrite with a fresh session whose first reading is
        // small — if the running total survived, this would saturate to 0
        // instead of its own value.
        try Data().write(to: URL(fileURLWithPath: path))
        let newSession = #"{"timestamp":"2026-08-09T09:00:00.000Z","type":"session_meta","payload":{"session_id":"s2","cwd":"/Users/me/src/other"}}"#
        let smallToken = #"{"timestamp":"2026-08-09T09:00:10.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"total_tokens":110}}}}"#
        try (newSession + "\n" + smallToken + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let after = try await reader.onChange(path: path, source: source)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].usage.input, 60, "must be its own first reading, not a delta against the pre-truncation total")
        XCTAssertEqual(after[0].project, "-Users-me-src-other")
    }

    private func appendLine(path: String, line: String) throws {
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } else {
            try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
