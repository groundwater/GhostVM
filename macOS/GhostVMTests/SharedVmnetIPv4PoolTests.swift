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

        XCTAssertEqual(try pool.allocate(endpointIdentifier: "one"), 0xc0a85003)
        XCTAssertEqual(try pool.allocate(endpointIdentifier: "one"), 0xc0a85003)
        pool.release(endpointIdentifier: "one")
        XCTAssertEqual(try pool.allocate(endpointIdentifier: "two"), 0xc0a85003)
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
}
