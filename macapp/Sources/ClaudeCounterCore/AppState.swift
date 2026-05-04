import Foundation
#if canImport(Combine)
import Combine
#endif

/// Top-of-app reactive view model. Owns the pipeline:
///
///     Watcher → Reader → Aggregator → Snapshot → UI
///
/// SwiftUI views observe `AppState` via `@ObservedObject`. AppState is
/// MainActor-bound so all `@Published` mutations stay on the main thread.
@MainActor
public final class AppState: ObservableObject {

    // MARK: Published state (UI binds to these)

    @Published public private(set) var totals: Totals = Totals()
    @Published public private(set) var live: [LiveEvent] = []
    @Published public private(set) var pricing: PricingTable
    @Published public private(set) var status: Status = .starting
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var settings: AppSettings

    public enum Status: Equatable, Sendable {
        case starting
        case scanning
        case live
        case noProjectsRoot(path: String)
    }

    // MARK: Dependencies

    public let projectsRoot: String
    private let aggregator: Aggregator
    private let reader: Reader
    private var watcher: Watcher?
    private let cacheStore: CacheStore
    private let dockIcon: DockIconController
    private let settingsStore: SettingsStore
    private let now: () -> Date
    private let calendar: Calendar

    // MARK: Internal state

    private var liveBuffer = LiveEventBuffer(capacity: 50)
    private var liveTailOpen: Bool = false   // gates LIVE buffer until backfill completes
    private var perFileOffsets: [String: Int64] = [:]
    private var dirty: Bool = false
    private var snapshotTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var periodicFlushTask: Task<Void, Never>?

    public init(projectsRoot: String,
                aggregator: Aggregator,
                reader: Reader = Reader(),
                cacheStore: CacheStore,
                pricing: PricingTable,
                dockIcon: DockIconController? = nil,
                settingsStore: SettingsStore? = nil,
                now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.projectsRoot = projectsRoot
        self.aggregator = aggregator
        self.reader = reader
        self.cacheStore = cacheStore
        self.pricing = pricing
        // Production wiring resolves the optional deps here so that
        // existing tests (which don't pass dockIcon / settingsStore)
        // still compile and run against safe defaults — UserDefaults
        // is real but harmless, and the NSApp dock controller no-ops
        // on the test runner until `setVisible(true)` is called.
        let resolvedDock = dockIcon ?? NSAppDockIconController()
        let resolvedStore = settingsStore ?? UserDefaultsSettingsStore()
        self.dockIcon = resolvedDock
        self.settingsStore = resolvedStore
        self.settings = resolvedStore.load()
        self.now = now
        self.calendar = calendar
    }

    // MARK: Lifecycle

    /// Boot the pipeline:
    ///   1. Apply the persisted dock-icon visibility (sync, before any
    ///      async work, so the dock icon shows up immediately).
    ///   2. Try to load cache; seed aggregator + reader offsets if present.
    ///   3. Publish first snapshot immediately so the UI shows numbers
    ///      (and the dock badge picks up today's spend on the same tick).
    ///   4. Start the FSEventStream watcher.
    ///   5. Run the catch-up scan with notBefore = max(cache.writtenAt-5m,
    ///      min(firstOfMonth, now-35d)).
    ///   6. Open the live-tail gate so per-event UI updates start flowing.
    public func start() async {
        // Apply dock visibility before checking the projects root —
        // even if there's no data, the user should see the dock icon
        // (which doubles as proof the app is running) when enabled.
        dockIcon.setVisible(settings.dockIconEnabled)

        guard FileManager.default.fileExists(atPath: projectsRoot) else {
            self.status = .noProjectsRoot(path: projectsRoot)
            return
        }

        var cacheWrittenAt: Date? = nil
        if let cache = try? cacheStore.load() {
            if cache.version == CacheFile.currentVersion {
                let offsets = await cache.restore(into: aggregator)
                self.perFileOffsets = offsets
                await reader.seedOffsets(offsets)
                cacheWrittenAt = cache.writtenAt
            } else {
                cacheStore.invalidate()
            }
        }
        // Show whatever the cache produced as soon as possible.
        await publishSnapshot()

        startWatcher()
        startPeriodicFlush()

        self.status = .scanning
        // Catch-up scan.
        let notBefore = scanCutoff(now: now(), cacheWrittenAt: cacheWrittenAt, calendar: calendar)
        do {
            let events = try await reader.initialScan(root: projectsRoot, notBefore: notBefore)
            for ev in events {
                await aggregator.apply(ev)
            }
            // Snapshot once at end of backfill.
            await publishSnapshot()
            self.perFileOffsets = await reader.allOffsets()
        } catch {
            self.lastError = "Initial scan failed: \(error.localizedDescription)"
        }
        self.liveTailOpen = true
        self.status = .live

        // Persist now so that even a crash a moment later keeps the
        // post-backfill state durable.
        await flushCache()
    }

    /// Tear down the pipeline. Persists current state to cache.
    public func stop() async {
        snapshotTask?.cancel()
        watcherTask?.cancel()
        periodicFlushTask?.cancel()
        watcher?.stop()
        watcher = nil
        await flushCache()
    }

    /// Manual refresh: invalidate cache, reset aggregator, do a full
    /// scan from `min(firstOfMonth, now-35d)`.
    public func refresh() async {
        cacheStore.invalidate()
        await aggregator.reset()
        await reader.resetAll()
        self.perFileOffsets = [:]
        self.liveBuffer.clear()
        self.live = []
        self.lastError = nil
        await publishSnapshot()
        self.liveTailOpen = false

        self.status = .scanning
        let notBefore = scanCutoff(now: now(), cacheWrittenAt: nil, calendar: calendar)
        do {
            let events = try await reader.initialScan(root: projectsRoot, notBefore: notBefore)
            for ev in events {
                await aggregator.apply(ev)
            }
            await publishSnapshot()
            self.perFileOffsets = await reader.allOffsets()
        } catch {
            self.lastError = "Refresh failed: \(error.localizedDescription)"
        }
        self.liveTailOpen = true
        self.status = .live
        await flushCache()
    }

    /// Replace the pricing table. Snapshot will recompute USD on next tick.
    public func updatePricing(_ table: PricingTable) async {
        self.pricing = table
        await aggregator.setPricing(table)
        await publishSnapshot()
    }

    // MARK: Watcher loop

    private func startWatcher() {
        let w = Watcher(root: projectsRoot)
        let stream = w.start()
        self.watcher = w

        watcherTask = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                await self.handle(change: change)
            }
        }
    }

    private func handle(change: FileChange) async {
        switch change.kind {
        case .create, .modify:
            do {
                let events = try await reader.onChange(path: change.path)
                for ev in events {
                    await aggregator.apply(ev)
                    if liveTailOpen {
                        let live = LiveEvent.from(ev, pricing: self.pricing)
                        self.liveBuffer.push(live)
                    }
                }
                if !events.isEmpty {
                    self.dirty = true
                    self.scheduleSnapshotTick()
                    if liveTailOpen {
                        self.live = self.liveBuffer.items
                    }
                }
            } catch {
                self.lastError = "Reader failed on \(change.path): \(error.localizedDescription)"
            }
        case .remove:
            await reader.forget(path: change.path)
            self.dirty = true
            self.scheduleSnapshotTick()
        }
    }

    /// Coalesce snapshot publishes to at most one per 250ms.
    private func scheduleSnapshotTick() {
        if snapshotTask != nil { return }
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.snapshotTask = nil
            if self.dirty {
                self.dirty = false
                await self.publishSnapshot()
            }
        }
    }

    private func publishSnapshot() async {
        let snap = await aggregator.snapshot()
        self.totals = snap
        updateDockBadge()
    }

    /// Stamp today's spend onto the dock badge. No-op when the user has
    /// the dock icon turned off — the controller will skip the syscall
    /// anyway, but checking here saves the formatter call.
    private func updateDockBadge() {
        guard settings.dockIconEnabled else { return }
        let today = totals.day.values.reduce(0) { $0 + $1.usd }
        dockIcon.setBadge(formatUSDCompact(today))
    }

    /// Toggle the dock icon at runtime (called from the ⚙ menu).
    /// Persists the new preference, flips the activation policy, and
    /// stamps the current spend immediately when enabling so the user
    /// sees the value the moment the icon appears.
    public func setDockIconEnabled(_ enabled: Bool) {
        settings.dockIconEnabled = enabled
        settingsStore.save(settings)
        dockIcon.setVisible(enabled)
        if enabled {
            updateDockBadge()
        }
    }

    private func startPeriodicFlush() {
        periodicFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                await self?.flushCache()
            }
        }
    }

    private func flushCache() async {
        let offsets = await reader.allOffsets()
        let parseErrors = await reader.parseErrors
        let cache = await CacheFile.snapshot(
            aggregator: aggregator,
            offsets: offsets,
            parseErrors: parseErrors,
            writtenAt: now()
        )
        do {
            try cacheStore.save(cache)
        } catch {
            self.lastError = "Cache write failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - scanCutoff

/// Match the Go binary's `min(firstOfMonth, now-35d)` cutoff, with the
/// menu-bar additional rule that if a cache has just been restored, we
/// only need to scan files modified after `cacheWrittenAt - 5min`.
public func scanCutoff(now: Date,
                       cacheWrittenAt: Date? = nil,
                       calendar: Calendar = .current) -> Date {
    let thirtyFive = calendar.date(byAdding: .day, value: -35, to: now) ?? now
    var comps = calendar.dateComponents([.year, .month], from: now)
    comps.day = 1; comps.hour = 0; comps.minute = 0; comps.second = 0
    let firstOfMonth = calendar.date(from: comps) ?? now
    let baseFloor = min(firstOfMonth, thirtyFive)

    guard let cacheTime = cacheWrittenAt else { return baseFloor }
    let cacheFloor = cacheTime.addingTimeInterval(-5 * 60)
    return max(cacheFloor, baseFloor)
}
