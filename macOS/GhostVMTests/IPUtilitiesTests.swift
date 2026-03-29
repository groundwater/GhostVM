import XCTest
@testable import GhostVMKit

final class IPUtilitiesTests: XCTestCase {

    // MARK: - MACAddress

    func testMACAddressParse() {
        let mac = MACAddress(string: "aa:bb:cc:dd:ee:ff")
        XCTAssertNotNil(mac)
        XCTAssertEqual(mac!.description, "aa:bb:cc:dd:ee:ff")
    }

    func testMACAddressInvalidParse() {
        XCTAssertNil(MACAddress(string: "invalid"))
        XCTAssertNil(MACAddress(string: "aa:bb:cc"))
        XCTAssertNil(MACAddress(string: "gg:bb:cc:dd:ee:ff"))
    }

    func testMACAddressBroadcast() {
        XCTAssertTrue(MACAddress.broadcast.isBroadcast)
        XCTAssertFalse(MACAddress.zero.isBroadcast)
    }

    func testMACAddressData() {
        let mac = MACAddress(0x01, 0x02, 0x03, 0x04, 0x05, 0x06)
        let data = mac.data
        XCTAssertEqual(data, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))

        let restored = MACAddress(data: data)
        XCTAssertEqual(restored, mac)
    }

    func testMACAddressEquality() {
        let a = MACAddress(string: "aa:bb:cc:dd:ee:ff")!
        let b = MACAddress(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF)
        XCTAssertEqual(a, b)
    }

    // MARK: - IPv4Address

    func testIPv4Parse() {
        let ip = IPv4Address(string: "10.0.0.1")
        XCTAssertNotNil(ip)
        XCTAssertEqual(ip!.description, "10.0.0.1")
    }

    func testIPv4InvalidParse() {
        XCTAssertNil(IPv4Address(string: "invalid"))
        XCTAssertNil(IPv4Address(string: "10.0.0"))
        XCTAssertNil(IPv4Address(string: "256.0.0.1"))
    }

    func testIPv4OctetsRoundTrip() {
        let ip = IPv4Address(192, 168, 1, 100)
        let o = ip.octets
        XCTAssertEqual(o.0, 192)
        XCTAssertEqual(o.1, 168)
        XCTAssertEqual(o.2, 1)
        XCTAssertEqual(o.3, 100)
    }

    func testIPv4Data() {
        let ip = IPv4Address(10, 100, 0, 1)
        XCTAssertEqual(ip.data, Data([10, 100, 0, 1]))

        let restored = IPv4Address(data: ip.data)
        XCTAssertEqual(restored, ip)
    }

    func testIPv4Comparison() {
        let a = IPv4Address(string: "10.0.0.1")!
        let b = IPv4Address(string: "10.0.0.2")!
        XCTAssertTrue(a < b)
        XCTAssertFalse(b < a)
    }

    func testIPv4Advanced() {
        let ip = IPv4Address(string: "10.0.0.1")!
        let next = ip.advanced(by: 5)
        XCTAssertEqual(next.description, "10.0.0.6")
    }

    // MARK: - CIDRRange

    func testCIDRParse() {
        let cidr = CIDRRange(string: "10.100.0.0/24")
        XCTAssertNotNil(cidr)
        XCTAssertEqual(cidr!.network.description, "10.100.0.0")
        XCTAssertEqual(cidr!.prefixLength, 24)
    }

    func testCIDRInvalidParse() {
        XCTAssertNil(CIDRRange(string: "invalid"))
        XCTAssertNil(CIDRRange(string: "10.0.0.0"))
        XCTAssertNil(CIDRRange(string: "10.0.0.0/33"))
    }

    func testCIDRContains() {
        let cidr = CIDRRange(string: "10.100.0.0/24")!
        XCTAssertTrue(cidr.contains(IPv4Address(string: "10.100.0.1")!))
        XCTAssertTrue(cidr.contains(IPv4Address(string: "10.100.0.254")!))
        XCTAssertFalse(cidr.contains(IPv4Address(string: "10.100.1.1")!))
        XCTAssertFalse(cidr.contains(IPv4Address(string: "192.168.0.1")!))
    }

    func testCIDRContainsSlash16() {
        let cidr = CIDRRange(string: "172.16.0.0/16")!
        XCTAssertTrue(cidr.contains(IPv4Address(string: "172.16.0.1")!))
        XCTAssertTrue(cidr.contains(IPv4Address(string: "172.16.255.255")!))
        XCTAssertFalse(cidr.contains(IPv4Address(string: "172.17.0.1")!))
    }

    func testCIDRSubnetMask() {
        let cidr = CIDRRange(string: "10.0.0.0/24")!
        XCTAssertEqual(cidr.subnetMask.description, "255.255.255.0")

        let cidr16 = CIDRRange(string: "10.0.0.0/16")!
        XCTAssertEqual(cidr16.subnetMask.description, "255.255.0.0")
    }

    func testCIDRBroadcast() {
        let cidr = CIDRRange(string: "10.100.0.0/24")!
        XCTAssertEqual(cidr.broadcastAddress.description, "10.100.0.255")
    }

    func testCIDRFirstLastHost() {
        let cidr = CIDRRange(string: "10.100.0.0/24")!
        XCTAssertEqual(cidr.firstHost.description, "10.100.0.1")
        XCTAssertEqual(cidr.lastHost.description, "10.100.0.254")
    }

    func testCIDRNetworkMasking() {
        // "10.100.0.50/24" should normalize to "10.100.0.0/24"
        let cidr = CIDRRange(string: "10.100.0.50/24")!
        XCTAssertEqual(cidr.network.description, "10.100.0.0")
    }
}
