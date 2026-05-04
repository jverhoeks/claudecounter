import SwiftUI
import ClaudeCounterCore

/// The view that renders into the system menu bar.
///
/// Cash-register theme: a `banknote.fill` SF Symbol on the left, today's
/// running spend (whole dollars, no decimals) on the right.
///
/// Lifecycle states:
/// - `.starting` / `.scanning` (with no live data yet) → dim glyph,
///   `$0`, soft pulse on the icon to signal "working".
/// - `.live` → solid glyph + the real `$today` figure.
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
        HStack(spacing: 4) {
            CashRegisterGlyph(pulsing: isLoading)
                // Match the visual weight of the menu-bar text. SF
                // Symbols scale with `.imageScale(.medium)` and the
                // surrounding font; keeping them in the same HStack
                // gives macOS a single text baseline to align to.
                .font(.system(size: 13, weight: .semibold))

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
        return formatUSDWhole(todayUSD())
    }

    private func todayUSD() -> Double {
        state.totals.day.values.reduce(0) { $0 + $1.usd }
    }
}

/// The cash-register glyph for the menu bar. macOS 13 doesn't ship a
/// literal cash-register SF Symbol, so we use `banknote.fill` — a
/// stylised banknote that reads as "money/POS" at 12-14pt sizes and
/// renders monochrome in the menu bar by default.
///
/// Pulses softly while the initial scan runs, snaps to solid once we
/// transition to `.live`. Mirrors the loading idiom used by Time
/// Machine in the menu bar.
struct CashRegisterGlyph: View {
    var pulsing: Bool = false

    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        Image(systemName: "banknote.fill")
            .symbolRenderingMode(.monochrome)
            .opacity(pulseOpacity)
            .onAppear {
                if pulsing { startPulse() } else { pulseOpacity = 1.0 }
            }
            .onChange(of: pulsing) { isPulsing in
                if isPulsing { startPulse() } else { pulseOpacity = 1.0 }
            }
    }

    private func startPulse() {
        // Gentle fade between 0.45 and 0.85 — visible motion without
        // shouting. Same animation curve as the old sparkline pulse so
        // the loading idiom is consistent across the v1.3 → v1.3.1 jump.
        pulseOpacity = 0.85
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.45
        }
    }
}

// `formatUSDCompact(_:)` and `formatUSDWhole(_:)` live in
// ClaudeCounterCore — see DockIcon.swift. The dock badge and the menu
// bar label both call `formatUSDWhole(_:)` so the two shell surfaces
// always render the same number for the same value.
