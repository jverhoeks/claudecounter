import SwiftUI
import AppKit
import ClaudeCounterCore  // (no direct symbol use yet, but keeps imports parallel)

/// The app's Dock icon, rendered at runtime from SwiftUI.
///
/// The bundle ships without an `.icns` file because macOS would
/// otherwise need one PNG per resolution baked in at build time.
/// Rendering at runtime means we change the design in code and both
/// the bundle and the live Dock pick it up next launch.
///
/// Design (after iterating from "white register on Claude orange"
/// because that read muddy at small dock zooms — see CHANGELOG):
///
/// - **White squircle**, inset to ~80% of the icon canvas. macOS HIG
///   says app artwork should occupy ~824×824 inside a 1024×1024 sheet
///   (the rest is breathing room so adjacent icons don't visually
///   collide). Earlier versions filled the full canvas, which made
///   the icon look noticeably wider than its dock neighbours.
/// - **Orange dollar bill** centred in the lower portion of the
///   canvas, so the top-right corner stays clean for the system-
///   drawn red `$X` spend badge.
/// - The bill is a horizontal rounded rectangle (typical 5.5:3 bill
///   aspect ratio) with a thin inner border (the classic bill's
///   inner frame) and a bold white `$` glyph at its centre.
///
/// Menu-bar surface continues to use `ClaudeRegisterShape` — the
/// register silhouette reads better at 13pt than a $-sign would.
struct AppIconView: View {

    /// The icon's edge length in SwiftUI points. The bitmap will be
    /// 2× this in pixels (retina), matching what the Dock asks for.
    let size: CGFloat

    var body: some View {
        ZStack {
            // Full-canvas transparent backing so the dock tile knows
            // its bounds; the visible squircle is inset so the icon
            // sits at the same visual size as the macOS HIG default.
            Color.clear

            RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                .fill(Color.white)
                // Subtle drop shadow so the white squircle still
                // reads against light wallpapers (the dock's
                // translucency lets the wallpaper bleed through).
                .shadow(color: Color.black.opacity(0.10),
                        radius: size * 0.012,
                        x: 0,
                        y: size * 0.006)
                .frame(width: size * 0.80, height: size * 0.80)

            // The dollar bill, sized to ~50% of canvas width and
            // shifted slightly downward so the system-drawn spend
            // badge has uncluttered space in the top-right corner.
            DollarBillSymbol(size: size * 0.50)
                .offset(y: size * 0.06)
        }
        .frame(width: size, height: size)
    }
}

/// A stylised dollar bill: orange rounded rectangle with a thin inner
/// border and a centred bold `$` sign. Sized by its width; height
/// follows the conventional ~5.5:3 bill aspect ratio so it reads as
/// "money" rather than "small card."
struct DollarBillSymbol: View {

    /// Width in points. Height is derived from the bill aspect ratio.
    let size: CGFloat

    private var height: CGFloat { size * 0.56 }

    /// Claude brand orange, slightly more saturated than the menu-bar
    /// asterisk shade so the bill pops on white.
    private static let billOrange = Color(red: 0.91, green: 0.49, blue: 0.27)

    var body: some View {
        ZStack {
            // Bill body — solid orange rounded rectangle.
            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Self.billOrange)

            // Inner decorative border (the classic bill frame). Thin
            // white stroke at ~55% opacity so it reads as detail
            // rather than a hard outline.
            RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55),
                              lineWidth: max(1, size * 0.012))
                .padding(size * 0.04)

            // Centred `$`. Rounded design weight so the glyph matches
            // the bill's soft corners; sized at 42% of the bill width
            // for clear readability at dock zoom levels.
            Text("$")
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: size, height: height)
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
