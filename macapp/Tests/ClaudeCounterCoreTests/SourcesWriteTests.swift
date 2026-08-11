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

    // `write` emits `key = "value"` with no escaping, and `parse` strips
    // comments quote-unaware from the first "#" on any line — so a root
    // containing "#" would otherwise round-trip through write+load as a
    // silently DIFFERENT (truncated) path instead of failing loudly. A
    // folder named "/a/b#c", legal on macOS and reachable via
    // NSOpenPanel with no warning, must be rejected at write time
    // rather than silently corrupted on the next load.
    func test_write_rejectsRootContainingHash() {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let bad = [SourceEntry(vendor: "claude", label: "work", root: "/a/b#c")]
        XCTAssertThrowsError(try Sources.write(bad, to: p))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p))
    }

    // Same hazard for a label containing a literal double quote — it
    // would break the emitted `label = "..."` line's own quoting.
    func test_write_rejectsLabelContainingQuote() {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        let bad = [SourceEntry(vendor: "claude", label: #"wor"k"#, root: "/a/b")]
        XCTAssertThrowsError(try Sources.write(bad, to: p))
    }

    // A hand-edited sources.toml with the same unsafe character must be
    // rejected by `load` too — `validate` is the single place both
    // callers route through, so this can't drift from `write`'s rule.
    func test_load_rejectsRootContainingBackslash() throws {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: p) }
        try #"""
        [[source]]
        vendor = "claude"
        label = "work"
        root = "/a/b\c"
        """#.write(toFile: p, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }
}
