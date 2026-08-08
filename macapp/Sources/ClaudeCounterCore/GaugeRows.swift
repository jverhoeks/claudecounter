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
    /// ForEach misbehaves. It holds because a vendor contributes at most
    /// one row per distinct window label, and labels are derived from
    /// distinct window_minutes values.
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
}
