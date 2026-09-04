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

    // The Keychain store is deliberately NOT exercised here: the test
    // runner would write into the developer's real login keychain.
    // It is verified manually through the popover.
}
