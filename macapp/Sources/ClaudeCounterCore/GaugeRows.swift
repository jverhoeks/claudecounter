import Foundation

/// Groups rows by rough duration. A band title is NOT an assertion that
/// its rows share a window definition — the weekly band holds an ISO
/// week, Codex's 7-day rolling window and Grok's Thursday-anchored
/// billing period. Every row therefore renders its own window label.
public enum GaugeBand: Sendable {
    case short, weekly
    public var title: String { self == .short ? "short window" : "weekly" }
}

public struct GaugeRow: Equatable, Sendable, Identifiable {
    public var vendor: String
    public var windowLabel: String
    public var budget: LimitStatus?
    public var plan: PlanGauge?
    public var notApplicable: String?

    /// SwiftUI requires this to be unique within a rendered band, or
    /// ForEach misbehaves. This is NOT derived from `PlanGauge`'s raw
    /// `window_minutes` — that value doesn't survive past `PlanLimits`'
    /// scan, only its rendered `windowLabel` does, and
    /// `PlanLimits.windowLabel(minutes:)` is lossy (integer division):
    /// 300 and 301 both render "5h", 10080 and 11000 both render "7d".
    /// This id only holds today because the two vendors we scan never
    /// report two windows whose *rendered* labels collide: Codex's own
    /// two slots are 300min ("5h") and 10080min ("7d") — far enough
    /// apart that the lossy rendering doesn't matter — and Grok
    /// contributes at most one row ("wk"). A vendor reporting two windows
    /// that render to the same label would break this.
    public var id: String { vendor + "/" + windowLabel }

    /// The percentage this row displays, whatever its source.
    public var pct: Double { budget?.pct ?? plan?.pct ?? 0 }
    public var isStale: Bool { plan?.stale ?? false }
}

/// Mirrors `tui/internal/ui.BuildRows` / `WorstPct` exactly (see
/// gauges.go) so the popover and the TUI never disagree about row order
/// or which row is worst.
public enum GaugeRows {

    /// Fixed vendor order within every band, matching Go's displayOrder.
    private static let displayOrder = ["claude", "codex", "grok"]

    public static func build(band: GaugeBand,
                             statuses: [LimitStatus],
                             gauges: [PlanGauge]) -> [GaugeRow] {
        let installed = Set(gauges.map(\.vendor))
        var rows: [GaugeRow] = []

        for vendor in displayOrder {
            if vendor == "claude" {
                let want: LimitWindow = band == .weekly ? .week : .day
                if let s = statuses.first(where: { $0.window == want && $0.state != .unset }) {
                    rows.append(GaugeRow(vendor: "claude", windowLabel: s.window.label,
                                         budget: s, plan: nil, notApplicable: nil))
                }
                continue
            }
            guard installed.contains(vendor) else { continue }

            let matches = gauges.filter { $0.vendor == vendor && bandOf($0) == band }
            if matches.isEmpty {
                rows.append(GaugeRow(vendor: vendor, windowLabel: "—", budget: nil, plan: nil,
                                     notApplicable: band == .short ? "weekly only" : "no weekly window"))
            } else {
                rows.append(contentsOf: matches.map {
                    GaugeRow(vendor: vendor, windowLabel: $0.windowLabel,
                             budget: nil, plan: $0, notApplicable: nil)
                })
            }
        }
        return rows
    }

    private static func bandOf(_ g: PlanGauge) -> GaugeBand {
        g.windowLabel.hasSuffix("h") ? .short : .weekly
    }

    /// Highest utilisation across every non-stale row. Drives menu bar
    /// escalation — deliberately a different ordering from displayOrder.
    public static func worstPct(statuses: [LimitStatus], gauges: [PlanGauge]) -> Double {
        var worst = 0.0
        for s in statuses where s.state != .unset { worst = max(worst, s.pct) }
        for g in gauges where !g.stale { worst = max(worst, g.pct) }
        return worst
    }

    // MARK: - Tint

    /// The warn/over/stale colour category a row renders as. Mirrors
    /// Go's stateColor/pctColor split in gauges.go: a budget row's tint
    /// comes from `LimitStatus.state` (see `budgetTint`), a plan row's
    /// from re-deriving against `warnPct` (see `planTint`) — `.stale`
    /// has no Go analog there since the TUI handles plan staleness as an
    /// early return in `renderPlanRow`, not a colour category, but the
    /// popover needs one value covering every row `GaugeRowView` draws.
    public enum Tint: Equatable, Sendable {
        case ok, warn, over, stale
    }

    /// A budget row's tint, read directly off the engine's `LimitState`
    /// — the verdict `Limits.evaluate` already computed against the
    /// configured `warnPct` — never by re-comparing `pct` against a
    /// threshold here. Mirrors Go's `stateColor`.
    public static func budgetTint(_ state: LimitState) -> Tint {
        switch state {
        case .over: return .over
        case .warn: return .warn
        case .ok, .unset: return .ok
        }
    }

    /// A plan gauge carries no `LimitState` (see `PlanGauge`), so it
    /// re-derives tint against `warnPct` directly. Applying the user's
    /// configured threshold to a plan row is a deliberate display
    /// convention, not a second engine — but it is what keeps a plan
    /// row's colour meaning the same threshold a budget row's State was
    /// computed against. Mirrors Go's `pctColor`. The over threshold
    /// (100) is never configurable.
    public static func planTint(pct: Double, warnPct: Int) -> Tint {
        if pct >= 100 { return .over }
        if pct >= Double(warnPct) { return .warn }
        return .ok
    }

    /// The tint for one row, combining staleness, budget state and plan
    /// pct into the single decision `GaugeRowView` renders.
    public static func tint(for row: GaugeRow, warnPct: Int) -> Tint {
        if row.isStale { return .stale }
        if let budget = row.budget { return budgetTint(budget.state) }
        return planTint(pct: row.pct, warnPct: warnPct)
    }
}
