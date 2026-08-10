import XCTest
@testable import ClaudeCounterCore

final class SourcesWriteTests: XCTestCase {

    // The GUI editor writes the same file the TUI reads, so a round trip
    // through write+load must be lossless.
    func test_write_thenLoad_roundTrips() throws {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let want = [
            SourceEntry(vendor: "claude", label: "work", root: "/home/u/.claude/projects"),
            SourceEntry(vendor: "claude", label: "personal", root: "/home/u/.claude-p/projects"),
        ]
        try Sources.write(want, to: p)
        let got = try Sources.load(path: p, home: "/home/u")
        XCTAssertEqual(got.sources, want)
    }

    // Writing a config the loader would reject must fail at write time,
    // not leave the user with a file neither app can read.
    func test_write_rejectsInvalidConfig() {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let bad = [
            SourceEntry(vendor: "claude", label: "dup", root: "/a"),
            SourceEntry(vendor: "claude", label: "dup", root: "/b"),
        ]
        XCTAssertThrowsError(try Sources.write(bad, to: p))
    }

    // A rejected write must not leave a partial/invalid file behind —
    // validation happens before anything touches disk.
    func test_write_rejectsInvalidConfig_leavesNoFileBehind() {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let bad = [
            SourceEntry(vendor: "claude", label: "dup", root: "/a"),
            SourceEntry(vendor: "claude", label: "dup", root: "/b"),
        ]
        XCTAssertThrowsError(try Sources.write(bad, to: p))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
    }

    // write() creates ~/.config/claudecounter/ if it doesn't exist yet —
    // sits beside limits.toml, matching how that directory is handled.
    func test_write_createsParentDirectoryIfNeeded() throws {
        let dir = NSTemporaryDirectory() + "sources-dir-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/nested/sources.toml"
        let want = [SourceEntry(vendor: "claude", label: "work", root: "/home/u/.claude/projects")]
        try Sources.write(want, to: p)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
    }
}
