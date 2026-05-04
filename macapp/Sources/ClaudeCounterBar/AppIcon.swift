import SwiftUI
import AppKit
import ClaudeCounterCore  // (no direct symbol use yet, but keeps imports parallel)

/// The app's Dock icon, rendered at runtime from SwiftUI.
///
/// The bundle ships without an `.icns` file because macOS would
/// otherwise need one PNG per resolution baked in at build time. By
/// re-using the same `ClaudeRegisterShape` we draw in the menu bar,
/// the Dock icon stays a single source of truth — change the shape
/// definition once and both surfaces follow.
///
/// Layout (all proportions normalised to the icon's edge length):
/// - Squircle background — Claude brand orange, with a subtle vertical
///   gradient so the icon doesn't read as a flat slab next to the
///   shaded macOS app icons surrounding it
/// - Cash register silhouette in white, sized at 55% of the squircle
///   so there's the conventional ~20% margin around the artwork that
///   Apple's HIG asks for
/// - The Claude 6-petal asterisk in `ClaudeRegisterShape` punches
///   through the white register via `FillStyle(eoFill: true)`,
///   revealing the orange beneath — the asterisk shows up "in Claude
///   orange on a white display" without us needing to render multiple
///   coloured layers.
struct AppIconView: View {

    /// The icon's edge length in SwiftUI points. The bitmap will be
    /// 2× this in pixels (retina), matching what the Dock asks for.
    let size: CGFloat

    var body: some View {
        ZStack {
            // Squircle background — Claude brand orange with a soft
            // vertical gradient.  Corner radius ≈22.5% of the side
            // length is the standard macOS Big Sur+ "squircle" ratio.
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.93, green: 0.55, blue: 0.40),  // top
                            Color(red: 0.78, green: 0.40, blue: 0.27),  // bottom
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Cash-register silhouette, white, with the Claude asterisk
            // cutouts revealing the orange squircle behind. Frame at
            // 55% of the icon side so we keep the HIG margin and the
            // register reads at small Dock zoom levels.
            ClaudeRegisterShape()
                .fill(Color.white, style: FillStyle(eoFill: true))
                .frame(width: size * 0.55, height: size * 0.55)
        }
        .frame(width: size, height: size)
    }
}

/// Render the app icon to an `NSImage` suitable for assigning to
/// `NSApp.applicationIconImage`.
///
/// We render at 512pt @2× so the produced bitmap is 1024×1024 — large
/// enough for the Dock's 128pt-zoomed-on-retina case (which asks for
/// 256px in each direction).  Returns `nil` if the renderer can't
/// produce a CGImage (shouldn't happen in practice, but `cgImage` is
/// optional so we return `nil` instead of crashing).
@MainActor
func renderAppIcon(edgeLength: CGFloat = 512) -> NSImage? {
    let renderer = ImageRenderer(content: AppIconView(size: edgeLength))
    renderer.scale = 2.0  // retina bitmap
    return renderer.nsImage
}
