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
    /// Live sessions with activity inside the active window, sorted by
    /// trailing-5-minute cost. Replaces the old per-event live tail.
    @Published public private(set) var activeSessions: [SessionStat] = []
    /// True when at least one active session is in any warning state —
    /// drives the red menu-bar capsule.
    @Published public private(set) var hasActiveWarning: Bool = false
    @Published public private(set) var pricing: PricingTable
    @Published public private(set) var status: Status = .starting
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var settings: AppSettings
    /// Budget statuses (day/week) evaluated against `limits.toml`. Empty
    /// when the file is absent/malformed or every window is `.unset`.
    @Published public private(set) var limitStatuses: [LimitStatus] = []
    /// Vendor-reported plan utilisation (Codex, Grok). Empty when neither
    /// vendor is installed.
    @Published public private(set) var planGauges: [PlanGauge] = []

    public enum Status: Equatable, Sendable {
        case starting
        case scanning
        case live
        case noProjectsRoot(path: String)
    }

    // MARK: Dependencies

    public let projectsRoot: String
    private let aggregator: Aggregator
    private let tracker: SessionTracker
    private let reader: Reader
    private var watcher: Watcher?
    private let cacheStore: CacheStore
    private let dockIcon: DockIconController
    private let settingsStore: SettingsStore
    private let notifier: SessionNotifier
    private let now: () -> Date
    private let calendar: Calendar

    // MARK: Internal state

    /// Debounce keys (`"<sessionID>|<condition>"`) already notified, so a
    /// session over threshold doesn't re-fire every turn.
    private var notifiedKeys: Set<String> = []
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
                tracker: SessionTracker? = nil,
                dockIcon: DockIconController? = nil,
                settingsStore: SettingsStore? = nil,
                notifier: SessionNotifier? = nil,
                now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current) {
        self.projectsRoot = projectsRoot
        self.aggregator = aggregator
        // Tracker shares the same pricing; production omits it and we build
        // one here. Tests can inject a pre-seeded tracker.
        self.tracker = tracker ?? SessionTracker(pricing: pricing)
        self.reader = reader
        self.cacheStore = cacheStore
        self.pricing = pricing
        // Default to the no-op notifier so the test runner never touches
        // UNUserNotificationCenter; production injects the real one.
        self.notifier = notifier ?? NullSessionNotifier()
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
                if await aggregator.apply(ev) { await tracker.apply(ev) }
            }
            // Snapshot once at end of backfill.
            await publishSnapshot()
            self.perFileOffsets = await reader.allOffsets()
        } catch {
            self.lastError = "Initial scan failed: \(error.localizedDescription)"
        }
        self.status = .live
        // First paint of the gauge bands, so they show up without the
        // user having to click Refresh.
        await refreshGauges()

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
        await tracker.reset()
        await reader.resetAll()
        self.perFileOffsets = [:]
        self.notifiedKeys.removeAll()
        self.lastError = nil
        await publishSnapshot()

        self.status = .scanning
        let notBefore = scanCutoff(now: now(), cacheWrittenAt: nil, calendar: calendar)
        do {
            let events = try await reader.initialScan(root: projectsRoot, notBefore: notBefore)
            for ev in events {
                if await aggregator.apply(ev) { await tracker.apply(ev) }
            }
            await publishSnapshot()
            self.perFileOffsets = await reader.allOffsets()
        } catch {
            self.lastError = "Refresh failed: \(error.localizedDescription)"
        }
        self.status = .live
        await refreshGauges()
        await flushCache()
    }

    /// Replace the pricing table. Snapshot will recompute USD on next tick.
    public func updatePricing(_ table: PricingTable) async {
        self.pricing = table
        await aggregator.setPricing(table)
        await tracker.setPricing(table)
        await publishSnapshot()
    }

    /// How often `refreshGauges` does the expensive part: a recursive
    /// filesystem walk of `~/.codex/sessions` (up to 50 whole-file reads)
    /// plus the Grok log. 10 minutes of percentage staleness is an
    /// acceptable trade against redoing that I/O every periodic-flush
    /// tick; staleness itself does NOT wait this long — see
    /// `displayPlanGauges`.
    private static let gaugeRescanEveryNTicks = 10

    /// Ticks (60s each, one per periodic-flush loop iteration) since the
    /// last full gauge rescan. Starts at `gaugeRescanEveryNTicks` so the
    /// very first tick after `start()`'s own rescan doesn't immediately
    /// rescan again.
    private var gaugeRescanTickCount = 0

    /// Highest non-stale utilisation, used for menu bar escalation.
    /// Reads `displayPlanGauges`, not `planGauges` directly, so an
    /// expired window stops counting the instant it expires rather than
    /// waiting for the next filesystem rescan.
    public var worstUtilisationPct: Double {
        GaugeRows.worstPct(statuses: limitStatuses, gauges: displayPlanGauges)
    }

    /// `planGauges` with `stale` re-derived from `resetsAt` against the
    /// current clock, instead of trusting the value fixed at the last
    /// scan (which can now be up to `gaugeRescanEveryNTicks` minutes
    /// old). This is what the popover should render, and what
    /// `worstUtilisationPct` filters on.
    ///
    /// This deliberately does NOT mutate the stored `planGauges` array:
    /// that array keeps exactly what the last scan observed (mirroring
    /// Go's `Gauge.Stale`, computed once at scan time), and this
    /// computed property derives the up-to-date display value from it
    /// on every access instead.
    public var displayPlanGauges: [PlanGauge] {
        let now = self.now()
        return planGauges.map { g in
            var g2 = g
            g2.stale = g.resetsAt < now
            return g2
        }
    }

    /// Re-evaluates budgets and rescans the vendor logs. Scanning walks
    /// the filesystem, so it stays off the main actor; only the
    /// assignment hops back.
    ///
    /// A malformed `limits.toml` degrades the budget rows to "no rows",
    /// never a crash or a stalled UI, but surfaces once via `lastError`
    /// so the user isn't left wondering why the budget gauges vanished.
    /// A missing config file is NOT an error — `Limits.load` returns
    /// zero limits for that case, which is the normal unconfigured
    /// state. Vendor scans never throw either: `PlanLimits.scanCodex` /
    /// `scanGrok` treat a missing or unreadable log as "no rows" for
    /// that vendor, not a failure.
    ///
    /// Called from `start()` (first paint) and `refresh()` (the
    /// popover's manual refresh button) — both do a full rescan. The
    /// periodic-flush loop also calls this, but only every
    /// `gaugeRescanEveryNTicks` ticks; the loop's other ticks force a
    /// UI redraw (via `objectWillChange`) so `displayPlanGauges` picks
    /// up newly-expired windows every minute without any filesystem
    /// access. Piggybacking on the existing periodic loop avoids adding
    /// a second timer.
    public func refreshGauges(now: Date = Date()) async {
        let daily = totals.daily
        let statuses: [LimitStatus]
        do {
            let cfg = try Limits.load(path: Limits.defaultConfigPath())
            // ISO-8601 identifier for Monday-first week numbering matching
            // Go's ISOWeek, but the CURRENT time zone — `DailyTotal.day` is a
            // local calendar day, so evaluating in UTC would misalign the day
            // key at the local midnight boundary. `Calendar.current` is wrong
            // here too: it is Gregorian and typically Sunday-first, which
            // numbers weeks differently from the Go side.
            var cal = Calendar(identifier: .iso8601)
            cal.timeZone = .current
            statuses = Limits.evaluate(daily: daily, config: cfg, now: now, calendar: cal)
        } catch LimitsError.malformed(let line) {
            self.lastError = "limits.toml is malformed near: \"\(line)\""
            statuses = []
        } catch {
            self.lastError = "Failed to load limits.toml: \(error)"
            statuses = []
        }
        let gauges = await Task.detached(priority: .utility) { () -> [PlanGauge] in
            PlanLimits.scanCodex(root: PlanLimits.defaultCodexRoot(), now: now)
                + PlanLimits.scanGrok(path: PlanLimits.defaultGrokLog(), now: now)
        }.value

        self.limitStatuses = statuses
        self.planGauges = gauges
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
                    if await aggregator.apply(ev) { await tracker.apply(ev) }
                }
                if !events.isEmpty {
                    self.dirty = true
                    self.scheduleSnapshotTick()
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
        await publishSessions()
    }

    /// Refresh the active-session panel, the red-capsule flag, and fire any
    /// newly-crossed notifications (debounced per session+condition).
    private func publishSessions() async {
        let sessions = await tracker.snapshot(now: now(),
                                              thresholds: settings.sessionThresholds)
        self.activeSessions = sessions
        self.hasActiveWarning = sessions.contains { !$0.warnings.isEmpty }

        let (toPost, next) = newlyTriggered(active: sessions,
                                            alreadyNotified: notifiedKeys)
        self.notifiedKeys = next
        if settings.notificationsEnabled {
            for n in toPost { notifier.post(n) }
        }
    }

    /// Stamp today's spend onto the dock badge. No-op when the user has
    /// the dock icon turned off — the controller will skip the syscall
    /// anyway, but checking here saves the formatter call.
    /// Uses the whole-dollar format (`$35`, not `$34.87`) to match the
    /// menu bar label — both shell surfaces stay legible at small size.
    private func updateDockBadge() {
        guard settings.dockIconEnabled else { return }
        let today = totals.day.values.reduce(0) { $0 + $1.usd }
        dockIcon.setBadge(formatUSDWhole(today))
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

    /// Toggle session-warning notifications at runtime (⚙ menu).
    public func setNotificationsEnabled(_ enabled: Bool) {
        settings.notificationsEnabled = enabled
        settingsStore.save(settings)
    }

    private func startPeriodicFlush() {
        periodicFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                guard let self else { return }
                // Force a redraw every tick so `displayPlanGauges` (which
                // re-derives staleness from `resetsAt` against "now" on
                // every access — see its doc comment) gets re-evaluated
                // even on an otherwise-idle app. This alone is what stops
                // an expired window from reading as live forever; it
                // costs no filesystem access.
                self.objectWillChange.send()
                self.gaugeRescanTickCount += 1
                if self.gaugeRescanTickCount >= Self.gaugeRescanEveryNTicks {
                    self.gaugeRescanTickCount = 0
                    // The expensive part: walks ~/.codex/sessions and
                    // reads the Grok log. Runs far less often than the
                    // staleness redraw above needs.
                    await self.refreshGauges()
                }
                await self.flushCache()
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
