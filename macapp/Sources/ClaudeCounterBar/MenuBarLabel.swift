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

/// Custom cash-register glyph for the menu bar, drawn as a SwiftUI
/// `Shape` so it renders crisp at any pixel density and inherits the
/// menu bar's foreground color (no template-image dance needed).
///
/// macOS 13's SF Symbols 4 doesn't ship a literal cash-register glyph
/// and `banknote.fill` was just a banknote, not a register. We hand-
/// draw the classic register silhouette: a wider drawer body at the
/// bottom, a narrower display housing on top, and — Claude-inspired —
/// a 6-petal asterisk cut out of the display via even-odd fill, so
/// the register looks like it's "running Claude" on its little screen.
///
/// Pulses softly while the initial scan runs, snaps to solid once we
/// transition to `.live`. Same animation curve as the old sparkline
/// pulse so the loading idiom is consistent.
struct CashRegisterGlyph: View {
    var pulsing: Bool = false

    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        ClaudeRegisterShape()
            .fill(.foreground, style: FillStyle(eoFill: true))
            .opacity(pulseOpacity)
            .frame(width: 14, height: 13)
            .onAppear {
                if pulsing { startPulse() } else { pulseOpacity = 1.0 }
            }
            .onChange(of: pulsing) { isPulsing in
                if isPulsing { startPulse() } else { pulseOpacity = 1.0 }
            }
    }

    private func startPulse() {
        // Gentle fade between 0.45 and 0.85 — visible motion without
        // shouting. Same curve we used for the sparkline pulse.
        pulseOpacity = 0.85
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.45
        }
    }
}

/// Cash-register silhouette with a Claude-inspired 6-petal asterisk
/// cutout in the display housing. Designed to read at ~14pt in the
/// menu bar; uses `FillStyle(eoFill: true)` so the asterisk petals
/// punch through the display rectangle as background-color cutouts.
///
/// Layout (origin top-left, normalised to the rect's bounds):
///
///        ┌───────┐    ← display housing (top 0.45 .. body top)
///        │  ✱    │      with the Claude asterisk cut out of it
///        └───────┘
///       ┌─────────┐  ← drawer body (top 0.50 .. bottom)
///       │         │
///       └─────────┘
struct ClaudeRegisterShape: Shape {

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        // Drawer / cabinet — wider rectangle at the bottom of the icon.
        let bodyTopY = h * 0.50
        let body = CGRect(
            x: 0,
            y: bodyTopY,
            width: w,
            height: h - bodyTopY
        )
        path.addRoundedRect(in: body, cornerSize: CGSize(width: 1.5, height: 1.5))

        // Display / keypad housing — narrower rectangle on top of the
        // drawer. Slight overlap (1pt) so the two shapes read as one
        // stepped silhouette rather than two stacked boxes.
        let dispW = w * 0.72
        let dispX = (w - dispW) / 2
        let dispY = h * 0.10
        let dispH = (bodyTopY + 1) - dispY
        let display = CGRect(x: dispX, y: dispY, width: dispW, height: dispH)
        path.addRoundedRect(in: display, cornerSize: CGSize(width: 0.9, height: 0.9))

        // Claude asterisk — 6 petals radiating from the centre of the
        // display housing. Added to the SAME path; combined with
        // even-odd fill, the petals subtract from the display, giving
        // a "screen-printed Claude logo" look.
        let asterCx = dispX + dispW / 2
        let asterCy = dispY + dispH / 2
        // Sized so all 6 petals stay inside the display housing with
        // a hair of margin. Tweak `petalLen` to taste.
        let petalLen = min(dispW, dispH) * 0.42
        let petalWid = max(0.55, petalLen * 0.30)

        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            // The base petal: a tiny rounded rect that starts at the
            // origin and extends `petalLen` units along +x. After the
            // affine (rotate + translate) it points outward from the
            // asterisk centre.
            let petalRect = CGRect(
                x: 0,
                y: -petalWid / 2,
                width: petalLen,
                height: petalWid
            )
            let transform = CGAffineTransform.identity
                .translatedBy(x: asterCx, y: asterCy)
                .rotated(by: angle)
            path.addRoundedRect(
                in: petalRect,
                cornerSize: CGSize(width: petalWid / 2, height: petalWid / 2),
                transform: transform
            )
        }

        return path
    }
}

// `formatUSDCompact(_:)` and `formatUSDWhole(_:)` live in
// ClaudeCounterCore — see DockIcon.swift. The dock badge and the menu
// bar label both call `formatUSDWhole(_:)` so the two shell surfaces
// always render the same number for the same value.
