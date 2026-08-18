import Foundation

/// Selects the time window the per-model list totals over. Orthogonal to
/// `GroupMode`: that picks which axis series collapse onto, this picks
/// how much history feeds them. Both are pure display state — every
/// period reads the same underlying cells.
public enum PeriodMode: String, Equatable, Sendable, CaseIterable {
    case day
    case week
    case month

    /// The period's own display name, used in the table header
    /// ("By model · week").
    public var label: String { rawValue }

    /// Segmented-control title.
    public var buttonLabel: String {
        switch self {
        case .day:   return "Day"
        case .week:  return "Week"
        case .month: return "Month"
        }
    }

    /// Trailing half of the empty-state line ("No spend yet " + this),
    /// so an empty day doesn't read as an empty month.
    public var emptyPhrase: String {
        switch self {
        case .day:   return "today"
        case .week:  return "this week"
        case .month: return "this month"
        }
    }
}
