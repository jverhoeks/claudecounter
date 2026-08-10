import Foundation

/// Mirrors `tui/internal/sources` in Go. The two implementations are
/// independent — see `Sources.load` there for the canonical behaviour
/// this one must match, including the two easy-to-get-wrong edges: a
/// root of "/" in the overlap check, and CRLF line endings in the file.

/// One configured root. `(vendor, label)` is the series identity — the
/// root path is the only thing that can distinguish two subscriptions
/// under the same vendor, since transcripts carry no account identifier.
public struct SourceEntry: Equatable, Sendable {
    public var vendor: String
    public var label: String
    public var root: String

    public init(vendor: String, label: String, root: String) {
        self.vendor = vendor
        self.label = label
        self.root = root
    }

    /// The series identity: vendor and label together. Two sources may
    /// share a label across vendors, so the label alone is not unique.
    public var id: String { "\(vendor)/\(label)" }
}

public struct SourcesConfig: Equatable, Sendable {
    public var sources: [SourceEntry]

    public init(sources: [SourceEntry]) {
        self.sources = sources
    }
}

public enum SourcesError: Error, LocalizedError, Equatable {
    case malformed(String)
    case unknownVendor(index: Int, vendor: String)
    case emptyLabel(index: Int)
    case emptyRoot(index: Int)
    case duplicateSource(id: String)
    case unsafeCharacter(index: Int, field: String)
    case sharedRoot(idA: String, idB: String, root: String)
    case nestedRoots(innerID: String, innerRoot: String, outerID: String, outerRoot: String)

    public var errorDescription: String? {
        switch self {
        case .malformed(let line):
            return "malformed sources.toml line: \(line)"
        case .unknownVendor(let index, let vendor):
            return "source \(index): unknown vendor \"\(vendor)\""
        case .emptyLabel(let index):
            return "source \(index): label must not be empty"
        case .emptyRoot(let index):
            return "source \(index): root must not be empty"
        case .unsafeCharacter(let index, let field):
            return "source \(index): \(field) must not contain '#', '\"', '\\', or a newline — the shared TOML writer/parser can't round-trip those characters"
        case .duplicateSource(let id):
            return "duplicate source \(id): two roots under one label would merge two subscriptions"
        case .sharedRoot(let idA, let idB, let root):
            return "sources \(idA) and \(idB) share the root \(root)"
        case .nestedRoots(let innerID, let innerRoot, let outerID, let outerRoot):
            return "source \(innerID) root \(innerRoot) is nested inside source \(outerID) root \(outerRoot): events would count twice"
        }
    }
}

public enum Sources {

    /// The vendors a reader exists for. `grok` is accepted so a user can
    /// configure it ahead of its reader shipping without the file
    /// failing to load.
    static let knownVendors: Set<String> = ["claude", "grok"]

    /// Sits beside limits.toml so both surfaces read one directory.
    public static func defaultConfigPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/claudecounter/sources.toml")
    }

    /// The implicit source list used when no config file exists: exactly
    /// today's hardcoded behaviour, so an existing user sees no change.
    public static func defaults(home: String) -> [SourceEntry] {
        [SourceEntry(vendor: "claude", label: "claude",
                     root: (home as NSString).appendingPathComponent(".claude/projects"))]
    }

    /// Reads sources.toml. A missing file yields `defaults(home:)` and no
    /// error — that is the normal unconfigured state. A malformed or
    /// invalid file throws so a typo is surfaced rather than silently
    /// read as "no sources".
    ///
    /// Missing and unreadable are deliberately NOT the same thing: only
    /// an absent file falls back to defaults, matching Go's
    /// `errors.Is(err, fs.ErrNotExist)` check. A file that exists but
    /// can't be read (permissions, a sandboxed container boundary, ...)
    /// throws instead of silently pretending the user has no config —
    /// `try?` around the read would otherwise swallow that distinction
    /// and hide a real misconfiguration behind "using defaults".
    public static func load(path: String, home: String) throws -> SourcesConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            return SourcesConfig(sources: defaults(home: home))
        }
        let body = try String(contentsOfFile: path, encoding: .utf8)
        let entries = try parse(body)
        return SourcesConfig(sources: try validate(entries, home: home))
    }

    /// Writes `sources` as `[[source]]` TOML tables to `path`, creating
    /// the parent directory if needed (same idiom as
    /// `PricingTable.writeToAppOverride`'s app-override writer) — sits
    /// beside limits.toml, so that directory already exists once either
    /// config has been touched, but a fresh install has neither yet.
    ///
    /// Validates through the exact same `validate` helper `load` calls,
    /// so the two can't drift: a file this GUI writes can never be one
    /// `load` — and therefore the TUI — would then reject. Validation
    /// runs BEFORE anything touches disk, so a rejected write leaves
    /// the previous file (if any) untouched rather than replacing it
    /// with something neither app can read.
    ///
    /// Writes the caller's roots verbatim (no `~`-expansion) — the
    /// stored file should read back as what the user/editor actually
    /// entered, not a silently rewritten absolute path.
    public static func write(_ sources: [SourceEntry], to path: String, home: String = NSHomeDirectory()) throws {
        let raw = sources.map { RawEntry(vendor: $0.vendor, label: $0.label, root: $0.root) }
        _ = try validate(raw, home: home)

        var body = ""
        for s in sources {
            body += "[[source]]\n"
            body += "vendor = \"\(s.vendor)\"\n"
            body += "label = \"\(s.label)\"\n"
            body += "root = \"\(s.root)\"\n\n"
        }

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private struct RawEntry {
        var vendor = ""
        var label = ""
        var root = ""
    }

    /// The rules shared by `load` (parsed-from-disk entries) and `write`
    /// (caller-supplied entries about to be persisted): unknown vendor,
    /// empty label/root, unsafe characters in label/root, a
    /// `~`-expanded root, duplicate `(vendor,label)` ids, and
    /// overlapping/nested roots. Kept as the single place both callers
    /// route through so they cannot drift apart.
    private static func validate(_ entries: [RawEntry], home: String) throws -> [SourceEntry] {
        var out: [SourceEntry] = []
        out.reserveCapacity(entries.count)
        var seen = Set<String>()
        for (index, raw) in entries.enumerated() {
            guard knownVendors.contains(raw.vendor) else {
                throw SourcesError.unknownVendor(index: index, vendor: raw.vendor)
            }
            guard !raw.label.isEmpty else { throw SourcesError.emptyLabel(index: index) }
            guard !raw.root.isEmpty else { throw SourcesError.emptyRoot(index: index) }
            // `write` emits `key = "value"` with no escaping, and
            // `parse` strips comments quote-unaware from the first `#`
            // on any line. A label/root containing `#`, `"`, `\`, or a
            // newline would therefore round-trip through write+load as
            // a DIFFERENT, silently wrong value instead of failing
            // loudly — e.g. a folder picked via NSOpenPanel named
            // "/a/b#c" would be truncated to "/a/b" on the next load,
            // contribute nothing, and tell the user nothing. Rejecting
            // here means both `load` (a hand-edited file) and `write`
            // (the GUI editor, which can then show the error inline)
            // catch it before it ever becomes a silently-wrong root.
            guard !containsUnsafeCharacter(raw.label) else {
                throw SourcesError.unsafeCharacter(index: index, field: "label")
            }
            guard !containsUnsafeCharacter(raw.root) else {
                throw SourcesError.unsafeCharacter(index: index, field: "root")
            }
            let entry = SourceEntry(vendor: raw.vendor, label: raw.label, root: expand(raw.root, home: home))
            guard !seen.contains(entry.id) else { throw SourcesError.duplicateSource(id: entry.id) }
            seen.insert(entry.id)
            out.append(entry)
        }
        try checkOverlap(out)
        return out
    }

    private static func containsUnsafeCharacter(_ s: String) -> Bool {
        s.contains("#") || s.contains("\"") || s.contains("\\") || s.contains(where: { $0.isNewline })
    }

    /// Parses the `[[source]]` tables out of a sources.toml body. Lines
    /// are split on `Character.isNewline`, not `separator: "\n"`: Swift's
    /// `Character` is an extended grapheme cluster, so "\r\n" in a CRLF
    /// file is a SINGLE Character equal to neither "\n" nor "\r" alone —
    /// `separator: "\n"` would then match nothing in a CRLF file and read
    /// the whole file as one "line". `isNewline` treats "\n", "\r" and
    /// "\r\n" each as one line ending. Mirrors the fix already applied to
    /// Limits.swift.
    private static func parse(_ body: String) throws -> [RawEntry] {
        var entries: [RawEntry] = []
        var current: RawEntry?

        func push() {
            if let c = current { entries.append(c) }
        }

        for rawLine in body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[line.startIndex..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw SourcesError.malformed(line) }
                push()
                if line.hasPrefix("[["), line.hasSuffix("]]") {
                    // Trim whitespace INSIDE the brackets too: "[[ source ]]"
                    // is valid TOML, but comparing the whole bracketed
                    // token verbatim would miss it (see Limits.swift's
                    // equivalent fix for single-bracket headers).
                    let name = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
                    current = (name == "source") ? RawEntry() : nil
                } else {
                    current = nil
                }
                continue
            }

            guard current != nil else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let value = unquote(parts[1])
            switch parts[0] {
            case "vendor": current!.vendor = value
            case "label":  current!.label = value
            case "root":   current!.root = value
            default: continue
            }
        }
        push()
        return entries
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }

    private static func expand(_ p: String, home: String) -> String {
        if p == "~" { return home }
        if p.hasPrefix("~/") {
            // Go's filepath.Join(home, p[2:]) cleans its result
            // internally, so "~/x/../y" resolves to "<home>/y". Building
            // the joined path with appendingPathComponent alone (no
            // clean) leaves the literal "x/../y" in place — and because
            // checkOverlap and duplicate detection compare roots as
            // plain strings, that divergence could make the Go and Swift
            // loaders disagree about whether two roots overlap. Routing
            // through clean() keeps both sides producing the same
            // canonical string for the same input.
            return clean((home as NSString).appendingPathComponent(String(p.dropFirst(2))))
        }
        return clean(p)
    }

    /// A small, POSIX-only stand-in for Go's `filepath.Clean`: collapses
    /// "." segments, resolves ".." lexically, and drops redundant
    /// separators, without touching the filesystem (no symlink
    /// resolution, unlike `NSString.standardizingPath`).
    private static func clean(_ p: String) -> String {
        if p.isEmpty { return "." }
        let isAbsolute = p.hasPrefix("/")
        var out: [Substring] = []
        for comp in p.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." {
                if let last = out.last, last != ".." {
                    out.removeLast()
                } else if !isAbsolute {
                    out.append(comp)
                }
                continue
            }
            out.append(comp)
        }
        let joined = out.joined(separator: "/")
        if isAbsolute { return "/" + joined }
        return joined.isEmpty ? "." : joined
    }

    /// Rejects a root nested inside another (or two sources sharing one
    /// root). An event under both would be scanned twice and counted
    /// twice, which is a silent doubling of the user's spend.
    ///
    /// "/" gets a special case: `"/" + "/"` is `"//"`, which is not a
    /// prefix of anything, so the naive `hasPrefix(a + "/")` check lets a
    /// root of "/" escape detection entirely (this was a real bug caught
    /// in the Go loader's review). Any other root is trivially nested
    /// inside "/", so it's checked directly instead of via the prefix.
    private static func checkOverlap(_ entries: [SourceEntry]) throws {
        for i in entries.indices {
            for j in entries.indices where j != i {
                let a = entries[i].root, b = entries[j].root
                if a == b {
                    throw SourcesError.sharedRoot(idA: entries[i].id, idB: entries[j].id, root: a)
                }
                if a == "/" {
                    if b != "/" {
                        throw SourcesError.nestedRoots(innerID: entries[j].id, innerRoot: b,
                                                        outerID: entries[i].id, outerRoot: a)
                    }
                } else if b.hasPrefix(a + "/") {
                    throw SourcesError.nestedRoots(innerID: entries[j].id, innerRoot: b,
                                                    outerID: entries[i].id, outerRoot: a)
                }
            }
        }
    }
}
