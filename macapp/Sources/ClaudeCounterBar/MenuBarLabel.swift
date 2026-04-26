import SwiftUI
import ClaudeCounterCore

/// The view that renders into the system menu bar. F3-style:
/// 8-bar sparkline of today's last 8 hours + today's $ figure.
///
/// Lifecycle states:
/// - `.starting` / `.scanning` (with no live data yet) → flat placeholder
///   bars + `$0.00`, dim text, soft pulse on the bars.
/// - `.live` → real sparkline + real `$today`.
/// - `.noProjectsRoot` → a dash so the user knows there's no data path.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    private var isLoading: Bool {
        switch state.status {
        case .starting:           return true
        case .scanning:           return todayUSD() == 0
        case .live, .noProjectsRoot: return false
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            SparkBars(
                values: lastEightHours(of: state.totals.todayHourlyUSD),
                pulsing: isLoading
            )
            // Important: explicit absolute size. MenuBarExtra hands
            // unreliable bounds to GeometryReader, so SparkBars below
            // draws at fixed pixel sizes and we just frame it here.
            .frame(width: 28, height: 14)

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

/// Tiny vertical-bar sparkline drawn with `Canvas`.
///
/// Why Canvas instead of SwiftUI shapes inside a GeometryReader: a
/// `MenuBarExtra` label is rendered into the system menu bar, where
/// SwiftUI hands GeometryReader children unreliable bounds (often
/// 0×0 on first paint). That's why the sparkline was invisible in the
/// previous build. Canvas gets explicit pixel-space drawing routines
/// that the menu bar host renders correctly.
struct SparkBars: View {
    let values: [Double]
    var pulsing: Bool = false

    @State private var pulseOpacity: Double = 0.85

    private let barCount: Int = 8
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 1
    private let barCorner: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            let maxV = max(values.max() ?? 0, 0.0001)
            let totalW = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
            let xOffset = max(0, (size.width - totalW) / 2)
            let h = size.height

            // Take the last `barCount` values; pad with zero on the left
            // so the sparkline grows right-to-left as the day fills in.
            var slice = values
            if slice.count < barCount {
                slice = Array(repeating: 0, count: barCount - slice.count) + slice
            } else if slice.count > barCount {
                slice = Array(slice.suffix(barCount))
            }

            let opacity = pulsing ? pulseOpacity : 0.85
            let color = Color.green.opacity(opacity)

            for i in 0..<barCount {
                let v = slice[i]
                let barH = max(2, CGFloat(v / maxV) * h)
                let x = xOffset + CGFloat(i) * (barWidth + barSpacing)
                let rect = CGRect(x: x, y: h - barH, width: barWidth, height: barH)
                let path = Path(roundedRect: rect, cornerRadius: barCorner)
                context.fill(path, with: .color(color))
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
        // shouting. Mirrors the loading idiom used by Time Machine.
        pulseOpacity = 0.55
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
