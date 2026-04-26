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
                .frame(width: 520)
                .frame(minHeight: 360, maxHeight: 600)
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
        self.appState = AppState(
            projectsRoot: projectsRoot,
            aggregator: agg,
            reader: Reader(),
            cacheStore: CacheStore(url: cacheURL),
            pricing: pricing
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
