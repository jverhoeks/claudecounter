import Foundation

/// User-facing app settings. Persisted out of process via `SettingsStore`
/// so a relaunch keeps the user's preferences. Keep this struct small
/// and Codable-friendly — every new key needs a default and a UserDefaults
/// fallback path so first-run users get sensible behaviour without ever
/// opening the ⚙ menu.
public struct AppSettings: Equatable, Sendable {

    /// Whether the app shows up in the Dock with a red spend badge.
    /// Default: `true` (the feature is on out of the box).
    public var dockIconEnabled: Bool

    /// Whether crossing a session warning threshold posts a macOS
    /// notification. When off, warnings stay in-app (popover badges + the
    /// red menu-bar capsule). Default: `true`.
    public var notificationsEnabled: Bool

    /// Warn when a session's main-turn count exceeds this. Default 150.
    public var turnWarnCount: Int
    /// Warn when context / window exceeds this fraction. Default 0.80.
    public var contextWarnPct: Double
    /// Warn when cache-creation cost in the trailing 5 minutes (a rate,
    /// not a session total) exceeds this many USD. Default 2.00.
    public var cacheWarnUSD: Double
    /// A session counts as "active" if its last turn is within this many
    /// minutes. Default 30.
    public var activeWindowMinutes: Int

    public static let defaults = AppSettings(
        dockIconEnabled: true,
        notificationsEnabled: true,
        turnWarnCount: 150,
        contextWarnPct: 0.80,
        cacheWarnUSD: 2.00,
        activeWindowMinutes: 30
    )

    public init(dockIconEnabled: Bool,
                notificationsEnabled: Bool = true,
                turnWarnCount: Int = 150,
                contextWarnPct: Double = 0.80,
                cacheWarnUSD: Double = 2.00,
                activeWindowMinutes: Int = 30) {
        self.dockIconEnabled = dockIconEnabled
        self.notificationsEnabled = notificationsEnabled
        self.turnWarnCount = turnWarnCount
        self.contextWarnPct = contextWarnPct
        self.cacheWarnUSD = cacheWarnUSD
        self.activeWindowMinutes = activeWindowMinutes
    }

    /// The tracker thresholds implied by these settings.
    public var sessionThresholds: SessionThresholds {
        SessionThresholds(
            activeWindow: TimeInterval(activeWindowMinutes * 60),
            turnWarnCount: turnWarnCount,
            contextWarnPct: contextWarnPct,
            cacheWarnUSD: cacheWarnUSD
        )
    }
}

/// Storage seam over `UserDefaults`. Production wires up
/// `UserDefaultsSettingsStore`; tests inject `InMemorySettingsStore`.
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// `UserDefaults`-backed production store. Reads/writes one key per
/// setting under a `ClaudeCounterBar.AppSettings.*` namespace so the
/// keys are easy to spot (and easy to clear) with `defaults delete`.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {

    static let dockIconKey = "ClaudeCounterBar.AppSettings.dockIconEnabled"
    static let notificationsKey = "ClaudeCounterBar.AppSettings.notificationsEnabled"
    static let turnWarnKey = "ClaudeCounterBar.AppSettings.turnWarnCount"
    static let contextWarnKey = "ClaudeCounterBar.AppSettings.contextWarnPct"
    static let cacheWarnKey = "ClaudeCounterBar.AppSettings.cacheWarnUSD"
    static let activeWindowKey = "ClaudeCounterBar.AppSettings.activeWindowMinutes"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        // First-run semantics: if a key is absent, fall through to
        // `AppSettings.defaults` so new users get sensible behaviour.
        // Using `object(forKey:)` (not `bool(forKey:)`) is important —
        // `bool(forKey:)` would silently coerce a missing key to `false`
        // and we'd ship features disabled.
        let d = AppSettings.defaults
        return AppSettings(
            dockIconEnabled: (defaults.object(forKey: Self.dockIconKey) as? Bool) ?? d.dockIconEnabled,
            notificationsEnabled: (defaults.object(forKey: Self.notificationsKey) as? Bool) ?? d.notificationsEnabled,
            turnWarnCount: (defaults.object(forKey: Self.turnWarnKey) as? Int) ?? d.turnWarnCount,
            contextWarnPct: (defaults.object(forKey: Self.contextWarnKey) as? Double) ?? d.contextWarnPct,
            cacheWarnUSD: (defaults.object(forKey: Self.cacheWarnKey) as? Double) ?? d.cacheWarnUSD,
            activeWindowMinutes: (defaults.object(forKey: Self.activeWindowKey) as? Int) ?? d.activeWindowMinutes
        )
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.dockIconEnabled, forKey: Self.dockIconKey)
        defaults.set(settings.notificationsEnabled, forKey: Self.notificationsKey)
        defaults.set(settings.turnWarnCount, forKey: Self.turnWarnKey)
        defaults.set(settings.contextWarnPct, forKey: Self.contextWarnKey)
        defaults.set(settings.cacheWarnUSD, forKey: Self.cacheWarnKey)
        defaults.set(settings.activeWindowMinutes, forKey: Self.activeWindowKey)
    }
}

/// In-memory test double.
public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {

    private var state: AppSettings
    public private(set) var saveCalls: [AppSettings] = []

    public init(initial: AppSettings = .defaults) {
        self.state = initial
    }

    public func load() -> AppSettings { state }

    public func save(_ settings: AppSettings) {
        state = settings
        saveCalls.append(settings)
    }
}
