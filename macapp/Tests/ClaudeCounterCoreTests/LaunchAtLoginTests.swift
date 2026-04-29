import XCTest
@testable import ClaudeCounterCore

final class LaunchAtLoginTests: XCTestCase {

    // MARK: - InMemoryLaunchAtLoginService (the test double itself)

    func test_inMemory_defaultsToDisabled() {
        let svc = InMemoryLaunchAtLoginService()
        XCTAssertEqual(svc.currentState(), .disabled)
    }

    func test_inMemory_setEnabledTrue_flipsState_andRecordsCall() throws {
        let svc = InMemoryLaunchAtLoginService()
        try svc.setEnabled(true)
        XCTAssertEqual(svc.currentState(), .enabled)
        XCTAssertEqual(svc.setEnabledCalls, [true])
    }

    func test_inMemory_setEnabledFalse_flipsBackToDisabled() throws {
        let svc = InMemoryLaunchAtLoginService(initialState: .enabled)
        try svc.setEnabled(false)
        XCTAssertEqual(svc.currentState(), .disabled)
        XCTAssertEqual(svc.setEnabledCalls, [false])
    }

    func test_inMemory_setEnabledError_propagates_andLeavesStateUnchanged() {
        let svc = InMemoryLaunchAtLoginService(initialState: .disabled)
        struct Boom: Error {}
        svc.setEnabledError = Boom()

        XCTAssertThrowsError(try svc.setEnabled(true))
        // setEnabledCalls still records the attempt — useful for tests
        // that want to assert the controller tried, even if it failed.
        XCTAssertEqual(svc.setEnabledCalls, [true])
        // The injected error happens before the in-memory state flip,
        // so state is the initial value.
        XCTAssertEqual(svc.currentState(), .disabled)
    }

    func test_inMemory_requiresApprovalState_isVisible() {
        // The controller should be able to read this state even though
        // it can never SET it directly (only macOS produces it).
        let svc = InMemoryLaunchAtLoginService(initialState: .requiresApproval)
        XCTAssertEqual(svc.currentState(), .requiresApproval)
    }

    // MARK: - SMAppServiceLaunchAtLogin (smoke test only)

    /// Verify the production implementation can be instantiated and
    /// queried without throwing on the test runner. We don't attempt
    /// `register()` here — that would actually wire the test runner
    /// into launchd as a login item, which is a bad side effect.
    func test_smAppService_currentState_doesNotCrash() {
        let svc = SMAppServiceLaunchAtLogin()
        let state = svc.currentState()
        // Any of the four enum cases is acceptable; we just want to
        // confirm the call returns rather than crashing.
        switch state {
        case .disabled, .enabled, .requiresApproval, .unsupported:
            break
        }
    }
}
