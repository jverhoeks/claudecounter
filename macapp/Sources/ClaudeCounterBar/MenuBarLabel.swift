import SwiftUI
import ClaudeCounterCore

/// The view that renders into the system menu bar. F3-style:
/// 8-bar sparkline of today's last 8 hours + today's $ figure.
///
/// Lifecycle states:
/// - `.starting` / `.scanning` (with no live data yet) → show a flat
///   placeholder sparkline + `$0.00` so the label always renders
///   *something* from the moment the SwiftUI scene mounts. Subtle
///   pulse animation telegraphs "doing work".
/// - `.live` → real sparkline + real `$today`.
/// - `.noProjectsRoot` → a dash so the user knows there's no data path.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    /// `true` while the pipeline hasn't produced any usable totals yet.
    /// We treat both `.starting` and `.scanning` (with $0 totals) as
    /// loading so the UI doesn't promise live numbers prematurely.
    private var isLoading: Bool {
        switch state.status {
        case .starting:           return true
        case .scanning:           return todayUSD() == 0
        case .live, .noProjectsRoot: return false
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            SparkBars(
                values: lastEightHours(of: state.totals.todayHourlyUSD),
                pulsing: isLoading
            )
            .frame(width: 24, height: 12)

            Text(labelText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isLoading ? .secondary : .primary)
        }
        .animation(.easeInOut(duration: 0.25), value: isLoading)
        .animation(.easeInOut(duration: 0.25), value: todayUSD())
    }

    private var labelText: String {
        if case .noProjectsRoot = state.status { return "—" }
        // During loading the formatter still produces "$0.00" (the
        // truthful starting value); once `.live` arrives the same path
        // animates over to the real number without a flicker.
        return formatUSDCompact(todayUSD())
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
/// in the slice; an all-zero slice draws as flat baseline bars. When
/// `pulsing` is true (loading state) the bars dim and pulse softly so
/// the label clearly reads as "still working" instead of "just $0".
struct SparkBars: View {
    let values: [Double]
    var pulsing: Bool = false

    @State private var pulseOpacity: Double = 0.55

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 0.0001)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green.opacity(pulsing ? pulseOpacity : 0.85))
                        .frame(height: max(2, CGFloat(v / maxV) * geo.size.height))
                }
            }
        }
        .onAppear {
            if pulsing { startPulse() }
        }
        .onChange(of: pulsing) { isPulsing in
            if isPulsing { startPulse() } else { pulseOpacity = 0.85 }
        }
    }

    private func startPulse() {
        // Soft fade between 0.30 and 0.55 — visible motion without
        // shouting. Mirrors the menu bar idiom used by Time Machine /
        // Bartender's loading hints.
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.30
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
