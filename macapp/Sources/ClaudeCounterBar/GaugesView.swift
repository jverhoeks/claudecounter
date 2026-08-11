import SwiftUI
import ClaudeCounterCore

/// The popover's gauge block. Shows the same two bands, the same rows and
/// the same detail column as the TUI — a budget row shows $spent/$limit,
/// a plan row shows its reset time — so the two surfaces read alike.
struct GaugesView: View {
    let statuses: [LimitStatus]
    let gauges: [PlanGauge]
    /// The user's configured amber threshold (`LimitsConfig.warnPct`,
    /// itself `LimitsConfig.defaultWarnPct` when unconfigured). Required,
    /// not defaulted — see `GaugeRows.tint`'s doc for why a plan row
    /// needs this plumbed through rather than falling back silently.
    let warnPct: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([GaugeBand.short, GaugeBand.weekly], id: \.title) { band in
                let rows = GaugeRows.build(band: band, statuses: statuses, gauges: gauges)
                if !rows.isEmpty {
                    Text(band.title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GaugeRowView(row: row, warnPct: warnPct)
                    }
                }
            }
        }
    }
}

private struct GaugeRowView: View {
    let row: GaugeRow
    let warnPct: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(row.vendor).font(.system(size: 11)).frame(width: 48, alignment: .leading)
            // The window label is always shown, including on budget rows:
            // "daily" beside "5h" makes clear they are different windows.
            Text(row.windowLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            ProgressView(value: min(row.pct, 100), total: 100)
                .progressViewStyle(.linear)
                .tint(tint)
                .frame(width: 90)
            Text(String(format: "%.0f%%", row.pct))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .opacity(row.isStale ? 0.45 : 1)
    }

    // Colour category comes from GaugeRows.tint — a budget row's from its
    // engine-computed LimitState, a plan row's from re-deriving against
    // warnPct — never from comparing row.pct against a hardcoded 80 here.
    private var tint: Color {
        switch GaugeRows.tint(for: row, warnPct: warnPct) {
        case .stale: return .gray
        case .over: return .red
        case .warn: return .orange
        case .ok: return .green
        }
    }

    private var detail: String {
        if let b = row.budget {
            // formatUSD is the app's existing currency formatter, defined
            // at PopoverView.swift:1055 in this same target.
            return "\(formatUSD(b.spentUSD))/\(formatUSD(b.limitUSD))"
        }
        if let p = row.plan {
            return p.stale ? "stale" : "↻ " + Self.reset.localizedString(for: p.resetsAt, relativeTo: Date())
        }
        return ""
    }

    private static let reset: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
