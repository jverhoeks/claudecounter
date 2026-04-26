import XCTest
@testable import ClaudeCounterCore

final class CacheTests: XCTestCase {

    func test_save_then_load_roundTrip() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CacheStore(url: url)

        let agg = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        let ev = UsageEvent(
            timestamp: Self.fixedNow, sessionID: "s1", cwd: "/tmp",
            project: "p1", model: "claude-opus-4-7",
            messageID: "m1", requestID: "r1", isSubagent: false,
            usage: Usage(input: 100, output: 200)
        )
        await agg.apply(ev)

        let offsets = ["/path/to/file.jsonl": Int64(8192)]
        let cache = await CacheFile.snapshot(
            aggregator: agg, offsets: offsets, parseErrors: 0, writtenAt: Self.fixedNow
        )
        try store.save(cache)

        let loaded = try store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, 1)
        XCTAssertEqual(loaded?.cells.count, 1)
        XCTAssertEqual(loaded?.cells.first?.input, 100)
        XCTAssertEqual(loaded?.cells.first?.output, 200)
        XCTAssertEqual(loaded?.cells.first?.project, "p1")
        XCTAssertEqual(loaded?.offsets["/path/to/file.jsonl"], 8192)
        XCTAssertEqual(loaded?.perMsg, ["m1:r1"])
    }

    func test_load_missingFile_returnsNil() throws {
        let url = tempURL()
        let store = CacheStore(url: url)
        XCTAssertNil(try store.load())
    }

    func test_load_corruptFile_throws() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not valid json".utf8).write(to: url)
        let store = CacheStore(url: url)
        XCTAssertThrowsError(try store.load())
    }

    func test_invalidate_removesFile() throws {
        let url = tempURL()
        try Data("{}".utf8).write(to: url)
        let store = CacheStore(url: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.invalidate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_restore_repopulatesAggregatorState() async throws {
        // Save state from agg1, restore it into agg2, verify snapshot matches.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CacheStore(url: url)

        let agg1 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        for i in 0..<3 {
            await agg1.apply(UsageEvent(
                timestamp: Self.fixedNow, sessionID: "s1", cwd: "/tmp",
                project: "p\(i)", model: "claude-opus-4-7",
                messageID: "m\(i)", requestID: "r\(i)", isSubagent: false,
                usage: Usage(input: UInt64(1_000_000 * (i + 1)))
            ))
        }
        let snap1 = await agg1.snapshot()

        let cache = await CacheFile.snapshot(
            aggregator: agg1, offsets: [:], parseErrors: 0, writtenAt: Self.fixedNow
        )
        try store.save(cache)

        let loaded = try store.load()!
        let agg2 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        _ = await loaded.restore(into: agg2)
        let snap2 = await agg2.snapshot()

        XCTAssertEqual(snap1.dayProj.count, snap2.dayProj.count)
        for (k, p1) in snap1.dayProj {
            let p2 = snap2.dayProj[k]
            XCTAssertEqual(p1.main.input, p2?.main.input, "project \(k) main.input mismatch")
            XCTAssertEqual(p1.mainUSD, p2?.mainUSD ?? 0, accuracy: 1e-9)
        }
    }

    func test_restore_dedupePersistsAcrossRestart() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CacheStore(url: url)

        let agg1 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        let ev = UsageEvent(
            timestamp: Self.fixedNow, sessionID: "s1", cwd: "/tmp",
            project: "p1", model: "claude-opus-4-7",
            messageID: "m1", requestID: "r1", isSubagent: false,
            usage: Usage(input: 1_000_000)
        )
        await agg1.apply(ev)

        try store.save(await CacheFile.snapshot(
            aggregator: agg1, offsets: [:], parseErrors: 0, writtenAt: Self.fixedNow
        ))

        let agg2 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        _ = try await store.load()!.restore(into: agg2)

        // Re-apply the same event in agg2 — it should be deduped because
        // perMsg was restored.
        await agg2.apply(ev)
        let snap2 = await agg2.snapshot()
        XCTAssertEqual(snap2.dupes, 1)
        // Tokens unchanged (only counted once originally + dedupe of replay).
        XCTAssertEqual(snap2.day["claude-opus-4-7"]?.tokens.input, 1_000_000)
    }

    // MARK: - helpers

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ct-\(UUID().uuidString).json")
    }

    static let fixedNow: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 26; c.hour = 14
        return Calendar.current.date(from: c)!
    }()
}
