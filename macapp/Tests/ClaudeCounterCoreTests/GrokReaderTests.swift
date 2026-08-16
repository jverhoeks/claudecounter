import XCTest
@testable import ClaudeCounterCore

/// Swift mirror of `tui/internal/reader/grok_test.go` and the root-relative
/// cases in `tui/internal/reader/vendor_test.go`. Same fixture (byte-identical
/// copy in Fixtures/), same numeric expectations — the two parsers must agree
/// line for line.
final class GrokReaderTests: XCTestCase {

    private let grokRoot = "/Users/me/.grok/sessions"
    private var grokPath: String { grokRoot + "/%2FUsers%2Fme%2Fsrc%2Fproj/01a0-sess/updates.jsonl" }

    // MARK: - Fixture loading (same helper pattern as ReaderTests.fixtureURL)

    private func fixtureURL(named: String) throws -> URL {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: named, withExtension: nil, subdirectory: "Fixtures")
            ?? bundle.url(forResource: named, withExtension: nil) else {
            throw NSError(domain: "GrokReaderTests", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "fixture \(named) not found"])
        }
        return url
    }

    /// Parses every line of the fixture with `GrokParser`, mirroring Go's
    /// `parseGrokFixture`: valid JSON that yields nothing is normal, invalid
    /// JSON is counted as a parse error.
    private func parseGrokFixture() throws -> (events: [UsageEvent], parseErrors: Int) {
        let url = try fixtureURL(named: "grok_updates.jsonl")
        let body = try String(contentsOf: url, encoding: .utf8)
        let p = GrokParser()
        var events: [UsageEvent] = []
        var parseErrors = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            switch p.parse(Data(line.utf8), path: grokPath) {
            case .events(let evs): events.append(contentsOf: evs)
            case .parseError: parseErrors += 1
            }
        }
        return (events, parseErrors)
    }

    // MARK: - Parse: coverage + usage event counts

    func test_grokParser_emitsOneEventPerModelPlusOneCoverageEvent() throws {
        let (events, parseErrors) = try parseGrokFixture()
        XCTAssertEqual(parseErrors, 1, "the malformed line must be the only parse error")

        let coverage = events.filter { $0.coverageOnly }
        let usage = events.filter { !$0.coverageOnly }

        // 5 turn_completed records (p1, p2, p3, p1-dup, p4) each yield
        // exactly one coverage event; the non-turn_completed and malformed
        // lines yield none.
        XCTAssertEqual(coverage.count, 5)

        var withUsage = 0
        for e in coverage {
            if e.hasUsage { withUsage += 1 }
            // Every coverage event must be dedupe-addressable, or a
            // re-scan silently inflates the tally.
            XCTAssertFalse(e.messageID.isEmpty)
            XCTAssertEqual(e.requestID, "coverage")
        }
        // p1, p3 and p1-dup carry a usable cost. p2 has no usage at all
        // and p4's costUsdTicks is 0 — neither counts as covered.
        XCTAssertEqual(withUsage, 3)

        // p1 -> 1 model, p3 -> 2 models, p1-dup -> 1 model, p4 -> 1 model.
        // Dedupe is the aggregator's job (messageID:requestID), not the
        // parser's.
        XCTAssertEqual(usage.count, 5)
    }

    // A record whose cost is zero but whose tokens are real is kept, not
    // dropped: a missing cost is a coverage problem, not a free turn.
    func test_grokParser_zeroCostRecordIsKeptWithItsTokens() throws {
        let (events, _) = try parseGrokFixture()
        guard let e = events.first(where: { !$0.coverageOnly && $0.messageID == "p4" }) else {
            return XCTFail("the zero-cost record produced no usage event")
        }
        XCTAssertEqual(e.costUSD, 0)
        XCTAssertTrue(e.costed, "a zero-cost Grok cell is still costed, not priced")
        XCTAssertEqual(e.usage.output, 50, "the tokens must survive")
    }

    // MARK: - Token and cost mapping

    func test_grokParser_tokenAndCostMapping() throws {
        let (events, _) = try parseGrokFixture()
        guard let first = events.first(where: { !$0.coverageOnly && $0.messageID == "p1" }) else {
            return XCTFail("no usage event for p1")
        }
        XCTAssertEqual(first.model, "grok-4.6-build")
        // inputTokens INCLUDES cachedReadTokens (totalTokens == input+output
        // on the live records), so the uncached input is the difference.
        XCTAssertEqual(first.usage.input, 210887 - 158592)
        XCTAssertEqual(first.usage.cacheRead, 158592)
        // reasoningTokens is a subset of outputTokens and must NOT be added.
        XCTAssertEqual(first.usage.output, 5833)
        XCTAssertEqual(first.usage.cacheCreate, 0, "Grok reports none")
        XCTAssertTrue(first.costed)
        // costUsdTicks are nano-dollars.
        XCTAssertEqual(first.costUSD, 0.3721028, accuracy: 1e-9)
        // The dedupe key is prompt_id + model, so a multi-model turn keeps
        // both of its cells.
        XCTAssertEqual(first.requestID, "grok-4.6-build")
    }

    func test_grokParser_topLevelTotalsNeverAddedOnTopOfModelUsage() throws {
        let (events, _) = try parseGrokFixture()
        let total = events
            .filter { !$0.coverageOnly && $0.messageID == "p3" }
            .reduce(0.0) { $0 + $1.costUSD }
        // p3's top-level costUsdTicks is 3e9 ($3.00) and its two models
        // sum to exactly that. Emitting both would report $6.00.
        XCTAssertEqual(total, 3.0, accuracy: 1e-9)
    }

    // MARK: - Project key

    func test_grokProjectKey_matchesClaudeEncoding() {
        // The session directory is the percent-encoded cwd. Decoding it
        // and re-encoding the Claude way keeps one project one row in the
        // per-project table regardless of which vendor produced the spend.
        XCTAssertEqual(grokProjectKey(root: grokRoot, path: grokPath), "-Users-me-src-proj")

        // A dot in the path becomes a dash, exactly as Claude encodes it
        // (~/.claude -> -Users-me--claude).
        let dotted = grokRoot + "/%2FUsers%2Fme%2F.config%2Fx/sess/updates.jsonl"
        XCTAssertEqual(grokProjectKey(root: grokRoot, path: dotted), "-Users-me--config-x")
    }

    // A configured Grok root need not be named "sessions" — Sources.load
    // places no such requirement on a custom root. Before projectUnderRoot,
    // a marker-anchored parser would silently return "" from project and
    // false from isSubagent for every event under a root missing that
    // segment. Ported with the fix already in place, unlike Go's history
    // (fixed there in a follow-up commit after the initial parser shipped).
    func test_grokParser_projectAndSubagent_rootWithoutSessionsSegment() {
        let root = "/Users/me/my-grok-archive"
        let main = root + "/%2FUsers%2Fme%2Fsrc%2Fproj/01a0-sess/updates.jsonl"
        let sub = root + "/%2FUsers%2Fme%2F.grok%2Fworktrees%2Fx%2Fsubagent-01a0/01a0/updates.jsonl"

        let p = GrokParser()
        XCTAssertEqual(p.project(main, root: root), "-Users-me-src-proj")
        XCTAssertFalse(p.isSubagent(main, root: root))
        XCTAssertTrue(p.isSubagent(sub, root: root))
    }

    // MARK: - Walkable

    func test_grokParser_walkableOnlyMatchesUpdatesJSONL() {
        let p = GrokParser()
        XCTAssertTrue(p.walkable("updates.jsonl"))
        // _meta.totalTokens lives in other files and is cumulative context,
        // not usage. Reading them would be a large silent overcount.
        for name in ["messages.jsonl", "meta.jsonl", "notes.txt"] {
            XCTAssertFalse(p.walkable(name), "\(name) must not be walkable")
        }
    }

    // MARK: - Subagent detection

    func test_grokParser_isSubagent() {
        let p = GrokParser()
        let sub = grokRoot + "/%2FUsers%2Fme%2F.grok%2Fworktrees%2Fx%2Fsubagent-01a0/01a0/updates.jsonl"
        XCTAssertTrue(p.isSubagent(sub, root: grokRoot), "a subagent worktree session must be flagged")
        XCTAssertFalse(p.isSubagent(grokPath, root: grokRoot), "a main session must not be flagged")
    }

    // MARK: - parserFor dispatch

    func test_parserFor_dispatchesByVendor() {
        XCTAssertTrue(parserFor(vendor: "grok") is GrokParser)
        XCTAssertTrue(parserFor(vendor: "claude") is ClaudeParser)
        XCTAssertTrue(parserFor(vendor: "unknown-future-vendor") is ClaudeParser)
    }

    // MARK: - End-to-end through Reader.onChange (Step 5 wiring)

    // The root deliberately has no "sessions" segment — proves the
    // dispatch routes through the root-relative GrokParser rather than a
    // marker anchored on that name.
    func test_reader_grokEndToEnd_scansOnlyUpdatesJSONL_andAttributesProject() async throws {
        let unresolvedRoot = NSTemporaryDirectory() + "grok-e2e-\(UUID().uuidString)/my-archive"
        let dir = unresolvedRoot + "/%2FUsers%2Fme%2Fsrc%2Fproj/01a0-sess"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: unresolvedRoot) }

        // Canonicalize with realpath(3), not `resolvingSymlinksInPath`:
        // on macOS NSTemporaryDirectory() lives under /var, a symlink to
        // /private/var, and FileManager's directory enumeration returns
        // the resolved /private/... form via a syscall-level realpath —
        // Foundation's `resolvingSymlinksInPath` does not reliably match
        // that here. Comparing an unresolved root against a resolved
        // scanned path would fail `projectUnderRoot`'s prefix check for a
        // reason that has nothing to do with the parser; any real
        // configured root (already a canonical absolute path, e.g.
        // ~/.grok/sessions) has no such mismatch.
        var buf = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolvedRoot, &buf) != nil else {
            throw NSError(domain: "GrokReaderTests", code: 2,
                           userInfo: [NSLocalizedDescriptionKey: "realpath failed for \(unresolvedRoot)"])
        }
        let root = String(cString: buf)

        let fixtureBody = try String(contentsOf: fixtureURL(named: "grok_updates.jsonl"), encoding: .utf8)
        try fixtureBody.write(toFile: dir + "/updates.jsonl", atomically: true, encoding: .utf8)
        // A sibling file that must be ignored: its token fields are
        // cumulative context, not usage.
        try fixtureBody.write(toFile: dir + "/messages.jsonl", atomically: true, encoding: .utf8)

        let source = SourceEntry(vendor: "grok", label: "grok", root: root)
        let reader = Reader()
        let events = try await reader.initialScan(root: root, source: source, notBefore: .distantPast)

        var usage = 0
        for e in events {
            XCTAssertEqual(e.vendor, "grok")
            XCTAssertEqual(e.source, "grok/grok")
            if e.coverageOnly { continue }
            usage += 1
            XCTAssertEqual(e.project, "-Users-me-src-proj")
            XCTAssertTrue(e.costed)
        }
        // Exactly the 5 usage events from updates.jsonl. If messages.jsonl
        // were also walked this would be 10.
        XCTAssertEqual(usage, 5, "messages.jsonl must be skipped")
    }
}
