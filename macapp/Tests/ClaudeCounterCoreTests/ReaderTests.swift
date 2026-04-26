import XCTest
@testable import ClaudeCounterCore

final class ReaderTests: XCTestCase {

    // MARK: - parseLine

    func test_parseLine_assistantWithUsage_returnsEvent() throws {
        let line = #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-7","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T14:00:01Z","sessionId":"s1","cwd":"/tmp/x","requestId":"r1"}"#
        let result = parseLine(Data(line.utf8))
        guard case .event(let ev) = result else {
            return XCTFail("expected .event, got \(result)")
        }
        XCTAssertEqual(ev.model, "claude-opus-4-7")
        XCTAssertEqual(ev.messageID, "m1")
        XCTAssertEqual(ev.requestID, "r1")
        XCTAssertEqual(ev.sessionID, "s1")
        XCTAssertEqual(ev.cwd, "/tmp/x")
        XCTAssertEqual(ev.usage, Usage(input: 10, output: 20, cacheCreate: 0, cacheRead: 0))
    }

    func test_parseLine_noMessage_isSkipped() {
        let line = #"{"type":"permission-mode","permissionMode":"default","sessionId":"s1"}"#
        XCTAssertEqual(parseLine(Data(line.utf8)), .skip)
    }

    func test_parseLine_messageWithoutUsage_isSkipped() {
        let line = #"{"type":"user","message":{"role":"user","content":"hi"},"sessionId":"s1","cwd":"/tmp/x","timestamp":"2026-04-24T14:00:00Z"}"#
        XCTAssertEqual(parseLine(Data(line.utf8)), .skip)
    }

    func test_parseLine_syntheticModel_isSkipped() {
        let line = #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T14:00:01Z"}"#
        XCTAssertEqual(parseLine(Data(line.utf8)), .skip)
    }

    func test_parseLine_malformedJSON_isParseError() {
        let line = "{this is not json"
        XCTAssertEqual(parseLine(Data(line.utf8)), .parseError)
    }

    func test_parseLine_anyTypeWithUsage_isIncluded() throws {
        // Permissive rule: any line with message.usage is included regardless of `type`.
        let line = #"{"type":"weird","message":{"id":"m1","model":"claude-haiku-4-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T14:00:01Z"}"#
        let result = parseLine(Data(line.utf8))
        guard case .event = result else {
            return XCTFail("expected .event, got \(result)")
        }
    }

    // MARK: - projectFromPath

    func test_projectFromPath_basicSession() {
        let p = projectFromPath("/Users/me/.claude/projects/encoded-name/session-uuid.jsonl")
        XCTAssertEqual(p, "encoded-name")
    }

    func test_projectFromPath_subagent() {
        let p = projectFromPath("/Users/me/.claude/projects/encoded-name/sess-uuid/subagents/agent-1.jsonl")
        XCTAssertEqual(p, "encoded-name")
    }

    func test_projectFromPath_noProjectsSegment_isEmpty() {
        XCTAssertEqual(projectFromPath("/tmp/random/file.jsonl"), "")
    }

    // MARK: - isSubagentPath

    func test_isSubagentPath_subagentsSegment_isTrue() {
        XCTAssertTrue(isSubagentPath("/projects/p/sess/subagents/agent-1.jsonl"))
    }

    func test_isSubagentPath_topLevelSession_isFalse() {
        XCTAssertFalse(isSubagentPath("/projects/p/session-uuid.jsonl"))
    }

    func test_isSubagentPath_windowsBackslashes_isNormalized() {
        // Path normalization happens before the substring check.
        XCTAssertTrue(isSubagentPath(#"C:\Users\me\.claude\projects\p\sess\subagents\agent-1.jsonl"#))
    }

    // MARK: - Reader.onChange (offsets, truncation, partial tail)

    func test_onChange_readsAllCompleteLines_advancesOffset() async throws {
        let path = try tempJSONL(lines: [
            sample(model: "claude-opus-4-7", input: 1, msgID: "m1", reqID: "r1"),
            sample(model: "claude-sonnet-4-6", input: 2, msgID: "m2", reqID: "r2"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = Reader()
        let events = try await reader.onChange(path: path)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].model, "claude-opus-4-7")
        XCTAssertEqual(events[1].model, "claude-sonnet-4-6")

        // Calling again with no new content yields no events.
        let again = try await reader.onChange(path: path)
        XCTAssertEqual(again.count, 0)
    }

    func test_onChange_resumesFromOffset() async throws {
        let path = try tempJSONL(lines: [
            sample(model: "claude-opus-4-7", input: 1, msgID: "m1", reqID: "r1"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = Reader()
        let first = try await reader.onChange(path: path)
        XCTAssertEqual(first.count, 1)

        // Append a new line and re-trigger.
        try appendLine(path: path, line: sample(model: "claude-haiku-4-5", input: 5, msgID: "m2", reqID: "r2"))
        let second = try await reader.onChange(path: path)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].model, "claude-haiku-4-5")
    }

    func test_onChange_truncatedFile_restartsFromZero() async throws {
        let path = try tempJSONL(lines: [
            sample(model: "claude-opus-4-7", input: 1, msgID: "m1", reqID: "r1"),
            sample(model: "claude-sonnet-4-6", input: 2, msgID: "m2", reqID: "r2"),
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = Reader()
        _ = try await reader.onChange(path: path)

        // Truncate and rewrite with a different single line.
        try Data().write(to: URL(fileURLWithPath: path))
        try appendLine(path: path, line: sample(model: "claude-haiku-4-5", input: 5, msgID: "m3", reqID: "r3"))

        let after = try await reader.onChange(path: path)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].model, "claude-haiku-4-5")
    }

    func test_onChange_partialTrailingLine_isNotConsumed() async throws {
        // Write a complete line + a partial (no trailing \n) line.
        let path = try tempJSONL(lines: [
            sample(model: "claude-opus-4-7", input: 1, msgID: "m1", reqID: "r1")
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Append partial content without a newline.
        let partial = sample(model: "claude-sonnet-4-6", input: 2, msgID: "m2", reqID: "r2")
            .dropLast() // remove final char to make it incomplete
        try (String(partial)).appendToFile(atPath: path)

        let reader = Reader()
        let first = try await reader.onChange(path: path)
        XCTAssertEqual(first.count, 1, "only the complete line should be emitted")

        // Now complete the partial line by appending the missing closing brace + newline.
        try "}\n".appendToFile(atPath: path)
        let second = try await reader.onChange(path: path)
        XCTAssertEqual(second.count, 1, "the previously-partial line should now be emitted")
    }

    func test_onChange_emptyAndWhitespaceLines_areSkipped() async throws {
        let path = NSTemporaryDirectory() + "rt-empty-\(UUID().uuidString).jsonl"
        let body = sample(model: "claude-opus-4-7", input: 1, msgID: "m1", reqID: "r1") + "\n\n   \n" +
                   sample(model: "claude-haiku-4-5", input: 2, msgID: "m2", reqID: "r2") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = Reader()
        let events = try await reader.onChange(path: path)
        XCTAssertEqual(events.count, 2)
    }

    func test_onChange_malformedLine_incrementsParseErrors() async throws {
        let path = NSTemporaryDirectory() + "rt-mal-\(UUID().uuidString).jsonl"
        let body = sample(model: "claude-opus-4-7", input: 1, msgID: "m1", reqID: "r1") + "\n" +
                   "{not json\n" +
                   sample(model: "claude-haiku-4-5", input: 2, msgID: "m2", reqID: "r2") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = Reader()
        let events = try await reader.onChange(path: path)
        XCTAssertEqual(events.count, 2)
        let errs = await reader.parseErrors
        XCTAssertEqual(errs, 1)
    }

    func test_onChange_attributesProjectAndSubagent() async throws {
        // Construct a path that includes /projects/<encoded>/sess/subagents/agent-1.jsonl
        let dir = NSTemporaryDirectory() + "rt-attr-\(UUID().uuidString)/projects/encoded-x/sess/subagents"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/agent-1.jsonl"
        let body = sample(model: "claude-opus-4-7", input: 1, msgID: "m1", reqID: "r1") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)

        let reader = Reader()
        let events = try await reader.onChange(path: path)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].project, "encoded-x")
        XCTAssertTrue(events[0].isSubagent)
    }

    // MARK: - Cross-language conformance against Go testdata

    func test_conformance_sessionNormal_yieldsTwoUsageEvents() async throws {
        let url = try fixtureURL(named: "session_normal.jsonl")
        // Copy into a known path under .../projects/<x>/sess.jsonl so attribution works.
        let staged = try stageFixtureUnderProjects(url: url, projectName: "p1", filename: "sess.jsonl")
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let reader = Reader()
        let events = try await reader.onChange(path: staged.path)
        // session_normal has 4 lines: permission-mode (skip), user (skip — no usage),
        // assistant opus, assistant sonnet → 2 events.
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map { $0.model }, ["claude-opus-4-7", "claude-sonnet-4-6"])
        XCTAssertEqual(events.map { $0.usage.input }, [10, 5])
        XCTAssertEqual(events.map { $0.usage.output }, [20, 7])
    }

    func test_conformance_sessionMalformed_yieldsTwoEventsAndOneParseError() async throws {
        let url = try fixtureURL(named: "session_malformed.jsonl")
        let staged = try stageFixtureUnderProjects(url: url, projectName: "p2", filename: "sess.jsonl")
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }

        let reader = Reader()
        let events = try await reader.onChange(path: staged.path)
        XCTAssertEqual(events.count, 2)
        let errs = await reader.parseErrors
        XCTAssertEqual(errs, 1)
    }

    // MARK: - Helpers

    private func tempJSONL(lines: [String]) throws -> String {
        let path = NSTemporaryDirectory() + "rt-\(UUID().uuidString).jsonl"
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func appendLine(path: String, line: String) throws {
        try (line + "\n").appendToFile(atPath: path)
    }

    private func sample(model: String, input: UInt64, msgID: String, reqID: String) -> String {
        return #"""
        {"type":"assistant","message":{"id":"\#(msgID)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}},"timestamp":"2026-04-24T14:00:01Z","sessionId":"s1","cwd":"/tmp/x","requestId":"\#(reqID)"}
        """#
    }

    private func fixtureURL(named: String) throws -> URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: named, withExtension: nil, subdirectory: "Fixtures")
            ?? bundle.url(forResource: named, withExtension: nil) else {
            throw NSError(domain: "ReaderTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture \(named) not found"])
        }
        return url
    }

    private func stageFixtureUnderProjects(url: URL, projectName: String, filename: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rt-stage-\(UUID().uuidString)", isDirectory: true)
        let projectsDir = root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        let dest = projectsDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

private extension String {
    func appendToFile(atPath path: String) throws {
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(self.utf8))
        } else {
            try self.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
