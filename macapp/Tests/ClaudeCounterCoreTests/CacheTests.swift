import XCTest
@testable import ClaudeCounterCore

final class CacheTests: XCTestCase {

    // Bumping the version invalidates old caches so a stale cell without a
    // source cannot be resurrected under the wrong series.
    func test_cacheVersion_wasBumpedForSeriesKeys() {
        XCTAssertEqual(CacheFile.currentVersion, 4)
    }

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
        XCTAssertEqual(loaded?.version, CacheFile.currentVersion)
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

    func test_restore_hourBucketsSurviveRestart_sameDay() async throws {
        // Regression for the "graph lost the older time" bug: previously
        // the cache only persisted (day, project, model, isSub) cells.
        // Today's hourly distribution was rebuilt only from new events
        // *after* restart, leaving older hours flat. Now we persist
        // the per-hour state too.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CacheStore(url: url)

        // Two events on Self.fixedNow's day, at hours 9 and 14.
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Self.fixedNow)
        c.hour = 9; let nineAM = Calendar.current.date(from: c)!
        c.hour = 14; let twoPM = Calendar.current.date(from: c)!

        let agg1 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        await agg1.apply(UsageEvent(
            timestamp: nineAM, sessionID: "s1", cwd: "/tmp",
            project: "p1", model: "claude-opus-4-7",
            messageID: "m1", requestID: "r1", isSubagent: false,
            usage: Usage(input: 1_000_000)))
        await agg1.apply(UsageEvent(
            timestamp: twoPM, sessionID: "s1", cwd: "/tmp",
            project: "p1", model: "claude-opus-4-7",
            messageID: "m2", requestID: "r2", isSubagent: false,
            usage: Usage(input: 2_000_000)))

        try store.save(await CacheFile.snapshot(
            aggregator: agg1, offsets: [:], parseErrors: 0, writtenAt: Self.fixedNow))

        let agg2 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        _ = try await store.load()!.restore(into: agg2)

        // Snapshot from agg2 must reflect both hours, even though no new
        // events flowed through apply() in this aggregator instance.
        let snap = await agg2.snapshot()
        XCTAssertEqual(snap.todayHourly[9].input, 1_000_000)
        XCTAssertEqual(snap.todayHourly[14].input, 2_000_000)
        XCTAssertEqual(snap.todayHourly[12].input, 0, "untouched hours stay zero")
    }

    func test_restore_yesterdayHourBuckets_staySeparateFromToday() async throws {
        // Hour buckets are kept per-day across the window (so the user
        // can drill into past days), but yesterday's hours must never
        // bleed into TODAY's hourly arrays after a restart.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CacheStore(url: url)

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Self.fixedNow)!

        // Aggregator clocked at "yesterday" applies an event yesterday;
        // hour bucket gets stamped with yesterday's CivilDay.
        let agg1 = Aggregator(pricing: .defaults, now: { yesterday })
        await agg1.apply(UsageEvent(
            timestamp: yesterday, sessionID: "s1", cwd: "/tmp",
            project: "p1", model: "claude-opus-4-7",
            messageID: "m1", requestID: "r1", isSubagent: false,
            usage: Usage(input: 1_000_000)))

        try store.save(await CacheFile.snapshot(
            aggregator: agg1, offsets: [:], parseErrors: 0, writtenAt: yesterday))

        // Restore into an aggregator clocked at today.
        let agg2 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        _ = try await store.load()!.restore(into: agg2)

        let snap = await agg2.snapshot()
        for h in 0..<24 {
            XCTAssertEqual(snap.todayHourly[h].input, 0,
                           "hour \(h): yesterday's bucket must not bleed into today")
        }

        // …and yesterday's per-hour breakdown is still available for
        // the drill-in view.
        let yHour = Calendar.current.component(.hour, from: yesterday)
        let yKey = String(format: "%04d-%02d-%02d",
                          Calendar.current.component(.year, from: yesterday),
                          Calendar.current.component(.month, from: yesterday),
                          Calendar.current.component(.day, from: yesterday))
        let yEntry = snap.daily.first { $0.day == yKey }
        XCTAssertNotNil(yEntry, "yesterday must be inside the 30-day window")
        XCTAssertGreaterThan(yEntry?.hourlyUSDByModel[yHour]["claude-opus-4-7"] ?? 0, 0,
                             "yesterday's hourly breakdown survives the restart")
    }

    func test_restore_dropsHourBucketsOutsideWindow() async throws {
        // Hour entries older than the 30-day window are pruned on load
        // so the cache can't grow without bound.
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CacheStore(url: url)

        let old = Calendar.current.date(byAdding: .day, value: -40, to: Self.fixedNow)!
        let agg1 = Aggregator(pricing: .defaults, now: { old })
        await agg1.apply(UsageEvent(
            timestamp: old, sessionID: "s1", cwd: "/tmp",
            project: "p1", model: "claude-opus-4-7",
            messageID: "m1", requestID: "r1", isSubagent: false,
            usage: Usage(input: 1_000_000)))

        try store.save(await CacheFile.snapshot(
            aggregator: agg1, offsets: [:], parseErrors: 0, writtenAt: old))

        let agg2 = Aggregator(pricing: .defaults, now: { Self.fixedNow })
        _ = try await store.load()!.restore(into: agg2)

        let buckets = await agg2.exportHourBuckets()
        XCTAssertTrue(buckets.isEmpty, "40-day-old hour buckets must be pruned on load")
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
        XCTAssertEqual(
            snap2.day[SeriesKey(source: "claude/claude", vendor: "claude", model: "claude-opus-4-7")]?.tokens.input,
            1_000_000)
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
