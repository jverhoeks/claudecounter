import SwiftUI
import ClaudeCounterCore

/// The view that renders into the system menu bar. F3-style:
/// 8-bar sparkline of today's last 8 hours + today's $ figure.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 6) {
            SparkBars(values: lastEightHours(of: state.totals.todayHourlyUSD))
                .frame(width: 24, height: 12)
            Text(formatUSDCompact(todayUSD()))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
        }
    }

    private func todayUSD() -> Double {
        state.totals.day.values.reduce(0) { $0 + $1.usd }
    }

    private func lastEightHours(of hourly: [Double]) -> [Double] {
        guard hourly.count == 24 else { return Array(repeating: 0, count: 8) }
        let nowHour = Calendar.current.component(.hour, from: Date())
        let start = max(0, nowHour - 7)
        return Array(hourly[start...min(start + 7, 23)])
    }
}

/// Tiny vertical-bar sparkline. Heights normalised to the max value
/// in the slice; an all-zero slice draws as flat baseline bars.
struct SparkBars: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 0.0001)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green.opacity(0.85))
                        .frame(height: max(2, CGFloat(v / maxV) * geo.size.height))
                }
            }
        }
    }
}

/// Tight currency formatter for the menu bar.
func formatUSDCompact(_ usd: Double) -> String {
    if usd >= 1000 {
        return String(format: "$%.0f", usd)
    }
    if usd >= 100 {
        return String(format: "$%.1f", usd)
    }
    return String(format: "$%.2f", usd)
}
