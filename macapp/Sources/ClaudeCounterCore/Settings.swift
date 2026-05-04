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

    public static let defaults = AppSettings(
        dockIconEnabled: true
    )

    public init(dockIconEnabled: Bool) {
        self.dockIconEnabled = dockIconEnabled
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

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppSettings {
        // First-run semantics: if the key is absent, fall through to
        // `AppSettings.defaults` so new users get the on-by-default
        // experience. Using `object(forKey:)` (not `bool(forKey:)`) is
        // important here — `bool(forKey:)` would silently coerce a
        // missing key to `false` and we'd ship the dock icon disabled.
        let dock: Bool
        if let raw = defaults.object(forKey: Self.dockIconKey) as? Bool {
            dock = raw
        } else {
            dock = AppSettings.defaults.dockIconEnabled
        }
        return AppSettings(dockIconEnabled: dock)
    }

    public func save(_ settings: AppSettings) {
        defaults.set(settings.dockIconEnabled, forKey: Self.dockIconKey)
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
