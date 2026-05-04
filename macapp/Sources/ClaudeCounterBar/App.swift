import SwiftUI
import AppKit
import ClaudeCounterCore

// MARK: - App entry point

@main
struct ClaudeCounterBarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: delegate.appState)
                // Fixed width + bounded height. SwiftUI's MenuBarExtra
                // window opens at the size we declare here; without an
                // explicit height it grows to the natural content size,
                // and on shorter screens the top of the popover ends
                // up clipped behind the menu bar overlay (you'd see
                // the project list with the hero / chart pushed off
                // the visible area). Bounding to 620pt keeps the whole
                // dashboard (hero + hourly + monthly + tables + live
                // tail + footer) on a 13" laptop.
                .frame(width: 520, height: 620)
        } label: {
            MenuBarLabel(state: delegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState

    override init() {
        let projectsRoot = AppDelegate.defaultProjectsRoot()
        let cacheURL = (try? CacheStore.defaultURL())
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ccbar-cache.json")
        let pricing = PricingTable.resolveFromDisk()
        let agg = Aggregator(pricing: pricing)

        // Production wiring for the dock icon + persisted settings.
        // The dock controller takes both:
        //   - tileContentView: a SwiftUI `AppIconView` wrapped in
        //     NSHostingView; the Dock renders this directly, no bitmap
        //   - applicationIconImage: a precomputed NSImage backstop for
        //     code paths that read `NSApp.applicationIconImage`
        //     (About panel, system alerts, etc.)
        let dockTileView = makeDockTileHostingView(edgeLength: 128)
        let dockIconImage = renderAppIcon(edgeLength: 512)
        let dockIcon = NSAppDockIconController(
            tileContentView: dockTileView,
            applicationIconImage: dockIconImage
        )
        let settingsStore = UserDefaultsSettingsStore()
        self.appState = AppState(
            projectsRoot: projectsRoot,
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: pricing,
            dockIcon: dockIcon,
            settingsStore: settingsStore
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No icon-image juggling here — the dock controller installs
        // both the hosting view and the backstop image inside
        // `setVisible(true)` and forces a `dockTile.display()`. That
        // way, toggling the dock icon off and back on always reapplies
        // the artwork; macOS resets some dock-tile state when the
        // activation policy flips and a one-shot launch-time install
        // wouldn't survive that.
        Task { await appState.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Kick off the async cache flush. macOS gives the app a few
        // seconds to wind down before SIGKILL, which is enough for the
        // small JSON write. We do NOT block the main thread here —
        // `applicationWillTerminate` runs on the MainActor, and any
        // semaphore-style join would deadlock the @MainActor-bound
        // Task we just spawned.
        Task { await appState.stop() }
    }

    private static func defaultProjectsRoot() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects").path
    }
}
