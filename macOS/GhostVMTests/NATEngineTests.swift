import XCTest
@testable import GhostVMKit

final class NATEngineTests: XCTestCase {

    func testOutboundMapping() {
        let engine = NATEngine()
        let entry = engine.outboundMapping(
            proto: IPProto.tcp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
            dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80
        )
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry!.originalSrcIP, IPv4Address(10, 100, 0, 10))
        XCTAssertEqual(entry!.originalSrcPort, 54321)
        XCTAssertEqual(entry!.mappedPort, 10000) // first allocated
        XCTAssertEqual(engine.entryCount, 1)
    }

    func testSameFlowReturnsSameMapping() {
        let engine = NATEngine()
        let entry1 = engine.outboundMapping(
            proto: IPProto.tcp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
            dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80
        )
        let entry2 = engine.outboundMapping(
            proto: IPProto.tcp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
            dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80
        )
        XCTAssertEqual(entry1!.mappedPort, entry2!.mappedPort)
        XCTAssertEqual(engine.entryCount, 1)
    }

    func testDifferentFlowsGetDifferentPorts() {
        let engine = NATEngine()
        let entry1 = engine.outboundMapping(
            proto: IPProto.tcp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
            dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80
        )
        let entry2 = engine.outboundMapping(
            proto: IPProto.tcp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54322,
            dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80
        )
        XCTAssertNotEqual(entry1!.mappedPort, entry2!.mappedPort)
        XCTAssertEqual(engine.entryCount, 2)
    }

    func testInboundLookup() {
        let engine = NATEngine()
        let entry = engine.outboundMapping(
            proto: IPProto.udp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 12345,
            dstIP: IPv4Address(8, 8, 8, 8), dstPort: 53
        )!

        let found = engine.inboundLookup(proto: IPProto.udp, mappedPort: entry.mappedPort)
        XCTAssertNotNil(found)
        XCTAssertEqual(found!.originalSrcIP, IPv4Address(10, 100, 0, 10))
        XCTAssertEqual(found!.originalSrcPort, 12345)
    }

    func testInboundLookupNotFound() {
        let engine = NATEngine()
        XCTAssertNil(engine.inboundLookup(proto: IPProto.udp, mappedPort: 9999))
    }

    func testRemoveEntry() {
        let engine = NATEngine()
        let _ = engine.outboundMapping(
            proto: IPProto.tcp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
            dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80
        )
        XCTAssertEqual(engine.entryCount, 1)

        engine.removeEntry(proto: IPProto.tcp,
                           srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
                           dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80)
        XCTAssertEqual(engine.entryCount, 0)
    }

    func testTCPStateTracking() {
        let engine = NATEngine()
        let _ = engine.outboundMapping(
            proto: IPProto.tcp,
            srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
            dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80
        )

        // SYN-ACK should move to established
        engine.updateTCPState(proto: IPProto.tcp,
                              srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
                              dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80,
                              flags: TCPHeader.ACK)

        // RST should move to closed
        engine.updateTCPState(proto: IPProto.tcp,
                              srcIP: IPv4Address(10, 100, 0, 10), srcPort: 54321,
                              dstIP: IPv4Address(93, 184, 216, 34), dstPort: 80,
                              flags: TCPHeader.RST)

        // Entry should still exist (cleanup removes it)
        XCTAssertEqual(engine.entryCount, 1)
    }

    func testStopClearsAll() {
        let engine = NATEngine()
        for i: UInt16 in 0..<5 {
            _ = engine.outboundMapping(
                proto: IPProto.udp,
                srcIP: IPv4Address(10, 100, 0, 10), srcPort: 10000 + i,
                dstIP: IPv4Address(8, 8, 8, 8), dstPort: 53
            )
        }
        XCTAssertEqual(engine.entryCount, 5)
        engine.stop()
        XCTAssertEqual(engine.entryCount, 0)
    }
}
