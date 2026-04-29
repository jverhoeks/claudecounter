import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

/// Three-state model of "should this app launch at login".
/// Mirrors the relevant subset of `SMAppService.Status`:
/// - `.disabled` — not registered (off, default for fresh installs)
/// - `.enabled` — registered and approved by the user
/// - `.requiresApproval` — registered but the user hasn't approved
///   yet in System Settings → General → Login Items. macOS shows a
///   prompt the first time `register()` is called.
public enum LaunchAtLoginState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unsupported   // platforms without SMAppService (non-macOS, pre-13)
}

/// Test seam over `SMAppService.mainApp`. Production wires up
/// `SMAppServiceLaunchAtLogin`; tests inject `InMemoryLaunchAtLoginService`.
public protocol LaunchAtLoginService: Sendable {
    func currentState() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) throws
}

/// Production implementation, backed by `SMAppService.mainApp`.
/// Available on macOS 13+; on earlier macOS or non-Apple platforms the
/// methods report `.unsupported` and silently ignore writes.
public struct SMAppServiceLaunchAtLogin: LaunchAtLoginService {

    public init() {}

    public func currentState() -> LaunchAtLoginState {
        #if canImport(ServiceManagement) && os(macOS)
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:           return .enabled
            case .notRegistered:     return .disabled
            case .requiresApproval:  return .requiresApproval
            case .notFound:          return .disabled
            @unknown default:        return .disabled
            }
        }
        return .unsupported
        #else
        return .unsupported
        #endif
    }

    public func setEnabled(_ enabled: Bool) throws {
        #if canImport(ServiceManagement) && os(macOS)
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
        #endif
    }
}

/// In-memory test double. Lets unit tests assert the controller's
/// reactive behaviour without touching the real launchd plist.
public final class InMemoryLaunchAtLoginService: LaunchAtLoginService, @unchecked Sendable {
    public var state: LaunchAtLoginState
    public var setEnabledError: Error?
    public private(set) var setEnabledCalls: [Bool] = []

    public init(initialState: LaunchAtLoginState = .disabled) {
        self.state = initialState
    }

    public func currentState() -> LaunchAtLoginState { state }

    public func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if let err = setEnabledError { throw err }
        state = enabled ? .enabled : .disabled
    }
}
