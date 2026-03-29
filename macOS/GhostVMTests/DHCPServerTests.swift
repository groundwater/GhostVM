import XCTest
@testable import GhostVMKit

final class DHCPServerTests: XCTestCase {

    let serverIP = IPv4Address(10, 100, 0, 1)
    let serverMAC = MACAddress(0x02, 0x00, 0x00, 0x00, 0x00, 0x01)
    let clientMAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)

    func makeServer(staticLeases: [(mac: MACAddress, ip: IPv4Address, hostname: String?)] = []) -> DHCPServer {
        DHCPServer(
            serverIP: serverIP,
            serverMAC: serverMAC,
            subnetMask: IPv4Address(255, 255, 255, 0),
            rangeStart: IPv4Address(10, 100, 0, 10),
            rangeEnd: IPv4Address(10, 100, 0, 20),
            dnsServers: [IPv4Address(8, 8, 8, 8)],
            leaseTime: 3600,
            staticLeases: staticLeases
        )
    }

    /// Build a DHCP discover/request frame that the server can process.
    func buildDHCPFrame(messageType: UInt8, xid: UInt32 = 0x12345678, clientMAC: MACAddress,
                        requestedIP: IPv4Address? = nil) -> Data {
        var dhcp = Data(capacity: 300)

        // BOOTP header
        dhcp.append(1) // op: request
        dhcp.append(1) // htype
        dhcp.append(6) // hlen
        dhcp.append(0) // hops
        dhcp.append(UInt8(xid >> 24))
        dhcp.append(UInt8((xid >> 16) & 0xFF))
        dhcp.append(UInt8((xid >> 8) & 0xFF))
        dhcp.append(UInt8(xid & 0xFF))
        dhcp.append(Data(count: 4)) // secs + flags
        dhcp.append(Data(count: 4)) // ciaddr
        dhcp.append(Data(count: 4)) // yiaddr
        dhcp.append(Data(count: 4)) // siaddr
        dhcp.append(Data(count: 4)) // giaddr
        dhcp.append(clientMAC.data) // chaddr
        dhcp.append(Data(count: 10)) // chaddr padding
        dhcp.append(Data(count: 192)) // sname + file

        // Magic cookie
        dhcp.append(contentsOf: [0x63, 0x82, 0x53, 0x63])

        // Options
        dhcp.append(contentsOf: [53, 1, messageType]) // message type

        if let ip = requestedIP {
            dhcp.append(contentsOf: [50, 4])
            dhcp.append(ip.data)
        }

        dhcp.append(255) // end

        // Pad to 300 bytes
        if dhcp.count < 300 {
            dhcp.append(Data(count: 300 - dhcp.count))
        }

        // Wrap in UDP/IP/Ethernet
        return PacketBuilder.udpFrame(
            dstMAC: MACAddress.broadcast, srcMAC: clientMAC,
            srcIP: IPv4Address(0, 0, 0, 0), dstIP: IPv4Address(255, 255, 255, 255),
            srcPort: 68, dstPort: 67,
            payload: dhcp
        )
    }

    func extractDHCPResponse(_ frameData: Data) -> (yiaddr: IPv4Address, messageType: UInt8)? {
        guard case .udp(_, _, let udp) = PacketParser.parse(frameData) else { return nil }
        let dhcp = udp.payload
        guard dhcp.count >= 240 else { return nil }

        return dhcp.withUnsafeBytes { buf -> (IPv4Address, UInt8)? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let yiaddr = IPv4Address(ptr[16], ptr[17], ptr[18], ptr[19])

            // Find message type option
            var i = 240
            while i < dhcp.count {
                if ptr[i] == 255 { break }
                if ptr[i] == 0 { i += 1; continue }
                let optType = ptr[i]
                guard i + 1 < dhcp.count else { break }
                let optLen = Int(ptr[i + 1])
                if optType == 53 && optLen == 1 && i + 2 < dhcp.count {
                    return (yiaddr, ptr[i + 2])
                }
                i += 2 + optLen
            }
            return nil
        }
    }

    // MARK: - Tests

    func testFullDORACycle() {
        let server = makeServer()

        // 1. DISCOVER
        let discoverFrame = buildDHCPFrame(messageType: 1, clientMAC: clientMAC)
        guard case .udp(let eth, let ip, let udp) = PacketParser.parse(discoverFrame) else {
            XCTFail("Failed to parse discover frame")
            return
        }

        let offerData = server.handleDHCP(frame: eth, ip: ip, udp: udp)
        XCTAssertNotNil(offerData)

        guard let offer = extractDHCPResponse(offerData!) else {
            XCTFail("Failed to parse offer")
            return
        }
        XCTAssertEqual(offer.messageType, 2) // OFFER
        XCTAssertEqual(offer.yiaddr, IPv4Address(10, 100, 0, 10)) // first in range

        // 2. REQUEST
        let requestFrame = buildDHCPFrame(messageType: 3, clientMAC: clientMAC,
                                          requestedIP: offer.yiaddr)
        guard case .udp(let reqEth, let reqIP, let reqUDP) = PacketParser.parse(requestFrame) else {
            XCTFail("Failed to parse request frame")
            return
        }

        let ackData = server.handleDHCP(frame: reqEth, ip: reqIP, udp: reqUDP)
        XCTAssertNotNil(ackData)

        guard let ack = extractDHCPResponse(ackData!) else {
            XCTFail("Failed to parse ack")
            return
        }
        XCTAssertEqual(ack.messageType, 5) // ACK
        XCTAssertEqual(ack.yiaddr, IPv4Address(10, 100, 0, 10))

        // Verify lease
        XCTAssertEqual(server.leases.count, 1)
        XCTAssertEqual(server.leases.first?.ip, IPv4Address(10, 100, 0, 10))
        XCTAssertEqual(server.leases.first?.mac, clientMAC)
    }

    func testStaticLease() {
        let staticIP = IPv4Address(10, 100, 0, 5)
        let server = makeServer(staticLeases: [(mac: clientMAC, ip: staticIP, hostname: "static-host")])

        let discoverFrame = buildDHCPFrame(messageType: 1, clientMAC: clientMAC)
        guard case .udp(let eth, let ip, let udp) = PacketParser.parse(discoverFrame) else {
            XCTFail("Failed to parse"); return
        }

        let offerData = server.handleDHCP(frame: eth, ip: ip, udp: udp)
        XCTAssertNotNil(offerData)

        guard let offer = extractDHCPResponse(offerData!) else {
            XCTFail("Failed to parse offer"); return
        }
        // Static lease should be offered even though it's outside the pool range
        XCTAssertEqual(offer.yiaddr, staticIP)
    }

    func testPoolExhaustion() {
        // Pool of 11 addresses (10-20), allocate all
        let server = makeServer()

        for i: UInt8 in 0...10 {
            let mac = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, i)
            let discoverFrame = buildDHCPFrame(messageType: 1, clientMAC: mac)
            guard case .udp(let eth, let ip, let udp) = PacketParser.parse(discoverFrame) else {
                XCTFail("Failed to parse"); return
            }
            let offerData = server.handleDHCP(frame: eth, ip: ip, udp: udp)
            XCTAssertNotNil(offerData, "Should offer IP for client \(i)")

            // Request it
            guard let offer = extractDHCPResponse(offerData!) else { continue }
            let requestFrame = buildDHCPFrame(messageType: 3, clientMAC: mac, requestedIP: offer.yiaddr)
            guard case .udp(let reqEth, let reqIP, let reqUDP) = PacketParser.parse(requestFrame) else { continue }
            _ = server.handleDHCP(frame: reqEth, ip: reqIP, udp: reqUDP)
        }

        // 12th client should fail
        let extraMAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0xFF)
        let discoverFrame = buildDHCPFrame(messageType: 1, clientMAC: extraMAC)
        guard case .udp(let eth, let ip, let udp) = PacketParser.parse(discoverFrame) else {
            XCTFail("Failed to parse"); return
        }
        let offerData = server.handleDHCP(frame: eth, ip: ip, udp: udp)
        XCTAssertNil(offerData, "Pool should be exhausted")
    }

    func testSecondClientGetsDifferentIP() {
        let server = makeServer()
        let client2MAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x66)

        // Client 1 DORA
        let d1 = buildDHCPFrame(messageType: 1, clientMAC: clientMAC)
        guard case .udp(let e1, let i1, let u1) = PacketParser.parse(d1) else { return }
        guard let o1 = server.handleDHCP(frame: e1, ip: i1, udp: u1),
              let offer1 = extractDHCPResponse(o1) else { return }

        let r1 = buildDHCPFrame(messageType: 3, clientMAC: clientMAC, requestedIP: offer1.yiaddr)
        guard case .udp(let re1, let ri1, let ru1) = PacketParser.parse(r1) else { return }
        _ = server.handleDHCP(frame: re1, ip: ri1, udp: ru1)

        // Client 2 DORA
        let d2 = buildDHCPFrame(messageType: 1, clientMAC: client2MAC)
        guard case .udp(let e2, let i2, let u2) = PacketParser.parse(d2) else { return }
        guard let o2 = server.handleDHCP(frame: e2, ip: i2, udp: u2),
              let offer2 = extractDHCPResponse(o2) else { return }

        XCTAssertNotEqual(offer1.yiaddr, offer2.yiaddr)
        XCTAssertEqual(offer2.yiaddr, IPv4Address(10, 100, 0, 11))
    }
}
