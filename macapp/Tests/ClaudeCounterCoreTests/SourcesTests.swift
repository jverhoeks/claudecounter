import XCTest
@testable import ClaudeCounterCore

final class SourcesTests: XCTestCase {

    private func write(_ body: String) throws -> String {
        let p = NSTemporaryDirectory() + "/sources-\(UUID().uuidString).toml"
        try body.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func test_load_missingFileYieldsDefaults() throws {
        let cfg = try Sources.load(path: NSTemporaryDirectory() + "/absent-\(UUID().uuidString).toml",
                                   home: "/home/u")
        XCTAssertEqual(cfg.sources, Sources.defaults(home: "/home/u"))
    }

    func test_defaults_isClaudeProjectsUnderHome() {
        let d = Sources.defaults(home: "/home/u")
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].vendor, "claude")
        XCTAssertEqual(d[0].label, "claude")
        XCTAssertEqual(d[0].root, "/home/u/.claude/projects")
    }

    func test_id_isVendorSlashLabel() {
        XCTAssertEqual(SourceEntry(vendor: "claude", label: "work", root: "/x").id, "claude/work")
    }

    func test_load_parsesAndExpandsTilde() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/.claude/projects"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        let cfg = try Sources.load(path: p, home: "/home/u")
        XCTAssertEqual(cfg.sources.count, 1)
        XCTAssertEqual(cfg.sources[0].root, "/home/u/.claude/projects")
    }

    func test_load_allowsSameLabelAcrossVendors() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "personal"
        root   = "~/.claude/projects"

        [[source]]
        vendor = "grok"
        label  = "personal"
        root   = "~/.grok/sessions"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertNoThrow(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_rejectsDuplicateLabelWithinVendor() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/a"

        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/b"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_rejectsNestedRoots() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "outer"
        root   = "~/.claude/projects"

        [[source]]
        vendor = "claude"
        label  = "inner"
        root   = "~/.claude/projects/sub"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_rejectsUnknownVendor() throws {
        let p = try write("""
        [[source]]
        vendor = "openai"
        label  = "x"
        root   = "~/x"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    // A file that parses cleanly but names zero sources must be
    // rejected, not silently read as "no sources" — that used to be
    // accepted, reporting a confident $0.00 with no indication anything
    // went wrong. See final-review.md I1.
    func test_load_emptyFileYieldsNoSources() throws {
        let p = try write("# nothing\n")
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u")) { error in
            XCTAssertEqual(error as? SourcesError, .noSources)
        }
    }

    func test_load_rejectsTypoedTableName() throws {
        let p = try write("""
        [[sources]]
        vendor = "claude"
        label  = "x"
        root   = "~/x"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u")) { error in
            XCTAssertEqual(error as? SourcesError, .noSources)
        }
    }

    // Regression for the bug caught in the Go loader's review: "/" + "/"
    // is "//", which is not a prefix of anything, so a naive
    // `hasPrefix(root + "/")` check lets a root of "/" escape overlap
    // detection entirely. See tui/internal/sources's
    // TestLoadRejectsRootSlashAsSupersets.
    func test_load_rejectsRootSlashAsSuperset() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "full-fs"
        root   = "/"

        [[source]]
        vendor = "claude"
        label  = "home"
        root   = "/foo"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    // Paths like /foo/bar and /foo/barbaz do not nest: one is not a
    // prefix of the other. They must be allowed. See tui/internal/sources's
    // TestLoadAllowsSiblingPaths.
    func test_load_allowsSiblingPaths() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "bar"
        root   = "/foo/bar"

        [[source]]
        vendor = "claude"
        label  = "barbaz"
        root   = "/foo/barbaz"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertNoThrow(try Sources.load(path: p, home: "/home/u"))
    }

    // Pinned together deliberately: only an ABSENT file falls back to
    // defaults. A file that exists but can't be read (permissions, a
    // sandboxed container boundary, ...) must throw instead of silently
    // looking like "no config" — `try?` around the read used to swallow
    // that distinction (see FR round 1).
    func test_load_missingVsUnreadableFileAreNotTheSame() throws {
        let missing = NSTemporaryDirectory() + "/absent-\(UUID().uuidString).toml"
        XCTAssertNoThrow(try Sources.load(path: missing, home: "/home/u"))
        let cfg = try Sources.load(path: missing, home: "/home/u")
        XCTAssertEqual(cfg.sources, Sources.defaults(home: "/home/u"))

        guard getuid() != 0 else {
            // Root ignores POSIX mode bits, so the permission-denied case
            // below can't be exercised meaningfully as root (e.g. some CI
            // containers). The "missing" half above still ran.
            return
        }
        let unreadable = try write("""
        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/work"
        """)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable)
            try? FileManager.default.removeItem(atPath: unreadable)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable)
        XCTAssertThrowsError(try Sources.load(path: unreadable, home: "/home/u"))
    }

    // Go's filepath.Join(home, p[2:]) cleans its result internally, so
    // "~/x/../y" resolves to "<home>/y". Two roots that differ only by
    // such a segment must therefore collide on the SAME canonical string
    // — including tripping duplicate/overlap detection, since that
    // comparison is a plain string equality (see FR round 1).
    func test_load_tildeExpansionCleansDotDotSegments() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "work"
        root   = "~/x/../y"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        let cfg = try Sources.load(path: p, home: "/home/u")
        XCTAssertEqual(cfg.sources[0].root, "/home/u/y")
    }

    // A bare relative root resolves against whatever CWD happens to be
    // at scan time, and can defeat checkOverlap's textual comparison
    // against an absolute root naming the same tree. It must be
    // rejected outright. See tui/internal/sources's
    // TestLoadRejectsRelativeRoot / final-review.md M2/item 4.
    func test_load_rejectsRelativeRoot() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "rel"
        root   = ".claude/projects"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    // Must be rejected on its own, not merely as a side effect of an
    // overlap comparison against another source.
    func test_load_rejectsRelativeRootAlone() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "rel"
        root   = "relative/only"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }

    func test_load_detectsDuplicateAcrossUncleanedTildePaths() throws {
        let p = try write("""
        [[source]]
        vendor = "claude"
        label  = "a"
        root   = "~/x/../y"

        [[source]]
        vendor = "claude"
        label  = "b"
        root   = "~/y"
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertThrowsError(try Sources.load(path: p, home: "/home/u"))
    }
}
