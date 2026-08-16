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
    /// The amber threshold from `limits.toml`'s `warn_pct`
    /// (`LimitsConfig.defaultWarnPct` when unconfigured or the file is
    /// malformed). This is what `GaugesView` and `MenuBarLabel` render
    /// their warn colour against — see `refreshBudgets` — so a configured
    /// threshold takes effect on both surfaces without either hardcoding
    /// 80.
    @Published public private(set) var warnPct: Int = LimitsConfig.defaultWarnPct
    /// The resolved source list currently being scanned/watched. A
    /// missing or malformed `sources.toml` degrades to the single
    /// implicit source rooted at `projectsRoot` — see `resolveSources`.
    @Published public private(set) var sources: [SourceEntry] = []
    /// Which axis the per-model list (and, eventually, other grouped
    /// views) collapses series onto. Purely a display choice — every
    /// mode partitions the same underlying totals, so switching it
    /// never changes what's counted.
    @Published public private(set) var groupMode: GroupMode = .model

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
    private let sourcesConfigPath: String
    /// Home directory `resolveSources` discovers non-Claude vendors
    /// under (via `Sources.defaultsWithClaudeRoot`) when `sources.toml`
    /// is absent or malformed. Defaults to the real home so a caller
    /// that doesn't opt in still gets correct discovery — the opposite
    /// default (silently NOT discovering) is the class of bug this
    /// parameter exists to fix. Tests inject an isolated temp dir here
    /// so they never touch a developer machine's real `~/.grok`.
    private let home: String
    /// One `Reader` per configured source, keyed by `SourceEntry.id`.
    /// Mirrors the Go TUI's `readers[s.ID()] = reader.New(evCh)` — see
    /// `resolveSources`/`syncReaders` for why this project keeps that
    /// shape even though Swift's `Reader` never stores a mutable
    /// "current source" the way Go's does (this app's `onChange` takes
    /// the source as a per-call argument and stamps events from it, so
    /// a single shared actor would already be attribution-safe here).
    /// Per-source instances are kept anyway for parity with the Go
    /// implementation and because `parseErrors`/offsets stay scoped to
    /// one subscription instead of commingling across sources when the
    /// user adds/removes one at runtime via the editor.
    private var readers: [String: Reader] = [:]
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
    /// Mirrors whatever `lastError` `resolveSources` itself most
    /// recently set (nil once a load last succeeded) — same pattern as
    /// `lastLimitsError`, so a later clean load clears exactly the
    /// error it set and nothing else.
    private var lastSourcesError: String? = nil

    /// `reader` seeds the `Reader` for the single implicit source
    /// (`vendor: "claude", label: "claude"`, id `"claude/claude"`) —
    /// exactly the role this parameter always had before multi-source
    /// support existed. Any additional sources a `sources.toml` goes on
    /// to configure get their own freshly-created `Reader` in
    /// `syncReaders`; this parameter never seeds more than the one.
    public init(projectsRoot: String,
                aggregator: Aggregator,
                reader: Reader = Reader(),
                cacheStore: CacheStore,
                pricing: PricingTable,
                tracker: SessionTracker? = nil,
                dockIcon: DockIconController? = nil,
                settingsStore: SettingsStore? = nil,
                notifier: SessionNotifier? = nil,
                sourcesConfigPath: String = Sources.defaultConfigPath(),
                now: @escaping () -> Date = Date.init,
                calendar: Calendar = .current,
                home: String = NSHomeDirectory()) {
        self.projectsRoot = projectsRoot
        self.aggregator = aggregator
        // Tracker shares the same pricing; production omits it and we build
        // one here. Tests can inject a pre-seeded tracker.
        self.tracker = tracker ?? SessionTracker(pricing: pricing)
        self.sourcesConfigPath = sourcesConfigPath
        self.home = home
        let defaultSource = SourceEntry(vendor: "claude", label: "claude", root: projectsRoot)
        self.readers = [defaultSource.id: reader]
        self.sources = [defaultSource]
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

        self.sources = resolveSources()
        syncReaders(to: sources)

        // A configured root that doesn't exist contributes nothing and
        // is not an error (see resolveSources' doc comment); only when
        // NONE of the configured roots exist do we fall back to the
        // pre-multi-source "no data" UI, exactly as before.
        let reachable = sources.filter { FileManager.default.fileExists(atPath: $0.root) }
        guard !reachable.isEmpty else {
            self.status = .noProjectsRoot(path: sources.first?.root ?? projectsRoot)
            return
        }

        var cacheWrittenAt: Date? = nil
        if let cache = try? cacheStore.load() {
            if cache.version == CacheFile.currentVersion {
                let offsets = await cache.restore(into: aggregator)
                self.perFileOffsets = offsets
                await seedReaders(from: offsets)
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
        // Catch-up scan, once per reachable source. A failure scanning
        // one source surfaces via lastError but does not stop the
        // others — see scanSource.
        let notBefore = scanCutoff(now: now(), cacheWrittenAt: cacheWrittenAt, calendar: calendar)
        for source in reachable {
            await scanSource(source, notBefore: notBefore)
        }
        // Snapshot once at end of backfill.
        await publishSnapshot()
        self.perFileOffsets = await mergedOffsets()
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
    /// scan from `min(firstOfMonth, now-35d)`. Also re-resolves sources
    /// (the user may have edited `sources.toml` externally since
    /// launch) and restarts the watcher against whatever roots that
    /// resolves to.
    public func refresh() async {
        cacheStore.invalidate()
        await aggregator.reset()
        await tracker.reset()
        for r in readers.values { await r.resetAll() }
        self.perFileOffsets = [:]
        self.notifiedKeys.removeAll()
        self.lastError = nil
        await publishSnapshot()

        self.sources = resolveSources()
        syncReaders(to: sources)
        restartWatcher()

        self.status = .scanning
        let notBefore = scanCutoff(now: now(), cacheWrittenAt: nil, calendar: calendar)
        let reachable = sources.filter { FileManager.default.fileExists(atPath: $0.root) }
        for source in reachable {
            await scanSource(source, notBefore: notBefore)
        }
        await publishSnapshot()
        self.perFileOffsets = await mergedOffsets()
        self.status = .live
        await refreshGauges()
        await flushCache()
    }

    /// Re-reads `sources.toml` (typically after the GUI editor saves a
    /// change), adjusts the reader pool, restarts the watcher against
    /// the new root set, and scans any source whose history hasn't been
    /// read yet — either because it's brand new, or because an existing
    /// id's root just changed (the editor's folder picker repointed it)
    /// — so the result shows up immediately rather than waiting for the
    /// next filesystem event. Removed sources simply stop contributing —
    /// their already-aggregated totals stay in `totals` (matching how a
    /// root going missing behaves), only future events stop arriving.
    public func reloadSources() async {
        let previousByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let resolved = resolveSources()

        var needsScan: [SourceEntry] = []
        for s in resolved {
            if readers[s.id] == nil {
                // Brand new id — syncReaders (below) will give it a
                // fresh Reader.
                needsScan.append(s)
            } else if let old = previousByID[s.id], old.root != s.root {
                // Same id, different root (edited in place): the
                // existing Reader's offsets are keyed to paths under
                // the OLD root and say nothing about the new one.
                // Replace it so the new root's files are read from
                // scratch rather than silently never scanned.
                readers[s.id] = Reader()
                needsScan.append(s)
            }
        }

        self.sources = resolved
        syncReaders(to: resolved)
        restartWatcher()

        let notBefore = scanCutoff(now: now(), calendar: calendar)
        for source in needsScan where FileManager.default.fileExists(atPath: source.root) {
            await scanSource(source, notBefore: notBefore)
        }
        await publishSnapshot()
        self.perFileOffsets = await mergedOffsets()
        await flushCache()
    }

    /// Change which axis the per-model list groups by. Pure display
    /// state — never touches `totals`, so switching modes back and
    /// forth is free.
    public func setGroupMode(_ mode: GroupMode) {
        self.groupMode = mode
    }

    /// Runs one source's catch-up scan through its own `Reader` and
    /// applies the resulting events. Errors are scoped to `lastError`
    /// rather than propagated, so one bad source (permissions, a
    /// half-written file, ...) never aborts the others — mirrors the Go
    /// pipeline's per-source `log.Printf` on `InitialScanSource` failure.
    private func scanSource(_ source: SourceEntry, notBefore: Date) async {
        guard let r = readers[source.id] else { return }
        do {
            let events = try await r.initialScan(root: source.root, source: source, notBefore: notBefore)
            for ev in events {
                if await aggregator.apply(ev) { await tracker.apply(ev) }
            }
        } catch {
            self.lastError = "Initial scan failed for \(source.id): \(error.localizedDescription)"
        }
    }

    /// Loads the configured source list. A missing `sources.toml` (the
    /// default state for every install) yields
    /// `Sources.defaultsWithClaudeRoot(home:claudeRoot:)`, NOT a bare
    /// Claude-only list: the Claude entry is pinned at exactly
    /// `projectsRoot` — this `AppState`'s injected root, honoured even
    /// when it's an isolated test temp dir rather than the real
    /// `~/.claude/projects` — while every OTHER vendor (currently just
    /// Grok) is discovered under `home`, also as injected, so a test's
    /// temp `home` (containing no `.grok/sessions`) discovers nothing
    /// and a production `home` of the real `NSHomeDirectory()` discovers
    /// whatever vendor directories actually exist on that machine. Both
    /// halves matter: pinning the Claude root keeps every existing
    /// caller's counting scope unchanged, and discovering under the
    /// injected `home` (rather than always the real one) is what keeps
    /// this deterministic under test. A malformed config degrades to
    /// that same discovering default with `lastError` set — counting
    /// never stops over a config typo.
    private func resolveSources() -> [SourceEntry] {
        let fallback = Sources.defaultsWithClaudeRoot(home: home, claudeRoot: projectsRoot)
        guard FileManager.default.fileExists(atPath: sourcesConfigPath) else {
            if lastError != nil && lastError == lastSourcesError { self.lastError = nil }
            lastSourcesError = nil
            return fallback
        }
        do {
            let cfg = try Sources.load(path: sourcesConfigPath, home: NSHomeDirectory())
            if lastError != nil && lastError == lastSourcesError { self.lastError = nil }
            lastSourcesError = nil
            return cfg.sources
        } catch {
            let message = "sources.toml: \(error.localizedDescription)"
            self.lastError = message
            lastSourcesError = message
            return fallback
        }
    }

    /// Keeps `readers` in sync with a resolved source list: a fresh
    /// `Reader` for every newly-configured source, and drops readers for
    /// sources no longer configured. The single-implicit-source id
    /// (`"claude/claude"`) already has a reader from `init` and is left
    /// alone when it's still present, so its accumulated offsets survive
    /// a reload that doesn't touch it.
    private func syncReaders(to newSources: [SourceEntry]) {
        let ids = Set(newSources.map { $0.id })
        for id in Set(readers.keys).subtracting(ids) {
            readers.removeValue(forKey: id)
        }
        for s in newSources where readers[s.id] == nil {
            readers[s.id] = Reader()
        }
    }

    /// Distributes a flat, cache-restored offset map to the readers
    /// that actually own each path, using the same `sourceForPath`
    /// routing the live watcher uses. This is the ONLY place offsets
    /// cross from "one dict for everything" back to "one dict per
    /// reader" — critically, each path lands in exactly one reader's
    /// dict, never more than one.
    ///
    /// A previous version of this method broadcast the *entire* merged
    /// dict to *every* reader via `Reader.seedOffsets` (which replaces,
    /// not merges). That left every reader holding entries for every
    /// OTHER source's paths too — entries it would never itself update,
    /// since `onChange`/`initialScan` only ever touch paths under that
    /// reader's own root. `mergedOffsets()` then had to pick one of two
    /// disagreeing values (the true owner's advanced offset vs. another
    /// reader's frozen, stale copy) using `Dictionary`'s unspecified
    /// iteration order — a coin flip that, when it landed on the stale
    /// value, persisted an offset BEHIND what was actually read. On the
    /// next launch that portion of the file would be re-scanned and its
    /// already-counted events re-emitted: double-counted spend, exactly
    /// what the global constraints forbid. Routing each path to its one
    /// true owner here removes the ambiguity at its source instead of
    /// arbitrating it later.
    private func seedReaders(from offsets: [String: Int64]) async {
        var bySource: [String: [String: Int64]] = [:]
        for (path, offset) in offsets {
            // A cached path that no longer matches ANY configured
            // source (its source was removed from sources.toml since
            // the cache was written) is dropped here, on purpose: there
            // is no reader to give it to. If that source is later
            // re-added, its files are re-read from offset zero — a
            // one-time re-scan, not a double count, since the
            // aggregator's perMsg dedupe (also restored from the same
            // cache) still recognises every message it already
            // counted. See
            // `test_appState_seedReaders_scopesEachOffsetToExactlyOneOwningReader`
            // for the pinned behaviour.
            //
            // Deliberately `Self.matchSource`, NOT `sourceForPath`: the
            // latter's single-source shortcut would hand this path to
            // the lone reader unconditionally, even when it belongs to
            // no configured source — see `matchSource`'s doc comment
            // and `test_appState_seedReaders_singleSource_dropsPathOutsideRoot`.
            guard let source = Self.matchSource(for: path, in: sources) else { continue }
            bySource[source.id, default: [:]][path] = offset
        }
        // Each reader id maps to exactly one `SourceEntry` (and so one
        // vendor) — `readers`/`sources` are kept in lockstep by
        // `syncReaders`. `seedOffsets` needs the vendor to know whether
        // to replay codex paths' running state (see its doc comment); a
        // reader whose id is somehow missing from `sources` (should be
        // unreachable) gets "", which is a plain assignment, never a
        // guessed-at replay.
        let vendorByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.vendor) })
        for (id, r) in readers {
            await r.seedOffsets(bySource[id] ?? [:], vendor: vendorByID[id] ?? "")
        }
    }

    /// Test-only introspection: a snapshot of every reader's own offset
    /// dict, keyed by source id. `readers` and `seedReaders` are
    /// `private` (this file keeps the reader pool as an implementation
    /// detail), so this is the one seam `AppStateTests` uses to assert
    /// the per-source-scoped-seeding invariant directly — see
    /// `test_appState_seedReaders_scopesEachOffsetToExactlyOneOwningReader`
    /// for why that direct assertion matters more than observing the
    /// double-counting symptom through a full restart cycle (the
    /// symptom depends on `Dictionary`'s randomised iteration order and
    /// was measured to reproduce only ~14% of the time against the
    /// pre-fix code). No `private`/`public` modifier: internal is
    /// enough for `@testable import` to reach it, and it stays out of
    /// `AppState`'s public API.
    func readerOffsetsByID() async -> [String: [String: Int64]] {
        var out: [String: [String: Int64]] = [:]
        for (id, r) in readers {
            out[id] = await r.allOffsets()
        }
        return out
    }

    /// Merge every reader's offset map into one flat dict for the cache
    /// file. Safe as a plain last-wins merge ONLY because `seedReaders`
    /// (see its doc comment) and the per-path routing in `handle` /
    /// `scanSource` guarantee each path is ever held by exactly one
    /// reader — never broadcast to others — so there is never a second,
    /// disagreeing value to lose here.
    private func mergedOffsets() async -> [String: Int64] {
        var merged: [String: Int64] = [:]
        for r in readers.values {
            merged.merge(await r.allOffsets()) { _, new in new }
        }
        return merged
    }

    private func totalParseErrors() async -> Int {
        var total = 0
        for r in readers.values { total += await r.parseErrors }
        return total
    }

    /// Replace the pricing table. Snapshot will recompute USD on next tick.
    public func updatePricing(_ table: PricingTable) async {
        self.pricing = table
        await aggregator.setPricing(table)
        await tracker.setPricing(table)
        await publishSnapshot()
    }

    /// One-shot pricing refresh when the on-disk cache `resolveFromDisk`
    /// loaded at launch predates `PricingTable.currentSchema`. Mirrors the
    /// Go binary's `loadPricing` stale-cache branch: a table saved under an
    /// older schema is a complete, valid table — just missing an entire
    /// provider's worth of models, which would silently price them at $0
    /// forever. `writeToAppOverride` (and the Go side's `SaveTOML`) always
    /// stamp the current schema, so this refetches at most once per stale
    /// cache.
    ///
    /// Unlike the Go CLI (a single run that can afford to block on this
    /// fetch), `resolveFromDisk` stays synchronous and the menu-bar app's
    /// launch is never blocked on network for it — call this separately,
    /// concurrently with `start()`. On failure (e.g. offline), the stale
    /// table already loaded into `pricing` is left in place rather than
    /// dropping to baked-in defaults: a network hiccup must never change
    /// Claude dollars as a side effect of a Codex/OpenAI pricing change.
    public func refreshPricingIfStale(session: URLSessionProtocol = URLSession.shared) async {
        guard pricing.schema < PricingTable.currentSchema else { return }
        guard let fresh = try? await PricingFetcher.fetch(session: session) else { return }
        try? fresh.writeToAppOverride()
        await updatePricing(fresh)
    }

    /// How often `rescanPlanGauges` walks the filesystem: a recursive
    /// walk of `~/.codex/sessions` (up to 50 whole-file reads) plus the
    /// Grok log. 10 minutes of vendor-plan staleness is an acceptable
    /// trade against redoing that I/O every periodic-flush tick.
    ///
    /// This does NOT gate `refreshBudgets` — budgets re-evaluate every
    /// tick (60s), since that's a small `limits.toml` read plus the pure
    /// `Limits.evaluate`, no directory walk. Before this split, both
    /// were bundled into one `refreshGauges` call gated behind this
    /// constant, which meant a budget crossing `warn_pct` or 100%
    /// mid-session could keep a green menu bar for up to 10 minutes
    /// (final-review.md I-1) — the fix that introduced this constant
    /// correctly decoupled the vendor walk from per-tick staleness
    /// (`displayPlanGauges`), but left budget re-evaluation riding along
    /// with the expensive walk instead.
    private static let gaugeRescanEveryNTicks = 10

    /// Ticks (60s each, one per periodic-flush loop iteration) since the
    /// last full gauge rescan. Starts at 0 — `start()` already performs
    /// its own rescan before the periodic loop's first tick, so counting
    /// up from zero here means the next filesystem rescan is a full
    /// `gaugeRescanEveryNTicks`-tick interval away, not immediate.
    private var gaugeRescanTickCount = 0

    /// Mirrors whatever `lastError` `refreshBudgets` itself most recently
    /// set (nil once it last succeeded). Lets a later successful config
    /// load clear `lastError` WITHOUT clobbering an unrelated error set
    /// by another path (initial scan, reader, refresh, cache write) that
    /// may have landed in `lastError` since — we only clear when
    /// `lastError` still equals the error we ourselves put there.
    private var lastLimitsError: String? = nil

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

    /// Re-evaluates budgets against `limits.toml`. Cheap: one small file
    /// read plus the pure `Limits.evaluate` — no filesystem walk. Safe
    /// to call every periodic-flush tick (60s), which is what closes
    /// final-review.md I-1: a budget crossing `warn_pct` or 100%
    /// mid-session now shows up within one tick instead of waiting for
    /// `rescanPlanGauges`'s much slower cadence.
    ///
    /// A malformed `limits.toml` degrades the budget rows to "no rows",
    /// never a crash or a stalled UI, but surfaces via `lastError` so the
    /// user isn't left wondering why the budget gauges vanished — and
    /// clears again the next time the file loads cleanly (see
    /// `lastLimitsError`), so a fixed typo doesn't leave a stale error
    /// banner up until the next manual Refresh. A missing config file is
    /// NOT an error — `Limits.load` returns zero limits for that case,
    /// which is the normal unconfigured state.
    ///
    /// `configPath` defaults to `Limits.defaultConfigPath()`; the
    /// parameter exists so tests can point at a temp file instead of the
    /// user's real `~/.config/claudecounter/limits.toml`.
    public func refreshBudgets(now: Date = Date(), configPath: String = Limits.defaultConfigPath()) async {
        let daily = totals.daily
        let statuses: [LimitStatus]
        do {
            let cfg = try Limits.load(path: configPath)
            // ISO-8601 identifier for Monday-first week numbering matching
            // Go's ISOWeek, but the CURRENT time zone — `DailyTotal.day` is a
            // local calendar day, so evaluating in UTC would misalign the day
            // key at the local midnight boundary. `Calendar.current` is wrong
            // here too: it is Gregorian and typically Sunday-first, which
            // numbers weeks differently from the Go side.
            var cal = Calendar(identifier: .iso8601)
            cal.timeZone = .current
            statuses = Limits.evaluate(daily: daily, config: cfg, now: now, calendar: cal)
            self.warnPct = cfg.warnPct
            // A fixed limits.toml shouldn't leave a stale error banner
            // up until the next manual Refresh — but only clear it if
            // it's still the error WE set; some other subsystem may have
            // set a more recent, unrelated one since.
            if lastError != nil && lastError == lastLimitsError { self.lastError = nil }
            lastLimitsError = nil
        } catch LimitsError.malformed(let line) {
            let message = "limits.toml is malformed near: \"\(line)\""
            self.lastError = message
            lastLimitsError = message
            statuses = []
            // An unusable config falls back to the same default the TUI
            // uses for a missing file — never left at a stale, possibly
            // stricter, value from the last good load.
            self.warnPct = LimitsConfig.defaultWarnPct
        } catch {
            let message = "Failed to load limits.toml: \(error)"
            self.lastError = message
            lastLimitsError = message
            statuses = []
            self.warnPct = LimitsConfig.defaultWarnPct
        }
        self.limitStatuses = statuses
    }

    /// Rescans the vendor plan logs (Codex, Grok). Expensive: a
    /// recursive filesystem walk of `~/.codex/sessions` (up to 50
    /// whole-file reads) plus reading the Grok log, so it stays off the
    /// main actor; only the assignment hops back. Runs far less often
    /// than `refreshBudgets` — see `gaugeRescanEveryNTicks`.
    ///
    /// Vendor scans never throw: `PlanLimits.scanCodex` / `scanGrok`
    /// treat a missing or unreadable log as "no rows" for that vendor,
    /// not a failure.
    public func rescanPlanGauges(now: Date = Date()) async {
        let gauges = await Task.detached(priority: .utility) { () -> [PlanGauge] in
            PlanLimits.scanCodex(root: PlanLimits.defaultCodexRoot(), now: now)
                + PlanLimits.scanGrok(path: PlanLimits.defaultGrokLog(), now: now)
        }.value
        self.planGauges = gauges
    }

    /// Full gauge refresh: budgets + vendor rescan together. Used where
    /// both are wanted unconditionally — `start()`'s first paint and the
    /// popover's manual Refresh — as opposed to the periodic-flush loop,
    /// which calls `refreshBudgets` every tick and `rescanPlanGauges`
    /// only every `gaugeRescanEveryNTicks` ticks (see
    /// `startPeriodicFlush`).
    private func refreshGauges(now: Date = Date()) async {
        await refreshBudgets(now: now)
        await rescanPlanGauges(now: now)
    }

    // MARK: Watcher loop

    /// One `FSEventStream` watching every reachable configured root at
    /// once (see `Watcher.init(roots:)`) — mirrors the Go pipeline's
    /// single `watcher.New()` with one `AddTree` call per source,
    /// rather than one OS-level watcher per source. `handle(change:)`
    /// then maps each reported path back to its owning `SourceEntry`,
    /// same as Go's `sourceForPath`.
    private func startWatcher() {
        let roots = sources.map { $0.root }.filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else { return }
        let w = Watcher(roots: roots)
        let stream = w.start()
        self.watcher = w

        watcherTask = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                await self.handle(change: change)
            }
        }
    }

    /// Tears down the current watcher/task and starts a fresh one
    /// against the current `sources`. Used by `refresh()` and
    /// `reloadSources()`, whose root set may have just changed —
    /// without cancelling the old task first, its `for await` loop (and
    /// the FSEventStream underneath it) would keep running alongside
    /// the new one.
    private func restartWatcher() {
        watcherTask?.cancel()
        watcher?.stop()
        watcher = nil
        startWatcher()
    }

    /// Finds the configured source whose root contains `path`, resolving
    /// symlinks on both sides first — macOS commonly reports FSEvents
    /// paths through their real (symlink-resolved) form (e.g. `/tmp` →
    /// `/private/tmp`), so a literal-string prefix match against the
    /// configured root can miss even when the file genuinely is under
    /// that root. Mirrors the Go pipeline's `sourceForPath`.
    ///
    /// The common case — exactly one configured source — skips the
    /// prefix match entirely and always resolves to that source. That
    /// keeps the no-`sources.toml` path exactly as forgiving as it was
    /// before multi-source support existed: previously nothing checked
    /// the watcher's reported path against `projectsRoot` at all, and
    /// this preserves that for the single-source case rather than
    /// introducing a new way for it to (mis)fire on a symlink quirk.
    ///
    /// This shortcut is watcher-only — used here, in `handle(change:)`,
    /// and nowhere else. `seedReaders` needs the opposite forgiveness
    /// rule (drop an unmatched path rather than assign it) and calls
    /// `matchSource` directly instead; see its doc comment.
    private func sourceForPath(_ path: String) -> SourceEntry? {
        if sources.count == 1 { return sources[0] }
        return Self.matchSource(for: path, in: sources)
    }

    /// The prefix-match core of `sourceForPath`, without its
    /// single-source shortcut. `seedReaders` MUST go through this
    /// directly rather than `sourceForPath`: the shortcut hands ANY
    /// path to the lone reader regardless of whether it's actually
    /// under that source's root, which — for seeding, unlike the
    /// watcher — reopens the exact offset collision Task 10 fixed. A
    /// cached path outside the one configured source's root would be
    /// seeded into that reader anyway instead of being dropped, so a
    /// later `mergedOffsets()` could persist an offset behind what was
    /// actually read, causing a re-read (and, for events missing a
    /// `messageID`/`requestID`, a re-count) on the next launch. See
    /// final-review.md item 3 /
    /// `test_appState_seedReaders_singleSource_dropsPathOutsideRoot`.
    private static func matchSource(for path: String, in sources: [SourceEntry]) -> SourceEntry? {
        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        var best: SourceEntry? = nil
        var bestLen = -1
        for s in sources {
            let resolvedRoot = (s.root as NSString).resolvingSymlinksInPath
            let matches = resolvedPath == resolvedRoot || resolvedPath.hasPrefix(resolvedRoot + "/")
            if matches && resolvedRoot.count > bestLen {
                bestLen = resolvedRoot.count
                best = s
            }
        }
        return best
    }

    private func handle(change: FileChange) async {
        guard let source = sourceForPath(change.path), let r = readers[source.id] else {
            // Should not happen: the watcher only ever watches configured
            // roots. Surface it rather than silently dropping the event
            // — a swallowed change here is spend silently lost, not just
            // mis-attributed.
            self.lastError = "watcher: \(change.path) does not match any configured source; ignoring"
            return
        }
        switch change.kind {
        case .create, .modify:
            do {
                let events = try await r.onChange(path: change.path, source: source)
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
            await r.forget(path: change.path)
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
                // Cheap: a limits.toml read plus the pure Limits.evaluate,
                // no filesystem walk. Every tick, so a budget crossing
                // warn_pct or 100% escalates within one minute rather
                // than waiting for the vendor rescan below
                // (final-review.md I-1).
                await self.refreshBudgets()
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
                    // reads the Grok log. Runs far less often than
                    // refreshBudgets above needs.
                    await self.rescanPlanGauges()
                }
                await self.flushCache()
            }
        }
    }

    private func flushCache() async {
        let offsets = await mergedOffsets()
        let parseErrors = await totalParseErrors()
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
