import Foundation

/// One model's share of a single chart bar, as rendered by the hover
/// popups. `value` is dollars on the two spend charts and tokens on the
/// token chart — deliberately unit-free, since the ordering rules below
/// are the same either way and the view supplies the formatter.
public struct BreakdownRow: Equatable, Sendable {
    public let model: String
    public let value: Double

    public init(model: String, value: Double) {
        self.model = model
        self.value = value
    }
}

/// Turns one bar's per-model map into the ordered rows its hover popup
/// renders, plus how many were hidden by `limit`. Shared by all three
/// charts: hourly spend, 30-day spend, and 30-day tokens.
///
/// Token maps are `UInt64` at the call site and converted to `Double`
/// here. That is exact for any real figure — a day's tokens run to
/// ~1e10, far inside Double's 2^53 exact-integer range — and it lets one
/// tested ordering rule serve both units instead of two near-copies.
///
/// This lives in Core rather than beside the view it serves because the
/// test target depends on `ClaudeCounterCore` only — `ClaudeCounterBar`
/// has no test path (see the note atop `ModelPaletteTests`). Keeping the
/// ordering and capping rules here is what makes them testable at all;
/// the view is left with nothing but layout.
///
/// Rules, each with a reason:
///
/// - **Non-positive entries are dropped.** A model can appear in an
///   hour's map having cost nothing — an all-cached turn, or a costed
///   vendor reporting zero — and a `$0.00` row is noise in a panel this
///   small. Negatives cannot occur today but are dropped rather than
///   rendered, since a negative dollar figure would be a wrong number.
/// - **Sorted by spend, descending.** The popup answers "what drove this
///   hour", so the largest contributor leads.
/// - **Ties break on model name.** Dictionary iteration order is not
///   stable between renders; without a deterministic tiebreak the rows
///   would visibly reshuffle while the pointer sits still on one bar.
/// - **`overflow` counts only rows that survived the zero filter**, so
///   "+N more" never promises spend that isn't there.
///
/// An hour with no positive spend yields no rows at all, which the view
/// reads as "show no popup" rather than drawing an empty panel.
public func breakdownRows(
    from byModel: [String: Double],
    limit: Int
) -> (rows: [BreakdownRow], overflow: Int) {
    // Built in explicit steps rather than one chained expression: the
    // Swift type-checker times out on the fused filter/map/sort over a
    // dictionary here.
    var spending: [BreakdownRow] = []
    spending.reserveCapacity(byModel.count)
    for (model, value) in byModel where value > 0 {
        spending.append(BreakdownRow(model: model, value: value))
    }
    spending.sort { lhs, rhs in
        if lhs.value == rhs.value { return lhs.model < rhs.model }
        return lhs.value > rhs.value
    }

    guard limit > 0 else { return ([], spending.count) }
    guard spending.count > limit else { return (spending, 0) }
    return (Array(spending.prefix(limit)), spending.count - limit)
}
