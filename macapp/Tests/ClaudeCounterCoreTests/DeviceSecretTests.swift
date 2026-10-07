import XCTest
@testable import ClaudeCounterCore

final class DeviceSecretTests: XCTestCase {

    func test_inMemory_roundTripAndDelete() throws {
        let s = InMemoryDeviceSecretStore()
        XCTAssertNil(s.readWriteToken())
        try s.saveWriteToken("abc")
        XCTAssertEqual(s.readWriteToken(), "abc")
        try s.saveWriteToken("def")
        XCTAssertEqual(s.readWriteToken(), "def")
        try s.deleteWriteToken()
        XCTAssertNil(s.readWriteToken())
    }

    /// Counts reads so the test can see the Keychain is asked only once.
    private final class CountingStore: DeviceSecretStore, @unchecked Sendable {
        var token: String?
        var reads = 0
        init(_ token: String?) { self.token = token }
        func readWriteToken() -> String? { reads += 1; return token }
        func saveWriteToken(_ token: String) throws { self.token = token }
        func deleteWriteToken() throws { token = nil }
    }

    func test_cached_readsBaseOnceAndTracksWrites() throws {
        let base = CountingStore("abc")
        let s = CachedDeviceSecretStore(base)
        for _ in 0..<5 { XCTAssertEqual(s.readWriteToken(), "abc") }
        XCTAssertEqual(base.reads, 1)
        try s.saveWriteToken("def")
        XCTAssertEqual(s.readWriteToken(), "def")
        try s.deleteWriteToken()
        XCTAssertNil(s.readWriteToken())
        XCTAssertEqual(base.reads, 1)
    }

    func test_cached_keepsAMissingTokenToo() {
        let base = CountingStore(nil)
        let s = CachedDeviceSecretStore(base)
        XCTAssertNil(s.readWriteToken())
        XCTAssertNil(s.readWriteToken())
        XCTAssertEqual(base.reads, 1)
    }

    // The Keychain store is deliberately NOT exercised here: the test
    // runner would write into the developer's real login keychain.
    // It is verified manually through the popover.
}
