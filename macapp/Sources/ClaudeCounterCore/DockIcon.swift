import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Controls whether the app shows up in the macOS Dock and what badge
/// (if any) is stamped over it.
///
/// The bundle ships with `LSUIElement = YES`, so the app boots as a
/// menu-bar accessory and the Dock is empty. Flipping the icon ON at
/// runtime calls `NSApp.setActivationPolicy(.regular)`; flipping it
/// OFF goes back to `.accessory`. The badge is the small red overlay
/// drawn on top of the dock icon — we use it to show today's spend.
///
/// All calls touch `NSApp`, which is `@MainActor`-bound — hence the
/// `@MainActor` annotation on the protocol. Tests inject the in-memory
/// double; production wires up `NSAppDockIconController`.
@MainActor
public protocol DockIconController: AnyObject {
    /// Show or hide the Dock icon.
    func setVisible(_ visible: Bool)
    /// Stamp the red badge overlay. Pass `nil` to clear. No-op when the
    /// icon is hidden (the badge would be invisible anyway).
    func setBadge(_ text: String?)
    /// Mirrors the most recent `setVisible` call.
    var isVisible: Bool { get }
}

/// Production implementation, backed by `NSApp`.
@MainActor
public final class NSAppDockIconController: DockIconController {

    public init() {}

    public private(set) var isVisible: Bool = false

    public func setVisible(_ visible: Bool) {
        #if canImport(AppKit)
        // `NSApp` is an implicitly-unwrapped global that's only set
        // after `NSApplication.shared` has been touched once. In a test
        // runner (`xctest`) it can be nil — referencing it crashes the
        // process. Using `NSApplication.shared` directly forces
        // initialisation and is safe in every context.
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        app.setActivationPolicy(policy)
        // Clear any stale badge when the icon is going away — otherwise
        // the next `setVisible(true)` would briefly show the previous
        // value before the next snapshot comes in.
        if !visible {
            app.dockTile.badgeLabel = nil
        }
        #endif
        isVisible = visible
    }

    public func setBadge(_ text: String?) {
        #if canImport(AppKit)
        // Skip the syscall when the icon is hidden — `dockTile.badgeLabel`
        // is harmless in that state but we'd rather avoid waking up the
        // dock for a UI affordance the user can't see.
        guard isVisible else { return }
        NSApplication.shared.dockTile.badgeLabel = text
        #endif
    }
}

// MARK: - Badge formatters

/// Compact USD formatter for the popover tables (by-model, by-project,
/// monthly summary). Dropping precision as the number grows keeps each
/// row tight without losing the order-of-magnitude on small values:
///
///   $0.00 … $99.99    → "$%.2f"  ($12.34)
///   $100   … $999.9   → "$%.1f"  ($123.4)
///   $1000+            → "$%.0f"  ($1234)
///
/// The at-a-glance shell surfaces (menu bar label + dock badge) use
/// `formatUSDWhole(_:)` instead — decimals are noisy at that size.
public func formatUSDCompact(_ usd: Double) -> String {
    if usd >= 1000 {
        return String(format: "$%.0f", usd)
    }
    if usd >= 100 {
        return String(format: "$%.1f", usd)
    }
    return String(format: "$%.2f", usd)
}

/// Whole-dollar formatter for the at-a-glance OS-shell surfaces — the
/// menu bar label next to the cash-register glyph, and the dock badge.
/// Both render at small sizes where decimals add visual noise without
/// the precision actually being readable; round to the nearest dollar.
///
///   $0.00 → "$0"
///   $0.49 → "$0"
///   $0.50 → "$0"   (printf %.0f banker's rounding: ties to even)
///   $1.50 → "$2"
///   $34.87 → "$35"
///   $1234.5 → "$1234"
public func formatUSDWhole(_ usd: Double) -> String {
    return String(format: "$%.0f", usd)
}

// MARK: - Test double

/// In-memory test double. Records every call so tests can assert that
/// AppState pushed the right badge text on each snapshot.
@MainActor
public final class InMemoryDockIconController: DockIconController {

    public private(set) var isVisible: Bool
    public private(set) var badge: String?
    public private(set) var setVisibleCalls: [Bool] = []
    public private(set) var setBadgeCalls: [String?] = []

    public init(initiallyVisible: Bool = false) {
        self.isVisible = initiallyVisible
        self.badge = nil
    }

    public func setVisible(_ visible: Bool) {
        setVisibleCalls.append(visible)
        isVisible = visible
        if !visible { badge = nil }
    }

    public func setBadge(_ text: String?) {
        setBadgeCalls.append(text)
        // Mirror production semantics: badge writes are a no-op when
        // the icon is hidden. Tests that want to assert "we tried to
        // set the badge" can still inspect setBadgeCalls.
        guard isVisible else { return }
        badge = text
    }
}
