import XCTest
@testable import GhostVMKit

final class FirewallEngineTests: XCTestCase {

    // MARK: - Helpers

    func makeTCPPacket(srcIP: String = "10.100.0.10", dstIP: String = "93.184.216.34",
                       srcPort: UInt16 = 54321, dstPort: UInt16 = 80) -> ParsedPacket {
        let frame = PacketBuilder.tcpFrame(
            dstMAC: MACAddress(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF),
            srcMAC: MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55),
            srcIP: IPv4Address(string: srcIP)!, dstIP: IPv4Address(string: dstIP)!,
            srcPort: srcPort, dstPort: dstPort,
            sequenceNumber: 1, ackNumber: 0, flags: TCPHeader.SYN
        )
        return PacketParser.parse(frame)!
    }

    func makeUDPPacket(srcIP: String = "10.100.0.10", dstIP: String = "8.8.8.8",
                       srcPort: UInt16 = 12345, dstPort: UInt16 = 53) -> ParsedPacket {
        let frame = PacketBuilder.udpFrame(
            dstMAC: MACAddress(0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF),
            srcMAC: MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55),
            srcIP: IPv4Address(string: srcIP)!, dstIP: IPv4Address(string: dstIP)!,
            srcPort: srcPort, dstPort: dstPort,
            payload: Data([0xDE, 0xAD])
        )
        return PacketParser.parse(frame)!
    }

    // MARK: - Default Policy

    func testDefaultAllowPolicyAllowsEverything() {
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: []))
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(), direction: .outbound), .allow)
    }

    func testDefaultBlockPolicyBlocksEverything() {
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .block, rules: []))
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(), direction: .outbound), .block)
    }

    // MARK: - Rule Matching

    func testBlockByDstPort() {
        let rule = NetworkRule(action: .block, layer: .l3, direction: .outbound,
                               ipProtocol: .tcp, dstPort: 443)
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]))

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstPort: 443), direction: .outbound), .block)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstPort: 80), direction: .outbound), .allow)
    }

    func testAllowByDstCIDR() {
        let rule = NetworkRule(action: .allow, layer: .l3, direction: .outbound,
                               dstCIDR: "93.184.216.0/24")
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .block, rules: [rule]))

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstIP: "93.184.216.34"), direction: .outbound), .allow)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstIP: "10.0.0.1"), direction: .outbound), .block)
    }

    func testBlockBySrcCIDR() {
        let rule = NetworkRule(action: .block, layer: .l3, direction: .outbound,
                               srcCIDR: "10.100.0.0/24")
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]))

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(srcIP: "10.100.0.10"), direction: .outbound), .block)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(srcIP: "192.168.1.1"), direction: .outbound), .allow)
    }

    // MARK: - Direction Matching

    func testOutboundRuleDoesNotMatchInbound() {
        let rule = NetworkRule(action: .block, layer: .l3, direction: .outbound, dstPort: 80)
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]))

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstPort: 80), direction: .inbound), .allow)
    }

    func testBothDirectionMatchesBoth() {
        let rule = NetworkRule(action: .block, layer: .l3, direction: .both, dstPort: 80)
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]))

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstPort: 80), direction: .outbound), .block)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstPort: 80), direction: .inbound), .block)
    }

    // MARK: - Disabled Rules

    func testDisabledRuleIsSkipped() {
        let rule = NetworkRule(enabled: false, action: .block, layer: .l3, direction: .outbound, dstPort: 80)
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]))

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstPort: 80), direction: .outbound), .allow)
    }

    // MARK: - First Match Wins

    func testFirstMatchWins() {
        let allowRule = NetworkRule(action: .allow, layer: .l3, direction: .outbound, dstPort: 80)
        let blockRule = NetworkRule(action: .block, layer: .l3, direction: .outbound, dstPort: 80)
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .block, rules: [allowRule, blockRule]))

        // First rule (allow) should win
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstPort: 80), direction: .outbound), .allow)
    }

    // MARK: - Protocol Matching

    func testProtocolMatching() {
        let rule = NetworkRule(action: .block, layer: .l3, direction: .outbound, ipProtocol: .udp)
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]))

        XCTAssertEqual(engine.evaluate(packet: makeUDPPacket(), direction: .outbound), .block)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(), direction: .outbound), .allow)
    }

    // MARK: - Alias Resolution

    func testAliasResolution() {
        let alias = NetworkAlias(name: "blocked_hosts", type: .hosts, entries: ["93.184.216.34", "10.0.0.1"])
        let rule = NetworkRule(action: .block, layer: .l3, direction: .outbound, dstCIDR: "blocked_hosts")
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]),
                                    aliases: [alias])

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstIP: "93.184.216.34"), direction: .outbound), .block)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstIP: "8.8.8.8"), direction: .outbound), .allow)
    }

    func testNetworkAliasResolution() {
        let alias = NetworkAlias(name: "internal_nets", type: .networks, entries: ["10.0.0.0/8", "172.16.0.0/12"])
        let rule = NetworkRule(action: .block, layer: .l3, direction: .outbound, dstCIDR: "internal_nets")
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]),
                                    aliases: [alias])

        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstIP: "10.0.0.1"), direction: .outbound), .block)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstIP: "172.16.0.1"), direction: .outbound), .block)
        XCTAssertEqual(engine.evaluate(packet: makeTCPPacket(dstIP: "8.8.8.8"), direction: .outbound), .allow)
    }

    // MARK: - L2 Rules

    func testL2BroadcastBlock() {
        let rule = NetworkRule(action: .block, layer: .l2, direction: .both, blockBroadcast: true)
        let engine = FirewallEngine(config: FirewallConfig(defaultPolicy: .allow, rules: [rule]))

        // Build a broadcast frame
        let frame = PacketBuilder.udpFrame(
            dstMAC: MACAddress.broadcast, srcMAC: MACAddress(0x00, 0x11, 0x22, 0x33, 0x44, 0x55),
            srcIP: IPv4Address(10, 100, 0, 10), dstIP: IPv4Address(255, 255, 255, 255),
            srcPort: 68, dstPort: 67,
            payload: Data([0x01])
        )
        let packet = PacketParser.parse(frame)!
        XCTAssertEqual(engine.evaluate(packet: packet, direction: .outbound), .block)
    }
}
