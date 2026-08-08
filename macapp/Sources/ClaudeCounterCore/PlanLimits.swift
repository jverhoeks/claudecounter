import Foundation

/// One vendor's utilisation of one of its own windows. Mirrors
/// `planlimits.Gauge` in Go.
public struct PlanGauge: Equatable, Sendable {
    public var vendor: String
    public var windowLabel: String
    public var pct: Double
    public var resetsAt: Date
    public var observed: Date
    public var stale: Bool
    public var plan: String
}

/// Mirrors `tui/internal/planlimits` in Go. Reads vendor-reported plan
/// utilisation out of the Codex and Grok CLIs' own local logs. Every
/// observation is point-in-time: scanners take the single most recent
/// value per window and never aggregate across events.
public enum PlanLimits {

    private static let shortWindowCutoffMinutes = 1440
    // The longest window Codex reports is 7 days, so an observation
    // older than this cannot describe a live window and is not worth
    // reading.
    private static let codexScanMaxAge: TimeInterval = 8 * 24 * 3600
    // Caps the walk on very large corpora. Files are visited
    // newest-first, so the cap only ever drops observations older than
    // ones already found.
    private static let codexScanMaxFiles = 50
    private static let grokBillingMarker = "billing: fetched credits config"

    public static func defaultCodexRoot() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".codex/sessions")
    }

    public static func defaultGrokLog() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".grok/logs/unified.jsonl")
    }

    /// Renders a window duration compactly: hours below a day, whole
    /// days above. 300 -> "5h", 10080 -> "7d".
    public static func windowLabel(minutes: Int) -> String {
        if minutes < shortWindowCutoffMinutes { return "\(minutes / 60)h" }
        if minutes == shortWindowCutoffMinutes { return "24h" }
        return "\(minutes / shortWindowCutoffMinutes)d"
    }

    /// Returns the most recent observation for each window Codex reports.
    ///
    /// Codex slot names are NOT stable across CLI versions: older builds
    /// put the 5-hour window in `primary` and the weekly in `secondary`;
    /// newer ones put the weekly in `primary` and omit the 5-hour window
    /// entirely. `limit_id` varies too ("codex", "premium"). Keying on
    /// window_minutes is therefore the only reliable identity.
    ///
    /// A missing or unreadable root is not an error — these are optional
    /// inputs and their absence simply means no rows.
    public static func scanCodex(root: String, now: Date) -> [PlanGauge] {
        guard !root.isEmpty else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        // window_minutes -> newest observation seen so far.
        var best: [Int: PlanGauge] = [:]
        var bestAt: [Int: Date] = [:]

        for file in codexFiles(root: root, now: now) {
            guard let body = try? String(contentsOfFile: file, encoding: .utf8) else {
                continue // unreadable file: keep scanning the rest
            }
            for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
                // Cheap reject before the JSON parse: the vast majority
                // of lines in a session transcript carry no rate limits.
                guard rawLine.contains("\"rate_limits\"") else { continue }
                guard let data = String(rawLine).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = obj["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let rl = payload["rate_limits"] as? [String: Any],
                      let ts = obj["timestamp"] as? String,
                      let observed = iso.date(from: ts) ?? isoPlain.date(from: ts)
                else { continue } // malformed line: skip, partial data beats none

                let planType = rl["plan_type"] as? String ?? ""
                for slotKey in ["primary", "secondary"] {
                    guard let slot = rl[slotKey] as? [String: Any],
                          let minutes = slot["window_minutes"] as? Int, minutes > 0,
                          let used = slot["used_percent"] as? Double
                    else { continue }
                    if let prev = bestAt[minutes], observed <= prev { continue }
                    let resetsUnix = (slot["resets_at"] as? Double) ?? 0
                    let resets = Date(timeIntervalSince1970: resetsUnix)
                    bestAt[minutes] = observed
                    best[minutes] = PlanGauge(vendor: "codex",
                                              windowLabel: windowLabel(minutes: minutes),
                                              pct: used,
                                              resetsAt: resets,
                                              observed: observed,
                                              stale: resets < now,
                                              plan: planType)
                }
            }
        }
        // Shortest window first, so 5h precedes 7d.
        return best.keys.sorted().compactMap { best[$0] }
    }

    /// Returns Grok's weekly utilisation, or nothing.
    ///
    /// Grok reports only a weekly billing period, vendor-anchored
    /// (Thursday 20:00 UTC), so it aligns with neither the ISO week nor
    /// Codex's 7-day rolling window. It is never reconciled with either.
    ///
    /// Grok's session transcripts are deliberately NOT read: they carry
    /// only a cumulative per-prompt context total, which is not billable
    /// tokens, and they are where all the corpus size is.
    public static func scanGrok(path: String, now: Date) -> [PlanGauge] {
        guard !path.isEmpty, let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [] // absent log is a normal state, not a failure
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        var newest: PlanGauge?
        var newestAt = Date.distantPast

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: true) {
            // Substring reject first: only a small fraction of lines are
            // billing lines, so this avoids parsing almost all of them.
            guard rawLine.contains(grokBillingMarker) else { continue }
            guard let data = String(rawLine).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["msg"] as? String == grokBillingMarker,
                  let ts = obj["ts"] as? String,
                  let observed = iso.date(from: ts) ?? isoPlain.date(from: ts)
            else { continue }
            if newest != nil, observed <= newestAt { continue }
            guard let ctx = obj["ctx"] as? [String: Any],
                  let config = ctx["config"] as? [String: Any],
                  let pct = config["creditUsagePercent"] as? Double,
                  let period = config["currentPeriod"] as? [String: Any],
                  let endStr = period["end"] as? String,
                  let end = iso.date(from: endStr) ?? isoPlain.date(from: endStr)
            else { continue }

            newestAt = observed
            newest = PlanGauge(vendor: "grok",
                               windowLabel: "wk",
                               pct: pct,
                               resetsAt: end,
                               observed: observed,
                               stale: end < now,
                               plan: ctx["subscriptionTier"] as? String ?? "")
        }
        return newest.map { [$0] } ?? []
    }

    /// Lists session transcripts newest-first, dropping anything older
    /// than the longest window Codex reports.
    private static func codexFiles(root: String, now: Date) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root),
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let cutoff = now.addingTimeInterval(-codexScanMaxAge)
        var found: [(path: String, mod: Date)] = []
        for case let url as URL in en {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir, url.pathExtension == "jsonl" else { continue }
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate, mod >= cutoff
            else { continue }
            found.append((url.path, mod))
        }
        return found.sorted { $0.mod > $1.mod }.prefix(codexScanMaxFiles).map(\.path)
    }
}
