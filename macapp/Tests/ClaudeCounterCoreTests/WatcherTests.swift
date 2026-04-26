import XCTest
@testable import ClaudeCounterCore
#if canImport(CoreServices)
import CoreServices
#endif

final class WatcherTests: XCTestCase {

    // MARK: - mapFlags pure-function tests

    func test_mapFlags_directoryEvent_isIgnored() {
        let flags = FSEventStreamEventFlags(
            UInt32(kFSEventStreamEventFlagItemCreated) |
            UInt32(kFSEventStreamEventFlagItemIsDir)
        )
        XCTAssertNil(mapFlags(flags))
    }

    func test_mapFlags_create_isCreate() {
        let flags = FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagItemCreated))
        XCTAssertEqual(mapFlags(flags), .create)
    }

    func test_mapFlags_modify_isModify() {
        let flags = FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagItemModified))
        XCTAssertEqual(mapFlags(flags), .modify)
    }

    func test_mapFlags_removed_isRemove() {
        let flags = FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagItemRemoved))
        XCTAssertEqual(mapFlags(flags), .remove)
    }

    func test_mapFlags_renamed_isRemove() {
        // Renames count as remove from the watcher's point of view —
        // the reader's offset map gets cleared and the new name (if it
        // shows up) is treated as a fresh file.
        let flags = FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagItemRenamed))
        XCTAssertEqual(mapFlags(flags), .remove)
    }

    func test_mapFlags_historyDoneOrUnrelated_isNil() {
        let flags = FSEventStreamEventFlags(UInt32(kFSEventStreamEventFlagHistoryDone))
        XCTAssertNil(mapFlags(flags))
    }

    // MARK: - Live FSEvents smoke test

    /// End-to-end smoke test: write a jsonl file under a watched dir and
    /// expect the watcher to emit at least one event for it within a
    /// reasonable timeout. FSEvents has some inherent latency (50ms here
    /// + macOS scheduling) so we give it 5s.
    func test_watcher_emitsEvent_whenJsonlIsCreated() async throws {
        let root = NSTemporaryDirectory() + "wt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let watcher = Watcher(root: root)
        let stream = watcher.start()

        // FSEvents needs a beat to subscribe before changes register.
        try await Task.sleep(nanoseconds: 200_000_000)

        let target = root + "/test.jsonl"
        try "{\"hello\":\"world\"}\n".write(toFile: target, atomically: true, encoding: .utf8)

        // Expect at least one matching event on the stream within 5s.
        let event = try await withTimeout(seconds: 5) {
            for await change in stream where change.path.hasSuffix("test.jsonl") {
                return change
            }
            return nil
        }
        watcher.stop()

        XCTAssertNotNil(event, "watcher did not emit an event for the new .jsonl")
    }

    // MARK: - helpers

    private func withTimeout<T: Sendable>(seconds: TimeInterval, _ work: @Sendable @escaping () async throws -> T?) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let value = try await group.next()
            group.cancelAll()
            return value ?? nil
        }
    }
}
