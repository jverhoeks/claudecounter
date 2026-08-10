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

    func test_load_emptyFileYieldsNoSources() throws {
        let p = try write("# nothing\n")
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertEqual(try Sources.load(path: p, home: "/home/u").sources.count, 0)
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
}
