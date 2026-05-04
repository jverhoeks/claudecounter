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
/// We go through `cgImage` rather than `nsImage` and wrap manually:
/// `ImageRenderer.nsImage` has been reported to silently return nil in
/// some hosting contexts (menu-bar accessory at launch, no foreground
/// window). `cgImage` is more reliable, and once we have it we can
/// build the `NSImage` ourselves with the logical size we want.
///
/// Rendered at 512pt @2× so the bitmap is 1024×1024 — enough for the
/// Dock's 128pt @2× retina worst case (256 actual pixels).
@MainActor
func renderAppIcon(edgeLength: CGFloat = 512) -> NSImage? {
    let renderer = ImageRenderer(content: AppIconView(size: edgeLength))
    renderer.scale = 2.0
    guard let cgImage = renderer.cgImage else { return nil }
    return NSImage(
        cgImage: cgImage,
        size: CGSize(width: edgeLength, height: edgeLength)
    )
}

/// Build an `NSHostingView` that renders `AppIconView` directly as the
/// Dock tile's content view.
///
/// Why prefer this over `NSApp.applicationIconImage`:
/// - The Dock draws an `NSView` natively, no bitmap snapshot — so we
///   skip `ImageRenderer.nsImage`'s "returns nil sometimes" failure
///   mode entirely
/// - SwiftUI redraws the view live on `dockTile.display()`, so the
///   icon stays crisp at every dock zoom level
/// - The badge (`dockTile.badgeLabel`) sits on top of the contentView
///   independently — no interference between artwork and badge
@MainActor
func makeDockTileHostingView(edgeLength: CGFloat = 128) -> NSView {
    let hosting = NSHostingView(rootView: AppIconView(size: edgeLength))
    hosting.frame = NSRect(x: 0, y: 0, width: edgeLength, height: edgeLength)
    return hosting
}
