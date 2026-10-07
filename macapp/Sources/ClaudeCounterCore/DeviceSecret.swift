import Foundation
import Security

/// Where the Worker write token lives. It is a credential, so it stays
/// out of UserDefaults (plaintext plist) and goes in the Keychain.
public protocol DeviceSecretStore: Sendable {
    func readWriteToken() -> String?
    func saveWriteToken(_ token: String) throws
    func deleteWriteToken() throws
}

public enum DeviceSecretError: Error, Equatable {
    case keychain(OSStatus)
}

/// Generic-password item, service `ClaudeCounterBar.device`, account
/// `writeToken`. Never used from tests.
public final class KeychainDeviceSecretStore: DeviceSecretStore {
    static let service = "ClaudeCounterBar.device"
    static let account = "writeToken"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account]
    }

    public func readWriteToken() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func saveWriteToken(_ token: String) throws {
        let data = Data(token.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeviceSecretError.keychain(status) }
    }

    public func deleteWriteToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceSecretError.keychain(status)
        }
    }
}

/// Reads the underlying store once and answers from memory after that.
///
/// The Keychain item's access list trusts one code signature, and an
/// ad-hoc signed build gets a new one every time it is rebuilt, so each
/// read can raise an approval prompt. `publishDevice` used to read on
/// every publish — one prompt per publish for anyone who clicked "Allow"
/// rather than "Always Allow". Now it's at most one per launch. Whatever
/// the first read returns is kept, a denied read included, so a refusal
/// isn't re-asked on every tick; saving or deleting updates the copy.
public final class CachedDeviceSecretStore: DeviceSecretStore, @unchecked Sendable {
    private let base: DeviceSecretStore
    private let lock = NSLock()
    private var cached: String??

    public init(_ base: DeviceSecretStore) { self.base = base }

    public func readWriteToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let token = base.readWriteToken()
        cached = .some(token)
        return token
    }

    public func saveWriteToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try base.saveWriteToken(token)
        cached = .some(token)
    }

    public func deleteWriteToken() throws {
        lock.lock(); defer { lock.unlock() }
        try base.deleteWriteToken()
        cached = .some(nil)
    }
}

/// Test double.
public final class InMemoryDeviceSecretStore: DeviceSecretStore, @unchecked Sendable {
    private var token: String?
    public init(token: String? = nil) { self.token = token }
    public func readWriteToken() -> String? { token }
    public func saveWriteToken(_ token: String) throws { self.token = token }
    public func deleteWriteToken() throws { token = nil }
}
