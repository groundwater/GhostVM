import XCTest
@testable import GhostVMKit

final class PortForwardConfigTests: XCTestCase {
    func testEncodeDecode() throws {
        let config = PortForwardConfig(hostPort: 8080, guestPort: 80)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(PortForwardConfig.self, from: data)

        XCTAssertEqual(decoded.hostPort, config.hostPort)
        XCTAssertEqual(decoded.guestPort, config.guestPort)
        XCTAssertEqual(decoded.enabled, config.enabled)
        XCTAssertEqual(decoded.id, config.id)
    }

    func testDefaultEnabled() {
        let config = PortForwardConfig(hostPort: 3000, guestPort: 3000)
        XCTAssertTrue(config.enabled)
    }

    func testEquality() {
        let id = UUID()
        let a = PortForwardConfig(id: id, hostPort: 8080, guestPort: 80)
        let b = PortForwardConfig(id: id, hostPort: 8080, guestPort: 80)
        XCTAssertEqual(a, b)
    }

    func testInequality() {
        let a = PortForwardConfig(hostPort: 8080, guestPort: 80)
        let b = PortForwardConfig(hostPort: 8080, guestPort: 443)
        XCTAssertNotEqual(a, b)
    }

    func testHashable() {
        let id = UUID()
        let a = PortForwardConfig(id: id, hostPort: 8080, guestPort: 80)
        let b = PortForwardConfig(id: id, hostPort: 8080, guestPort: 80)

        var set = Set<PortForwardConfig>()
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 1)
    }

    func testDisabledConfig() {
        let config = PortForwardConfig(hostPort: 22, guestPort: 22, enabled: false)
        XCTAssertFalse(config.enabled)
    }
}
