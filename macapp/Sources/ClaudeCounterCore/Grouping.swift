import Foundation

/// Selects how per-series totals are collapsed for display. The same mode
/// drives the monthly table and the charts. Mirrors `agg.Mode` in
/// `tui/internal/agg/group.go`.
public enum GroupMode: String, Equatable, Sendable, CaseIterable {
    case model   // one series per model, merged across sources
    case vendor  // one series per vendor — the "all Claude" view
    case source  // one series per configured subscription
    case total   // a single series

    /// The mode's own display name — mirrors Go's `Mode.String()`.
    public var label: String { rawValue }

    /// Cycles model -> vendor -> source -> total -> model. Mirrors Go's
    /// `Mode.Next()`.
    public var next: GroupMode {
        switch self {
        case .model:  return .vendor
        case .vendor: return .source
        case .source: return .total
        case .total:  return .model
        }
    }
}

extension GroupMode {
    /// Reduces a series key to its display name under this mode. Mirrors
    /// Go's `Mode.label(SeriesKey)` — kept private to this file since
    /// nothing outside `Grouping.group` needs a series' name in isolation.
    fileprivate func seriesName(for key: SeriesKey) -> String {
        switch self {
        case .vendor: return key.vendor
        case .source: return key.source
        case .total:  return "total"
        case .model:  return key.model
        }
    }
}

/// Collapses per-series totals by mode. Mirrors `agg.Group` in
/// `tui/internal/agg/group.go`.
public enum Grouping {
    /// Every mode partitions the same input, so all four sum to the same
    /// grand total — no mode may lose or duplicate spend. Merges both USD
    /// and tokens: dropping the token merge would leave every token view
    /// wrong while the dollar view looked fine.
    public static func group(_ input: [SeriesKey: ModelDay], by mode: GroupMode) -> [String: ModelDay] {
        var out: [String: ModelDay] = [:]
        for (key, value) in input {
            let name = mode.seriesName(for: key)
            var cur = out[name] ?? ModelDay(usd: 0, tokens: .zero)
            cur.usd += value.usd
            cur.tokens = cur.tokens.adding(value.tokens)
            out[name] = cur
        }
        return out
    }

    /// Collapses per-vendor coverage onto the same display rows `group`
    /// produces, so the two dictionaries always share a key set — a row
    /// without an entry would silently render unmarked.
    ///
    /// A row spanning several vendors takes the worst of them. Averaging,
    /// or weighting by spend, would let a large complete Claude figure
    /// hide a small partial Grok one inside the same row, which is
    /// exactly the failure this marker exists to prevent. Mirrors
    /// `agg.GroupCoverage` in `tui/internal/agg/group.go`.
    public static func groupCoverage(_ input: [SeriesKey: ModelDay],
                                     coverage: [String: Coverage],
                                     by mode: GroupMode) -> [String: Coverage] {
        // Reported in model mode only. The marker is a caveat about one
        // model's turns — the subset of them that predate its vendor's
        // usage field — so on a rollup row it answers a question nobody
        // asked: "grok ~90%" beside a vendor total reads as doubt about
        // the vendor itself. Returning nothing here rather than gating
        // in the view keeps this in step with Go's `GroupCoverage` by
        // construction, and keeps the rule testable — `ByModelTable`
        // lives in `ClaudeCounterBar`, which has no test path.
        guard mode == .model else { return [:] }

        var out: [String: Coverage] = [:]
        for key in input.keys {
            let name = mode.seriesName(for: key)
            let c = coverage[key.vendor] ?? Coverage()
            if let cur = out[name], cur.fraction <= c.fraction { continue }
            out[name] = c
        }
        return out
    }
}
