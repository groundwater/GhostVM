import XCTest
@testable import GhostVMKit

final class SharedVmnetIPv4PoolTests: XCTestCase {
    func testAllocatesContainersAfterGatewayAndVMLease() throws {
        var pool = SharedVmnetIPv4Pool(
            subnet: 0xc0a85000,
            mask: 0xffffff00,
            prefixLength: 24
        )

        XCTAssertEqual(try pool.allocate(endpointIdentifier: "one"), 0xc0a85003)
        XCTAssertEqual(try pool.allocate(endpointIdentifier: "two"), 0xc0a85004)
        XCTAssertEqual(SharedVmnetIPv4Pool.string(for: 0xc0a85003), "192.168.80.3")
    }

    func testAllocationIsIdempotentAndReleasedAddressIsReused() throws {
        var pool = SharedVmnetIPv4Pool(
            subnet: 0xc0a85000,
            mask: 0xfffffff8,
            prefixLength: 29
        )

        let firstAddress = try pool.allocate(endpointIdentifier: "one")
        let firstMAC = SharedVmnetIPv4Pool.macAddress(for: firstAddress)
        XCTAssertEqual(firstAddress, 0xc0a85003)
        XCTAssertEqual(try pool.allocate(endpointIdentifier: "one"), 0xc0a85003)
        pool.release(endpointIdentifier: "one")
        let reusedAddress = try pool.allocate(endpointIdentifier: "two")
        XCTAssertEqual(reusedAddress, 0xc0a85003)
        XCTAssertEqual(SharedVmnetIPv4Pool.macAddress(for: reusedAddress), firstMAC)
    }

    func testDifferentAddressesHaveDifferentMACAddresses() throws {
        var pool = SharedVmnetIPv4Pool(subnet: 0xc0a85000, mask: 0xffffff00, prefixLength: 24)
        let firstAddress = try pool.allocate(endpointIdentifier: "one")
        let secondAddress = try pool.allocate(endpointIdentifier: "two")

        XCTAssertNotEqual(
            SharedVmnetIPv4Pool.macAddress(for: firstAddress),
            SharedVmnetIPv4Pool.macAddress(for: secondAddress)
        )
    }

    func testMACAddressIsStableAcrossPoolRecreation() throws {
        var firstPool = SharedVmnetIPv4Pool(subnet: 0xc0a87100, mask: 0xffffff00, prefixLength: 24)
        var recreatedPool = SharedVmnetIPv4Pool(subnet: 0xc0a87100, mask: 0xffffff00, prefixLength: 24)
        let firstAddress = try firstPool.allocate(endpointIdentifier: "first-container")
        let recreatedAddress = try recreatedPool.allocate(endpointIdentifier: "replacement-container")

        XCTAssertEqual(recreatedAddress, firstAddress)
        XCTAssertEqual(
            SharedVmnetIPv4Pool.macAddress(for: recreatedAddress),
            SharedVmnetIPv4Pool.macAddress(for: firstAddress)
        )
        XCTAssertEqual(SharedVmnetIPv4Pool.macAddress(for: 0xc0a87180), "02:00:c0:a8:71:80")
    }

    func testRejectsSubnetWithoutContainerAddresses() {
        var pool = SharedVmnetIPv4Pool(
            subnet: 0xc0a85000,
            mask: 0xfffffffc,
            prefixLength: 30
        )

        XCTAssertThrowsError(try pool.allocate(endpointIdentifier: "one")) { error in
            XCTAssertEqual(error as? SharedVmnetIPv4PoolError, .exhausted)
        }
    }

    func testReservesUpperHalfForDirectContainerSessions() throws {
        var pool = SharedVmnetIPv4Pool(
            subnet: 0xc0a85000,
            mask: 0xffffff00,
            prefixLength: 24
        )

        var addresses: [UInt32] = []
        while let address = try? pool.allocate(endpointIdentifier: "endpoint-\(addresses.count)") {
            addresses.append(address)
        }
        XCTAssertEqual(addresses.first, 0xc0a85003)
        XCTAssertEqual(addresses.last, 0xc0a8507f)
        XCTAssertEqual(addresses.count, 125)
    }

    func testFullIPv4RangeDoesNotOverflow() throws {
        var pool = SharedVmnetIPv4Pool(subnet: 0, mask: 0, prefixLength: 0)

        XCTAssertEqual(try pool.allocate(endpointIdentifier: "one"), 3)
    }
}
