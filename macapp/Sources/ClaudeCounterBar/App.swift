import SwiftUI
import AppKit
import ClaudeCounterCore

// MARK: - App entry point

@main
struct ClaudeCounterBarApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            // Fixed width; height is user-adjustable via a drag grip at
            // the bottom of the popover and persisted across launches.
            // SwiftUI's MenuBarExtra window sizes to the content frame,
            // so `PopoverView` owns its own `.frame(width:height:)`.
            PopoverView(state: delegate.appState)
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
        self.notifier = UserNotificationsNotifier()
        self.appState = AppState(
            projectsRoot: projectsRoot,
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: pricing,
            dockIcon: dockIcon,
            settingsStore: settingsStore,
            notifier: notifier
        )
        super.init()
    }

    private let notifier: UserNotificationsNotifier

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No icon-image juggling here — the dock controller installs
        // both the hosting view and the backstop image inside
        // `setVisible(true)` and forces a `dockTile.display()`. That
        // way, toggling the dock icon off and back on always reapplies
        // the artwork; macOS resets some dock-tile state when the
        // activation policy flips and a one-shot launch-time install
        // wouldn't survive that.
        // Ask for notification permission once. Denied/undetermined is
        // fine — session alerts silently no-op and the in-app warnings +
        // red menu-bar capsule still work.
        notifier.requestAuthorization()
        Task { await appState.start() }
        // Separate, concurrent Task: a stale-schema pricing.toml (e.g. one
        // written before OpenAI models were admitted) must not block the
        // data pipeline above on a network fetch — see
        // AppState.refreshPricingIfStale.
        Task { await appState.refreshPricingIfStale() }
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
