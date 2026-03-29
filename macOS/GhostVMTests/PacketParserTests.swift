import XCTest
@testable import GhostVMKit

final class PacketParserTests: XCTestCase {

    // MARK: - ARP

    func testParseARPRequest() {
        // Build an ARP request frame manually
        let senderMAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        let senderIP = IPv4Address(10, 100, 0, 10)
        let targetIP = IPv4Address(10, 100, 0, 1)

        var frame = Data()
        // Ethernet header: dst=broadcast, src=senderMAC, type=ARP
        frame.append(MACAddress.broadcast.data)
        frame.append(senderMAC.data)
        frame.append(contentsOf: [0x08, 0x06]) // ARP
        // ARP payload
        frame.append(contentsOf: [0x00, 0x01]) // hw type
        frame.append(contentsOf: [0x08, 0x00]) // proto type
        frame.append(6) // hw size
        frame.append(4) // proto size
        frame.append(contentsOf: [0x00, 0x01]) // request
        frame.append(senderMAC.data)
        frame.append(senderIP.data)
        frame.append(MACAddress.zero.data) // target MAC unknown
        frame.append(targetIP.data)

        guard let parsed = PacketParser.parse(frame) else {
            XCTFail("Failed to parse ARP frame")
            return
        }

        if case .arp(let eth, let arp) = parsed {
            XCTAssertTrue(eth.dstMAC.isBroadcast)
            XCTAssertEqual(eth.srcMAC, senderMAC)
            XCTAssertEqual(eth.etherType, EtherType.arp)
            XCTAssertEqual(arp.opcode, ARPPacket.request)
            XCTAssertEqual(arp.senderIP, senderIP)
            XCTAssertEqual(arp.targetIP, targetIP)
        } else {
            XCTFail("Expected ARP packet")
        }
    }

    // MARK: - UDP

    func testParseUDPPacket() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let frame = PacketBuilder.udpFrame(
            dstMAC: MACAddress.broadcast, srcMAC: MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55),
            srcIP: IPv4Address(10, 100, 0, 10), dstIP: IPv4Address(10, 100, 0, 1),
            srcPort: 12345, dstPort: 53,
            payload: payload
        )

        guard let parsed = PacketParser.parse(frame) else {
            XCTFail("Failed to parse UDP frame")
            return
        }

        if case .udp(let eth, let ip, let udp) = parsed {
            XCTAssertEqual(eth.etherType, EtherType.ipv4)
            XCTAssertEqual(ip.proto, IPProto.udp)
            XCTAssertEqual(ip.srcIP, IPv4Address(10, 100, 0, 10))
            XCTAssertEqual(ip.dstIP, IPv4Address(10, 100, 0, 1))
            XCTAssertEqual(udp.srcPort, 12345)
            XCTAssertEqual(udp.dstPort, 53)
            XCTAssertEqual(udp.payload, payload)
        } else {
            XCTFail("Expected UDP packet")
        }
    }

    // MARK: - TCP

    func testParseTCPSYN() {
        let frame = PacketBuilder.tcpFrame(
            dstMAC: MACAddress(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF),
            srcMAC: MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55),
            srcIP: IPv4Address(10, 100, 0, 10), dstIP: IPv4Address(93, 184, 216, 34),
            srcPort: 54321, dstPort: 80,
            sequenceNumber: 1000, ackNumber: 0,
            flags: TCPHeader.SYN
        )

        guard let parsed = PacketParser.parse(frame) else {
            XCTFail("Failed to parse TCP frame")
            return
        }

        if case .tcp(_, let ip, let tcp) = parsed {
            XCTAssertEqual(ip.proto, IPProto.tcp)
            XCTAssertEqual(tcp.srcPort, 54321)
            XCTAssertEqual(tcp.dstPort, 80)
            XCTAssertEqual(tcp.sequenceNumber, 1000)
            XCTAssertTrue(tcp.isSYN)
            XCTAssertFalse(tcp.isACK)
            XCTAssertFalse(tcp.isFIN)
        } else {
            XCTFail("Expected TCP packet")
        }
    }

    // MARK: - ICMP

    func testParseICMPEchoRequest() {
        // Build ICMP echo request
        var icmpPayload = Data(capacity: 8)
        icmpPayload.append(ICMPHeader.echoRequest)
        icmpPayload.append(0) // code
        icmpPayload.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        icmpPayload.append(contentsOf: [0x00, 0x01]) // identifier
        icmpPayload.append(contentsOf: [0x00, 0x01]) // sequence

        let cksum = Checksum.internetChecksum(icmpPayload)
        icmpPayload[2] = UInt8(cksum >> 8)
        icmpPayload[3] = UInt8(cksum & 0xFF)

        let ipPacket = PacketBuilder.ipv4Packet(
            srcIP: IPv4Address(10, 100, 0, 10), dstIP: IPv4Address(10, 100, 0, 1),
            proto: IPProto.icmp, payload: icmpPayload
        )
        let frame = PacketBuilder.ethernetFrame(
            dst: MACAddress(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF),
            src: MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55),
            etherType: EtherType.ipv4, payload: ipPacket
        )

        guard let parsed = PacketParser.parse(frame) else {
            XCTFail("Failed to parse ICMP frame")
            return
        }

        if case .icmp(_, let ip, let icmp) = parsed {
            XCTAssertEqual(ip.proto, IPProto.icmp)
            XCTAssertEqual(icmp.type, ICMPHeader.echoRequest)
            XCTAssertEqual(icmp.code, 0)
        } else {
            XCTFail("Expected ICMP packet")
        }
    }

    // MARK: - Malformed

    func testTruncatedFrame() {
        XCTAssertNil(PacketParser.parse(Data([0x00, 0x01, 0x02])))
    }

    func testTruncatedARPPayload() {
        var frame = Data()
        frame.append(MACAddress.broadcast.data)
        frame.append(MACAddress.zero.data)
        frame.append(contentsOf: [0x08, 0x06]) // ARP
        frame.append(contentsOf: [0x00, 0x01]) // just 2 bytes of ARP - truncated
        XCTAssertNil(PacketParser.parse(frame))
    }

    func testTruncatedIPv4() {
        var frame = Data()
        frame.append(MACAddress.broadcast.data)
        frame.append(MACAddress.zero.data)
        frame.append(contentsOf: [0x08, 0x00]) // IPv4
        frame.append(contentsOf: [0x45, 0x00]) // just 2 bytes of IPv4 - truncated
        XCTAssertNil(PacketParser.parse(frame))
    }

    func testUnknownEtherType() {
        var frame = Data()
        frame.append(MACAddress.broadcast.data)
        frame.append(MACAddress.zero.data)
        frame.append(contentsOf: [0xFF, 0xFF]) // unknown
        frame.append(Data([0x00]))

        let parsed = PacketParser.parse(frame)
        if case .unknownEther = parsed {
            // expected
        } else {
            XCTFail("Expected unknownEther")
        }
    }

    // MARK: - Round-trip

    func testBuildAndParseRoundTrip() {
        let srcMAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        let dstMAC = MACAddress(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF)
        let srcIP = IPv4Address(192, 168, 1, 100)
        let dstIP = IPv4Address(8, 8, 8, 8)
        let payload = Data("Hello, World!".utf8)

        let frame = PacketBuilder.udpFrame(
            dstMAC: dstMAC, srcMAC: srcMAC,
            srcIP: srcIP, dstIP: dstIP,
            srcPort: 5000, dstPort: 53,
            payload: payload
        )

        guard case .udp(let eth, let ip, let udp) = PacketParser.parse(frame) else {
            XCTFail("Round-trip failed")
            return
        }

        XCTAssertEqual(eth.srcMAC, srcMAC)
        XCTAssertEqual(eth.dstMAC, dstMAC)
        XCTAssertEqual(ip.srcIP, srcIP)
        XCTAssertEqual(ip.dstIP, dstIP)
        XCTAssertEqual(udp.srcPort, 5000)
        XCTAssertEqual(udp.dstPort, 53)
        XCTAssertEqual(udp.payload, payload)
    }
}
