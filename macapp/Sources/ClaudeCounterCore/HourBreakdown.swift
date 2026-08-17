import Foundation

/// One model's spend within a single hour, as rendered by the hourly
/// chart's hover popup.
public struct HourBreakdownRow: Equatable, Sendable {
    public let model: String
    public let usd: Double

    public init(model: String, usd: Double) {
        self.model = model
        self.usd = usd
    }
}

/// Turns one hour's per-model USD map into the ordered rows the hourly
/// chart's hover popup renders, plus how many were hidden by `limit`.
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
public func hourBreakdownRows(
    from byModel: [String: Double],
    limit: Int
) -> (rows: [HourBreakdownRow], overflow: Int) {
    // Built in explicit steps rather than one chained expression: the
    // Swift type-checker times out on the fused filter/map/sort over a
    // dictionary here.
    var spending: [HourBreakdownRow] = []
    spending.reserveCapacity(byModel.count)
    for (model, usd) in byModel where usd > 0 {
        spending.append(HourBreakdownRow(model: model, usd: usd))
    }
    spending.sort { lhs, rhs in
        if lhs.usd == rhs.usd { return lhs.model < rhs.model }
        return lhs.usd > rhs.usd
    }

    guard limit > 0 else { return ([], spending.count) }
    guard spending.count > limit else { return (spending, 0) }
    return (Array(spending.prefix(limit)), spending.count - limit)
}
