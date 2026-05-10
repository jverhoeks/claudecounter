import SwiftUI
import ClaudeCounterCore

/// Stable per-model colour mapping so the same model is the same colour
/// across both monthly charts (cost + tokens) AND the "By model · month"
/// table — that way the table doubles as a colour legend and the user
/// doesn't need a separate key.
///
/// Construction rules:
/// - Order is determined ONCE per snapshot from the month-USD ranking
///   (largest spender first). This stays stable for the day even if a
///   single day has a different model dominating — keeps the colour-
///   to-model association predictable as the user scans the chart.
/// - Models that haven't produced spend this month but show up in the
///   30-day window (e.g. an old model used early in the period and
///   then dropped) get appended after the month-active set, in
///   alphabetical order.
/// - Up to 8 distinct colours; anything beyond that wraps. The user
///   only ever sees 3-4 active models in practice, so wrap-around
///   collisions are theoretical.
struct ModelPalette {

    /// Eight perceptually-distinct hues from SwiftUI's system colours
    /// (so light/dark mode adapts automatically). Ordered for visual
    /// hierarchy: green for the dominant model gives the cost chart
    /// a "money" feel; blue/orange/purple/etc. for the rest.
    static let colours: [Color] = [
        .green,    // 0 — top spender (typically opus)
        .blue,     // 1 — secondary (typically sonnet)
        .orange,   // 2 — tertiary (typically haiku)
        .purple,   // 3
        .pink,     // 4
        .yellow,   // 5
        .cyan,     // 6
        .red,      // 7
    ]

    /// Final model→colour-index map. Computed once per snapshot.
    let indexByModel: [String: Int]
    /// Model order used for stacking (smallest index = bottom of stack).
    /// Matches the order seen in the table.
    let order: [String]

    init(monthUSD: [String: ModelDay], dailyWindow: [DailyTotal]) {
        // 1) Models with month USD, sorted high→low.
        let monthRanked = monthUSD
            .map { (name: $0.key, usd: $0.value.usd) }
            .sorted { $0.usd > $1.usd }
            .map(\.name)

        // 2) Plus any model that appears in the 30-day window but has
        //    no month-USD entry (different month, unpriced, …).
        let monthSet = Set(monthRanked)
        var extras = Set<String>()
        for d in dailyWindow {
            for m in d.usdByModel.keys where !monthSet.contains(m) { extras.insert(m) }
            for m in d.tokensByModel.keys where !monthSet.contains(m) { extras.insert(m) }
        }
        let extrasOrdered = extras.sorted()  // alphabetical for stable order

        let combined = monthRanked + extrasOrdered
        self.order = combined
        var map: [String: Int] = [:]
        for (i, m) in combined.enumerated() { map[m] = i }
        self.indexByModel = map
    }

    /// Colour for `model`. Falls back to `Color.gray` for models that
    /// weren't seen at construction time (defensive — shouldn't happen
    /// because we build from the snapshot itself).
    func colour(for model: String) -> Color {
        guard let idx = indexByModel[model] else { return .gray }
        return Self.colours[idx % Self.colours.count]
    }
}
