import Foundation
import Network

/// Processes packets from a VM's custom network interface, providing
/// ARP, DHCP, DNS, NAT, firewall, and port forwarding services.
public final class CustomNetworkProcessor {
    private let hostFD: Int32
    private let config: RouterConfig
    private let gatewayIP: IPv4Address
    private let gatewayMAC: MACAddress
    private let lanCIDR: CIDRRange
    private let queue: DispatchQueue

    private let arpResponder: ARPResponder
    private let dhcpServer: DHCPServer?
    private let natEngine: NATEngine
    private let dnsForwarder: DNSForwarder
    private let firewallEngine: FirewallEngine?
    private let portForwarder: PortForwarder?

    private var readSource: DispatchSourceRead?
    private var stopped = false

    /// The file handle for the host side of the socketpair. Kept alive to prevent fd close.
    private let hostHandle: FileHandle

    public init(hostHandle: FileHandle, config: RouterConfig, vmMAC: MACAddress) {
        self.hostHandle = hostHandle
        self.hostFD = hostHandle.fileDescriptor
        self.config = config

        // Parse LAN configuration
        self.gatewayIP = IPv4Address(string: config.lan.gateway) ?? IPv4Address(10, 100, 0, 1)
        self.lanCIDR = CIDRRange(string: config.lan.subnet) ?? CIDRRange(string: "10.100.0.0/24")!
        // Generate a deterministic gateway MAC from the network ID
        let idBytes = withUnsafeBytes(of: config.id.uuid) { Array($0) }
        self.gatewayMAC = MACAddress(0x02, idBytes[0], idBytes[1], idBytes[2], idBytes[3], idBytes[4])

        let queueLabel = "org.ghostvm.customnet.\(config.id.uuidString.prefix(8))"
        self.queue = DispatchQueue(label: queueLabel, qos: .userInteractive)

        // Initialize sub-components
        self.arpResponder = ARPResponder(gatewayIP: gatewayIP, gatewayMAC: gatewayMAC)

        if config.dhcp.enabled {
            let dnsServers: [IPv4Address]
            switch config.dns.mode {
            case .custom:
                dnsServers = config.dns.servers.compactMap { IPv4Address(string: $0) }
            case .blocked:
                dnsServers = []
            case .passthrough:
                dnsServers = [IPv4Address(8, 8, 8, 8), IPv4Address(8, 8, 4, 4)]
            }
            self.dhcpServer = DHCPServer(
                serverIP: gatewayIP, serverMAC: gatewayMAC,
                lanConfig: config.lan, dhcpConfig: config.dhcp,
                dnsServers: dnsServers
            )
        } else {
            self.dhcpServer = nil
        }

        self.natEngine = NATEngine()
        self.dnsForwarder = DNSForwarder(dnsConfig: config.dns, queue: queue)

        if !config.firewall.rules.isEmpty || config.firewall.defaultPolicy == .block {
            self.firewallEngine = FirewallEngine(config: config.firewall, aliases: config.aliases)
        } else {
            self.firewallEngine = nil
        }

        let enabledForwards = config.portForwarding.filter { $0.enabled }
        if !enabledForwards.isEmpty {
            self.portForwarder = PortForwarder(rules: enabledForwards, queue: queue)
        } else {
            self.portForwarder = nil
        }
    }

    /// Start processing packets.
    public func start() {
        natEngine.startCleanup(queue: queue)
        portForwarder?.start { [weak self] data in
            self?.writeToVM(data)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: hostFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.readPackets()
        }
        source.setCancelHandler { [weak self] in
            self?.stopped = true
        }
        source.resume()
        self.readSource = source

        print("[CustomNetworkProcessor] Started for network '\(config.name)' (gateway \(gatewayIP))")
    }

    /// Stop processing and clean up.
    public func stop() {
        stopped = true
        readSource?.cancel()
        readSource = nil
        natEngine.stop()
        dnsForwarder.stop()
        portForwarder?.stop()
        print("[CustomNetworkProcessor] Stopped for network '\(config.name)'")
    }

    // MARK: - Packet I/O

    private func readPackets() {
        // VZFileHandleNetworkDeviceAttachment sends SOCK_DGRAM messages on the socketpair.
        // Each recvfrom() returns exactly one Ethernet frame.
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = recv(hostFD, &buf, buf.count, 0)
        guard n > 0 else { return }

        let data = Data(buf[0..<n])
        processOutbound(data)
    }

    private func writeToVM(_ data: Data) {
        data.withUnsafeBytes { buf in
            _ = send(hostFD, buf.baseAddress!, buf.count, 0)
        }
    }

    // MARK: - Outbound Processing (VM → Internet)

    private func processOutbound(_ data: Data) {
        guard let packet = PacketParser.parse(data) else { return }

        switch packet {
        case .arp(let frame, let arp):
            if let reply = arpResponder.handleARP(frame: frame, arp: arp) {
                writeToVM(reply)
            }

        case .udp(let frame, let ip, let udp):
            // Firewall check
            if let fw = firewallEngine, fw.evaluate(packet: packet, direction: .outbound) == .block {
                return
            }

            if udp.dstPort == 67 {
                // DHCP
                if let response = dhcpServer?.handleDHCP(frame: frame, ip: ip, udp: udp) {
                    // Learn the assigned IP in ARP table
                    if let assigned = extractAssignedIP(response) {
                        arpResponder.learn(ip: assigned, mac: frame.srcMAC)
                    }
                    writeToVM(response)
                }
            } else if udp.dstPort == 53 {
                // DNS
                handleDNS(frame: frame, ip: ip, udp: udp)
            } else {
                // Regular UDP — NAT
                handleOutboundUDP(frame: frame, ip: ip, udp: udp)
            }

        case .tcp(let frame, let ip, let tcp):
            if let fw = firewallEngine, fw.evaluate(packet: packet, direction: .outbound) == .block {
                return
            }
            handleOutboundTCP(frame: frame, ip: ip, udp: tcp)

        case .icmp(let frame, let ip, let icmp):
            handleICMP(frame: frame, ip: ip, icmp: icmp)

        case .unknownIPv4, .unknownEther:
            break
        }
    }

    // MARK: - DNS Handling

    private func handleDNS(frame: EthernetFrame, ip: IPv4Header, udp: UDPHeader) {
        let srcMAC = frame.srcMAC
        let srcIP = ip.srcIP
        let srcPort = udp.srcPort

        dnsForwarder.handleQuery(udp.payload) { [weak self] responseData in
            guard let self = self, let responseData = responseData else { return }

            let response = PacketBuilder.udpFrame(
                dstMAC: srcMAC, srcMAC: self.gatewayMAC,
                srcIP: self.gatewayIP, dstIP: srcIP,
                srcPort: 53, dstPort: srcPort,
                payload: responseData
            )
            self.writeToVM(response)
        }
    }

    // MARK: - Outbound UDP (NAT)

    private func handleOutboundUDP(frame: EthernetFrame, ip: IPv4Header, udp: UDPHeader) {
        guard let entry = natEngine.outboundMapping(
            proto: IPProto.udp, srcIP: ip.srcIP, srcPort: udp.srcPort,
            dstIP: ip.dstIP, dstPort: udp.dstPort
        ) else { return }

        if entry.connection == nil {
            // Create new NWConnection
            let host = NWEndpoint.Host(ip.dstIP.description)
            let port = NWEndpoint.Port(rawValue: udp.dstPort)!
            let connection = NWConnection(host: host, port: port, using: .udp)

            natEngine.setConnection(proto: IPProto.udp, srcIP: ip.srcIP, srcPort: udp.srcPort,
                                    dstIP: ip.dstIP, dstPort: udp.dstPort, connection: connection)

            let srcMAC = frame.srcMAC
            let srcIP = ip.srcIP
            let srcPort = udp.srcPort
            let dstIP = ip.dstIP
            let dstPort = udp.dstPort

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    connection.send(content: udp.payload, completion: .contentProcessed { _ in })
                    self?.receiveUDPResponses(connection: connection, srcMAC: srcMAC,
                                             originalSrcIP: srcIP, originalSrcPort: srcPort,
                                             dstIP: dstIP, dstPort: dstPort)
                case .failed, .cancelled:
                    self?.natEngine.removeEntry(proto: IPProto.udp, srcIP: srcIP, srcPort: srcPort,
                                               dstIP: dstIP, dstPort: dstPort)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        } else {
            // Reuse existing connection
            entry.connection?.send(content: udp.payload, completion: .contentProcessed { _ in })
        }
    }

    private func receiveUDPResponses(connection: NWConnection, srcMAC: MACAddress,
                                     originalSrcIP: IPv4Address, originalSrcPort: UInt16,
                                     dstIP: IPv4Address, dstPort: UInt16) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self = self, let data = data else { return }

            // Build response frame back to VM
            let response = PacketBuilder.udpFrame(
                dstMAC: srcMAC, srcMAC: self.gatewayMAC,
                srcIP: dstIP, dstIP: originalSrcIP,
                srcPort: dstPort, dstPort: originalSrcPort,
                payload: data
            )

            // Firewall check on inbound
            if let fw = self.firewallEngine,
               let parsed = PacketParser.parse(response),
               fw.evaluate(packet: parsed, direction: .inbound) == .block {
                return
            }

            self.writeToVM(response)

            // Continue receiving
            self.receiveUDPResponses(connection: connection, srcMAC: srcMAC,
                                     originalSrcIP: originalSrcIP, originalSrcPort: originalSrcPort,
                                     dstIP: dstIP, dstPort: dstPort)
        }
    }

    // MARK: - Outbound TCP (NAT)

    private func handleOutboundTCP(frame: EthernetFrame, ip: IPv4Header, udp tcp: TCPHeader) {
        guard let entry = natEngine.outboundMapping(
            proto: IPProto.tcp, srcIP: ip.srcIP, srcPort: tcp.srcPort,
            dstIP: ip.dstIP, dstPort: tcp.dstPort
        ) else { return }

        natEngine.updateTCPState(proto: IPProto.tcp, srcIP: ip.srcIP, srcPort: tcp.srcPort,
                                 dstIP: ip.dstIP, dstPort: tcp.dstPort, flags: tcp.flags)

        if entry.connection == nil && tcp.isSYN {
            // New TCP connection
            let host = NWEndpoint.Host(ip.dstIP.description)
            let port = NWEndpoint.Port(rawValue: tcp.dstPort)!
            let params = NWParameters.tcp
            let connection = NWConnection(host: host, port: port, using: params)

            natEngine.setConnection(proto: IPProto.tcp, srcIP: ip.srcIP, srcPort: tcp.srcPort,
                                    dstIP: ip.dstIP, dstPort: tcp.dstPort, connection: connection)

            let srcMAC = frame.srcMAC
            let srcIP = ip.srcIP
            let srcPort = tcp.srcPort
            let dstIP = ip.dstIP
            let dstPort = tcp.dstPort

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    // Send any payload from SYN packet (unlikely but possible)
                    if !tcp.payload.isEmpty {
                        connection.send(content: tcp.payload, completion: .contentProcessed { _ in })
                    }
                    self?.receiveTCPResponses(connection: connection, srcMAC: srcMAC,
                                              originalSrcIP: srcIP, originalSrcPort: srcPort,
                                              dstIP: dstIP, dstPort: dstPort)
                case .failed, .cancelled:
                    self?.natEngine.removeEntry(proto: IPProto.tcp, srcIP: srcIP, srcPort: srcPort,
                                               dstIP: dstIP, dstPort: dstPort)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        } else if let conn = entry.connection, !tcp.payload.isEmpty {
            // Forward data on existing connection
            conn.send(content: tcp.payload, completion: .contentProcessed { _ in })
        }

        // Handle FIN/RST
        if tcp.isFIN || tcp.isRST {
            if let conn = entry.connection {
                conn.cancel()
            }
        }
    }

    private func receiveTCPResponses(connection: NWConnection, srcMAC: MACAddress,
                                     originalSrcIP: IPv4Address, originalSrcPort: UInt16,
                                     dstIP: IPv4Address, dstPort: UInt16) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                // Build TCP response frame
                // Note: NWConnection handles TCP state machine, we just need to deliver data
                let response = PacketBuilder.udpFrame(
                    dstMAC: srcMAC, srcMAC: self.gatewayMAC,
                    srcIP: dstIP, dstIP: originalSrcIP,
                    srcPort: dstPort, dstPort: originalSrcPort,
                    payload: data
                )

                if let fw = self.firewallEngine,
                   let parsed = PacketParser.parse(response),
                   fw.evaluate(packet: parsed, direction: .inbound) == .block {
                    return
                }

                self.writeToVM(response)
            }

            if isComplete || error != nil {
                self.natEngine.removeEntry(proto: IPProto.tcp, srcIP: originalSrcIP, srcPort: originalSrcPort,
                                           dstIP: dstIP, dstPort: dstPort)
                return
            }

            // Continue receiving
            self.receiveTCPResponses(connection: connection, srcMAC: srcMAC,
                                     originalSrcIP: originalSrcIP, originalSrcPort: originalSrcPort,
                                     dstIP: dstIP, dstPort: dstPort)
        }
    }

    // MARK: - ICMP

    private func handleICMP(frame: EthernetFrame, ip: IPv4Header, icmp: ICMPHeader) {
        // Only respond to pings to the gateway
        guard ip.dstIP == gatewayIP, icmp.type == ICMPHeader.echoRequest else { return }

        let reply = PacketBuilder.icmpEchoReplyFrame(
            dstMAC: frame.srcMAC, srcMAC: gatewayMAC,
            srcIP: gatewayIP, dstIP: ip.srcIP,
            requestPayload: icmp.payload
        )
        writeToVM(reply)
    }

    // MARK: - Helpers

    private func extractAssignedIP(_ dhcpResponse: Data) -> IPv4Address? {
        // Parse the DHCP response to find yiaddr
        guard case .udp(_, _, let udp) = PacketParser.parse(dhcpResponse) else { return nil }
        let dhcp = udp.payload
        guard dhcp.count >= 20 else { return nil }
        return dhcp.withUnsafeBytes { buf -> IPv4Address? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let yiaddr = IPv4Address(ptr[16], ptr[17], ptr[18], ptr[19])
            return yiaddr == IPv4Address(0, 0, 0, 0) ? nil : yiaddr
        }
    }
}
