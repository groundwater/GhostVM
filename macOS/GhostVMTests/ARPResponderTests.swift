import XCTest
@testable import GhostVMKit

final class ARPResponderTests: XCTestCase {

    let gatewayIP = IPv4Address(10, 100, 0, 1)
    let gatewayMAC = MACAddress(0x02, 0x00, 0x00, 0x00, 0x00, 0x01)

    func makeResponder() -> ARPResponder {
        ARPResponder(gatewayIP: gatewayIP, gatewayMAC: gatewayMAC)
    }

    func testRespondsToGatewayARPRequest() {
        let responder = makeResponder()
        let clientMAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        let clientIP = IPv4Address(10, 100, 0, 10)

        // Build an ARP request for the gateway
        let arp = ARPPacket(hardwareType: 1, protocolType: 0x0800,
                            hardwareSize: 6, protocolSize: 4,
                            opcode: ARPPacket.request,
                            senderMAC: clientMAC, senderIP: clientIP,
                            targetMAC: MACAddress.zero, targetIP: gatewayIP)
        let frame = EthernetFrame(dstMAC: MACAddress.broadcast, srcMAC: clientMAC,
                                  etherType: EtherType.arp, payload: Data(), payloadOffset: 14)

        let reply = responder.handleARP(frame: frame, arp: arp)
        XCTAssertNotNil(reply)

        // Parse the reply
        guard let parsed = PacketParser.parse(reply!) else {
            XCTFail("Failed to parse ARP reply")
            return
        }
        if case .arp(let eth, let replyARP) = parsed {
            XCTAssertEqual(eth.dstMAC, clientMAC)
            XCTAssertEqual(eth.srcMAC, gatewayMAC)
            XCTAssertEqual(replyARP.opcode, ARPPacket.reply)
            XCTAssertEqual(replyARP.senderMAC, gatewayMAC)
            XCTAssertEqual(replyARP.senderIP, gatewayIP)
            XCTAssertEqual(replyARP.targetMAC, clientMAC)
            XCTAssertEqual(replyARP.targetIP, clientIP)
        } else {
            XCTFail("Expected ARP reply")
        }
    }

    func testIgnoresARPRequestForOtherIP() {
        let responder = makeResponder()
        let clientMAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        let otherIP = IPv4Address(10, 100, 0, 99)

        let arp = ARPPacket(hardwareType: 1, protocolType: 0x0800,
                            hardwareSize: 6, protocolSize: 4,
                            opcode: ARPPacket.request,
                            senderMAC: clientMAC, senderIP: IPv4Address(10, 100, 0, 10),
                            targetMAC: MACAddress.zero, targetIP: otherIP)
        let frame = EthernetFrame(dstMAC: MACAddress.broadcast, srcMAC: clientMAC,
                                  etherType: EtherType.arp, payload: Data(), payloadOffset: 14)

        let reply = responder.handleARP(frame: frame, arp: arp)
        XCTAssertNil(reply)
    }

    func testIgnoresARPReply() {
        let responder = makeResponder()
        let arp = ARPPacket(hardwareType: 1, protocolType: 0x0800,
                            hardwareSize: 6, protocolSize: 4,
                            opcode: ARPPacket.reply,
                            senderMAC: MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55),
                            senderIP: IPv4Address(10, 100, 0, 10),
                            targetMAC: gatewayMAC, targetIP: gatewayIP)
        let frame = EthernetFrame(dstMAC: gatewayMAC, srcMAC: arp.senderMAC,
                                  etherType: EtherType.arp, payload: Data(), payloadOffset: 14)

        let reply = responder.handleARP(frame: frame, arp: arp)
        XCTAssertNil(reply)
    }

    func testLearnsFromARP() {
        let responder = makeResponder()
        let clientMAC = MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55)
        let clientIP = IPv4Address(10, 100, 0, 10)

        let arp = ARPPacket(hardwareType: 1, protocolType: 0x0800,
                            hardwareSize: 6, protocolSize: 4,
                            opcode: ARPPacket.request,
                            senderMAC: clientMAC, senderIP: clientIP,
                            targetMAC: MACAddress.zero, targetIP: gatewayIP)
        let frame = EthernetFrame(dstMAC: MACAddress.broadcast, srcMAC: clientMAC,
                                  etherType: EtherType.arp, payload: Data(), payloadOffset: 14)

        _ = responder.handleARP(frame: frame, arp: arp)

        XCTAssertEqual(responder.lookup(clientIP), clientMAC)
    }

    func testLookupUnknownIP() {
        let responder = makeResponder()
        XCTAssertNil(responder.lookup(IPv4Address(10, 100, 0, 99)))
    }

    func testRegisterStatic() {
        let responder = makeResponder()
        let ip = IPv4Address(10, 100, 0, 50)
        let mac = MACAddress(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF)
        responder.register(ip: ip, mac: mac)
        XCTAssertEqual(responder.lookup(ip), mac)
    }
}
