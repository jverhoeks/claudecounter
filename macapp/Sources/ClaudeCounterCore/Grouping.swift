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
}
