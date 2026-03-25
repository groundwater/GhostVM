import XCTest
@testable import GhostTools

final class TunnelServerTests: XCTestCase {
    func testDisconnectErrnoClassification() {
        XCTAssertTrue(tunnelIsDisconnectErrno(ECONNRESET))
        XCTAssertTrue(tunnelIsDisconnectErrno(EPIPE))
        XCTAssertTrue(tunnelIsDisconnectErrno(ETIMEDOUT))
        XCTAssertFalse(tunnelIsDisconnectErrno(EINVAL))
    }

    func testOperationalBridgeErrorClassification() {
        XCTAssertTrue(tunnelIsOperationalBridgeError(AsyncVSockIOError.closed))
        XCTAssertTrue(tunnelIsOperationalBridgeError(AsyncVSockIOError.cancelled))
        XCTAssertTrue(tunnelIsOperationalBridgeError(AsyncVSockIOError.syscall(op: "read", errno: ECONNRESET)))
        XCTAssertFalse(tunnelIsOperationalBridgeError(AsyncVSockIOError.syscall(op: "read", errno: EINVAL)))
    }
}

