import XCTest
@testable import ClaudeCounterCore

final class SettingsTests: XCTestCase {

    // MARK: - AppSettings defaults

    func test_appSettings_defaults_dockIconEnabledTrue() {
        // The user explicitly asked for "on by default" — guard that
        // contract here so a future refactor can't quietly flip it.
        XCTAssertTrue(AppSettings.defaults.dockIconEnabled)
    }

    // MARK: - InMemorySettingsStore

    func test_inMemoryStore_loadReturnsInitial() {
        let store = InMemorySettingsStore(initial: AppSettings(dockIconEnabled: false))
        XCTAssertFalse(store.load().dockIconEnabled)
    }

    func test_inMemoryStore_saveRoundTrip() {
        let store = InMemorySettingsStore()
        store.save(AppSettings(dockIconEnabled: false))
        XCTAssertFalse(store.load().dockIconEnabled)
        XCTAssertEqual(store.saveCalls.count, 1)
    }

    // MARK: - UserDefaultsSettingsStore

    /// Helper: produce a UserDefaults bound to a unique suite name so
    /// tests don't stomp on the real .standard defaults or each other.
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "ccbar.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (d, suite)
    }

    func test_userDefaults_firstRun_dockIconDefaultsToTrue() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertTrue(store.load().dockIconEnabled,
                      "first-run users must get the dock icon ON")
    }

    func test_userDefaults_savedFalse_persists() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        store.save(AppSettings(dockIconEnabled: false))

        // Read back through a fresh store instance to prove we hit
        // UserDefaults rather than an in-memory cache.
        let store2 = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertFalse(store2.load().dockIconEnabled)
    }

    func test_userDefaults_savedTrue_persists() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsSettingsStore(defaults: defaults)
        // Save false, then back to true — proves the key was actually
        // written, not just that the default kicked in.
        store.save(AppSettings(dockIconEnabled: false))
        store.save(AppSettings(dockIconEnabled: true))

        let store2 = UserDefaultsSettingsStore(defaults: defaults)
        XCTAssertTrue(store2.load().dockIconEnabled)
    }
}
