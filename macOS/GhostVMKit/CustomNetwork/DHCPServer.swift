import Foundation

// MARK: - DHCP Constants

private enum DHCPConst {
    static let serverPort: UInt16 = 67
    static let clientPort: UInt16 = 68
    static let magicCookie: [UInt8] = [0x63, 0x82, 0x53, 0x63]

    // Message types
    static let discover: UInt8 = 1
    static let offer: UInt8 = 2
    static let request: UInt8 = 3
    static let decline: UInt8 = 4
    static let ack: UInt8 = 5
    static let nak: UInt8 = 6
    static let release: UInt8 = 7

    // Options
    static let optSubnetMask: UInt8 = 1
    static let optRouter: UInt8 = 3
    static let optDNS: UInt8 = 6
    static let optHostname: UInt8 = 12
    static let optRequestedIP: UInt8 = 50
    static let optLeaseTime: UInt8 = 51
    static let optMessageType: UInt8 = 53
    static let optServerID: UInt8 = 54
    static let optEnd: UInt8 = 255
    static let optPad: UInt8 = 0

    // Boot reply
    static let bootReply: UInt8 = 2
}

// MARK: - DHCP Lease

public struct DHCPLease: Equatable {
    public let ip: IPv4Address
    public let mac: MACAddress
    public let expiry: Date
    public let hostname: String?

    public var isExpired: Bool { Date() > expiry }
}

// MARK: - DHCPServer

public final class DHCPServer {
    private let serverIP: IPv4Address
    private let serverMAC: MACAddress
    private let subnetMask: IPv4Address
    private let rangeStart: IPv4Address
    private let rangeEnd: IPv4Address
    private let dnsServers: [IPv4Address]
    private let leaseTime: TimeInterval
    private let staticLeases: [(mac: MACAddress, ip: IPv4Address, hostname: String?)]

    private var activeLeases: [MACAddress: DHCPLease] = [:]
    private var pendingOffers: [MACAddress: IPv4Address] = [:]
    private let lock = NSLock()

    public init(
        serverIP: IPv4Address,
        serverMAC: MACAddress,
        subnetMask: IPv4Address,
        rangeStart: IPv4Address,
        rangeEnd: IPv4Address,
        dnsServers: [IPv4Address] = [],
        leaseTime: TimeInterval = 3600,
        staticLeases: [(mac: MACAddress, ip: IPv4Address, hostname: String?)] = []
    ) {
        self.serverIP = serverIP
        self.serverMAC = serverMAC
        self.subnetMask = subnetMask
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.dnsServers = dnsServers
        self.leaseTime = leaseTime
        self.staticLeases = staticLeases
    }

    /// Convenience initializer from config types.
    public convenience init(
        serverIP: IPv4Address,
        serverMAC: MACAddress,
        lanConfig: LANConfig,
        dhcpConfig: DHCPConfig,
        dnsServers: [IPv4Address] = []
    ) {
        let cidr = CIDRRange(string: lanConfig.subnet)
        let mask = cidr?.subnetMask ?? IPv4Address(255, 255, 255, 0)
        let start = IPv4Address(string: dhcpConfig.rangeStart) ?? IPv4Address(10, 100, 0, 10)
        let end = IPv4Address(string: dhcpConfig.rangeEnd) ?? IPv4Address(10, 100, 0, 254)

        let statics: [(mac: MACAddress, ip: IPv4Address, hostname: String?)] = dhcpConfig.staticLeases.compactMap {
            guard let mac = MACAddress(string: $0.mac),
                  let ip = IPv4Address(string: $0.ip) else { return nil }
            return (mac: mac, ip: ip, hostname: $0.hostname.isEmpty ? nil : $0.hostname)
        }

        self.init(serverIP: serverIP, serverMAC: serverMAC, subnetMask: mask,
                  rangeStart: start, rangeEnd: end, dnsServers: dnsServers,
                  leaseTime: 3600, staticLeases: statics)
    }

    /// Handle a DHCP UDP packet (payload of UDP destined for port 67).
    /// Returns a response Ethernet frame, or nil if not applicable.
    public func handleDHCP(frame: EthernetFrame, ip: IPv4Header, udp: UDPHeader) -> Data? {
        let dhcpData = udp.payload
        guard let message = parseDHCPMessage(dhcpData) else { return nil }
        guard let messageType = message.options[DHCPConst.optMessageType]?.first else { return nil }

        let clientMAC = message.chaddr

        switch messageType {
        case DHCPConst.discover:
            return handleDiscover(message: message, clientMAC: clientMAC, srcFrame: frame)
        case DHCPConst.request:
            return handleRequest(message: message, clientMAC: clientMAC, srcFrame: frame)
        case DHCPConst.release:
            handleRelease(clientMAC: clientMAC)
            return nil
        default:
            return nil
        }
    }

    /// Get all active (non-expired) leases.
    public var leases: [DHCPLease] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeLeases.values.filter { !$0.isExpired })
    }

    /// Clean up expired leases.
    public func purgeExpired() {
        lock.lock()
        activeLeases = activeLeases.filter { !$0.value.isExpired }
        pendingOffers = pendingOffers.filter { mac, _ in
            // Remove pending offers for MACs that got a lease
            activeLeases[mac] != nil ? false : true
        }
        lock.unlock()
    }

    // MARK: - Private

    private func handleDiscover(message: DHCPMessage, clientMAC: MACAddress, srcFrame: EthernetFrame) -> Data? {
        let offeredIP = allocateIP(for: clientMAC)
        guard let ip = offeredIP else { return nil } // pool exhausted

        lock.lock()
        pendingOffers[clientMAC] = ip
        lock.unlock()

        return buildResponse(type: DHCPConst.offer, xid: message.xid, clientMAC: clientMAC,
                             assignedIP: ip, srcFrame: srcFrame)
    }

    private func handleRequest(message: DHCPMessage, clientMAC: MACAddress, srcFrame: EthernetFrame) -> Data? {
        // Determine requested IP from options or ciaddr
        let requestedIP: IPv4Address?
        if let reqData = message.options[DHCPConst.optRequestedIP], reqData.count == 4 {
            requestedIP = IPv4Address(data: reqData)
        } else if message.ciaddr != IPv4Address(0, 0, 0, 0) {
            requestedIP = message.ciaddr
        } else {
            lock.lock()
            let pending = pendingOffers[clientMAC]
            lock.unlock()
            requestedIP = pending
        }

        guard let ip = requestedIP else {
            return buildResponse(type: DHCPConst.nak, xid: message.xid, clientMAC: clientMAC,
                                 assignedIP: IPv4Address(0, 0, 0, 0), srcFrame: srcFrame)
        }

        // Verify IP is valid for this client
        let validIP = isIPValidForClient(ip, mac: clientMAC)
        guard validIP else {
            return buildResponse(type: DHCPConst.nak, xid: message.xid, clientMAC: clientMAC,
                                 assignedIP: IPv4Address(0, 0, 0, 0), srcFrame: srcFrame)
        }

        let hostname = message.options[DHCPConst.optHostname].flatMap { String(data: $0, encoding: .utf8) }

        lock.lock()
        activeLeases[clientMAC] = DHCPLease(ip: ip, mac: clientMAC,
                                            expiry: Date().addingTimeInterval(leaseTime),
                                            hostname: hostname)
        pendingOffers.removeValue(forKey: clientMAC)
        lock.unlock()

        return buildResponse(type: DHCPConst.ack, xid: message.xid, clientMAC: clientMAC,
                             assignedIP: ip, srcFrame: srcFrame)
    }

    private func handleRelease(clientMAC: MACAddress) {
        lock.lock()
        activeLeases.removeValue(forKey: clientMAC)
        lock.unlock()
    }

    private func allocateIP(for mac: MACAddress) -> IPv4Address? {
        lock.lock()
        defer { lock.unlock() }

        // Check static leases first
        if let staticEntry = staticLeases.first(where: { $0.mac == mac }) {
            return staticEntry.ip
        }

        // Check existing active lease
        if let existing = activeLeases[mac], !existing.isExpired {
            return existing.ip
        }

        // Check pending offer
        if let pending = pendingOffers[mac] {
            return pending
        }

        // Allocate from pool
        let usedIPs = Set(activeLeases.values.map { $0.ip }).union(Set(pendingOffers.values))
        let staticIPs = Set(staticLeases.map { $0.ip })

        var candidate = rangeStart
        while candidate <= rangeEnd {
            if !usedIPs.contains(candidate) && !staticIPs.contains(candidate) {
                return candidate
            }
            candidate = candidate.advanced(by: 1)
        }

        return nil // pool exhausted
    }

    private func isIPValidForClient(_ ip: IPv4Address, mac: MACAddress) -> Bool {
        // Static lease: must match
        if let staticEntry = staticLeases.first(where: { $0.mac == mac }) {
            return staticEntry.ip == ip
        }

        // Must be in range
        guard ip >= rangeStart && ip <= rangeEnd else { return false }

        lock.lock()
        defer { lock.unlock() }

        // Must not be taken by another MAC
        for (otherMAC, lease) in activeLeases {
            if lease.ip == ip && otherMAC != mac && !lease.isExpired {
                return false
            }
        }

        return true
    }

    // MARK: - DHCP Message Building

    private func buildResponse(type: UInt8, xid: UInt32, clientMAC: MACAddress,
                               assignedIP: IPv4Address, srcFrame: EthernetFrame) -> Data {
        var response = Data(capacity: 300)

        // BOOTP header
        response.append(DHCPConst.bootReply) // op
        response.append(1) // htype (Ethernet)
        response.append(6) // hlen
        response.append(0) // hops
        // xid
        response.append(UInt8(xid >> 24))
        response.append(UInt8((xid >> 16) & 0xFF))
        response.append(UInt8((xid >> 8) & 0xFF))
        response.append(UInt8(xid & 0xFF))
        response.append(contentsOf: [0, 0]) // secs
        response.append(contentsOf: [0, 0]) // flags
        response.append(contentsOf: [0, 0, 0, 0]) // ciaddr
        response.append(assignedIP.data) // yiaddr
        response.append(serverIP.data) // siaddr
        response.append(contentsOf: [0, 0, 0, 0]) // giaddr

        // chaddr (16 bytes, MAC + padding)
        response.append(clientMAC.data)
        response.append(Data(count: 10))

        // sname (64 bytes) + file (128 bytes)
        response.append(Data(count: 192))

        // Magic cookie
        response.append(contentsOf: DHCPConst.magicCookie)

        // Options
        // Message type
        response.append(contentsOf: [DHCPConst.optMessageType, 1, type])

        // Server identifier
        response.append(DHCPConst.optServerID)
        response.append(4)
        response.append(serverIP.data)

        if type == DHCPConst.offer || type == DHCPConst.ack {
            // Lease time
            let lt = UInt32(leaseTime)
            response.append(contentsOf: [DHCPConst.optLeaseTime, 4,
                                         UInt8(lt >> 24), UInt8((lt >> 16) & 0xFF),
                                         UInt8((lt >> 8) & 0xFF), UInt8(lt & 0xFF)])

            // Subnet mask
            response.append(DHCPConst.optSubnetMask)
            response.append(4)
            response.append(subnetMask.data)

            // Router (gateway)
            response.append(DHCPConst.optRouter)
            response.append(4)
            response.append(serverIP.data)

            // DNS servers
            if !dnsServers.isEmpty {
                response.append(DHCPConst.optDNS)
                response.append(UInt8(dnsServers.count * 4))
                for dns in dnsServers {
                    response.append(dns.data)
                }
            }
        }

        // End
        response.append(DHCPConst.optEnd)

        // Pad to minimum 300 bytes
        if response.count < 300 {
            response.append(Data(count: 300 - response.count))
        }

        // Wrap in UDP/IP/Ethernet
        let dstMAC = clientMAC
        let dstIP = assignedIP == IPv4Address(0, 0, 0, 0)
            ? IPv4Address(255, 255, 255, 255)
            : assignedIP

        return PacketBuilder.udpFrame(
            dstMAC: dstMAC, srcMAC: serverMAC,
            srcIP: serverIP, dstIP: dstIP,
            srcPort: DHCPConst.serverPort, dstPort: DHCPConst.clientPort,
            payload: response
        )
    }

    // MARK: - DHCP Message Parsing

    private struct DHCPMessage {
        let op: UInt8
        let xid: UInt32
        let ciaddr: IPv4Address
        let chaddr: MACAddress
        let options: [UInt8: Data]
    }

    private func parseDHCPMessage(_ data: Data) -> DHCPMessage? {
        guard data.count >= 240 else { return nil }
        return data.withUnsafeBytes { buf -> DHCPMessage? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)

            let op = ptr[0]
            let xid = UInt32(ptr[4]) << 24 | UInt32(ptr[5]) << 16 | UInt32(ptr[6]) << 8 | UInt32(ptr[7])
            let ciaddr = IPv4Address(ptr[12], ptr[13], ptr[14], ptr[15])
            let chaddr = MACAddress(ptr[28], ptr[29], ptr[30], ptr[31], ptr[32], ptr[33])

            // Verify magic cookie at offset 236
            guard ptr[236] == 0x63 && ptr[237] == 0x82 && ptr[238] == 0x53 && ptr[239] == 0x63 else {
                return nil
            }

            // Parse options starting at 240
            var options: [UInt8: Data] = [:]
            var i = 240
            while i < data.count {
                let optType = ptr[i]
                if optType == DHCPConst.optEnd { break }
                if optType == DHCPConst.optPad { i += 1; continue }
                guard i + 1 < data.count else { break }
                let optLen = Int(ptr[i + 1])
                guard i + 2 + optLen <= data.count else { break }
                options[optType] = Data(bytes: ptr + i + 2, count: optLen)
                i += 2 + optLen
            }

            return DHCPMessage(op: op, xid: xid, ciaddr: ciaddr, chaddr: chaddr, options: options)
        }
    }
}
