import XCTest
@testable import GhostVMKit

final class ClipboardSyncModeTests: XCTestCase {
    func testBidirectionalAllowsBothDirections() {
        let mode = ClipboardSyncMode.bidirectional
        XCTAssertTrue(mode.allowsHostToGuest)
        XCTAssertTrue(mode.allowsGuestToHost)
    }

    func testHostToGuestAllowsOnlyHostToGuest() {
        let mode = ClipboardSyncMode.hostToGuest
        XCTAssertTrue(mode.allowsHostToGuest)
        XCTAssertFalse(mode.allowsGuestToHost)
    }

    func testGuestToHostAllowsOnlyGuestToHost() {
        let mode = ClipboardSyncMode.guestToHost
        XCTAssertFalse(mode.allowsHostToGuest)
        XCTAssertTrue(mode.allowsGuestToHost)
    }

    func testDisabledAllowsNeither() {
        let mode = ClipboardSyncMode.disabled
        XCTAssertFalse(mode.allowsHostToGuest)
        XCTAssertFalse(mode.allowsGuestToHost)
    }

    func testAllCasesCount() {
        XCTAssertEqual(ClipboardSyncMode.allCases.count, 4)
    }

    func testDisplayNamesNonEmpty() {
        for mode in ClipboardSyncMode.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, "\(mode.rawValue) has empty displayName")
        }
    }

    func testRawValueRoundTrip() {
        for mode in ClipboardSyncMode.allCases {
            let roundTripped = ClipboardSyncMode(rawValue: mode.rawValue)
            XCTAssertEqual(roundTripped, mode)
        }
    }

    func testCodableRoundTrip() throws {
        for mode in ClipboardSyncMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(ClipboardSyncMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}
