import SwiftUI
import ClaudeCounterCore

/// The popover's gauge block. Shows the same two bands, the same rows and
/// the same detail column as the TUI — a budget row shows $spent/$limit,
/// a plan row shows its reset time — so the two surfaces read alike.
struct GaugesView: View {
    let statuses: [LimitStatus]
    let gauges: [PlanGauge]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([GaugeBand.short, GaugeBand.weekly], id: \.title) { band in
                let rows = GaugeRows.build(band: band, statuses: statuses, gauges: gauges)
                if !rows.isEmpty {
                    Text(band.title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GaugeRowView(row: row)
                    }
                }
            }
        }
    }
}

private struct GaugeRowView: View {
    let row: GaugeRow

    var body: some View {
        HStack(spacing: 6) {
            Text(row.vendor).font(.system(size: 11)).frame(width: 48, alignment: .leading)
            // The window label is always shown, including on budget rows:
            // "daily" beside "5h" makes clear they are different windows.
            Text(row.windowLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            if let reason = row.notApplicable {
                Text("n/a (\(reason))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
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
        }
        .opacity(row.isStale ? 0.45 : 1)
    }

    private var tint: Color {
        if row.isStale { return .gray }
        if row.pct >= 100 { return .red }
        if row.pct >= Double(LimitsConfig.defaultWarnPct) { return .orange }
        return .green
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
