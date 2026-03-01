import Foundation

/// Responds to ARP requests for the gateway IP and maintains an ARP table.
public final class ARPResponder {
    private let gatewayIP: IPv4Address
    private let gatewayMAC: MACAddress
    private var arpTable: [IPv4Address: MACAddress] = [:]
    private let lock = NSLock()

    public init(gatewayIP: IPv4Address, gatewayMAC: MACAddress) {
        self.gatewayIP = gatewayIP
        self.gatewayMAC = gatewayMAC
    }

    /// Process an ARP packet and optionally return a reply frame.
    public func handleARP(frame: EthernetFrame, arp: ARPPacket) -> Data? {
        // Learn sender's MAC-IP binding
        learn(ip: arp.senderIP, mac: arp.senderMAC)

        guard arp.opcode == ARPPacket.request else { return nil }

        // Only respond if the target IP is our gateway
        guard arp.targetIP == gatewayIP else { return nil }

        return PacketBuilder.arpReplyFrame(
            senderMAC: gatewayMAC, senderIP: gatewayIP,
            targetMAC: arp.senderMAC, targetIP: arp.senderIP
        )
    }

    /// Learn a MAC-IP binding from observed traffic.
    public func learn(ip: IPv4Address, mac: MACAddress) {
        guard mac != MACAddress.zero && mac != MACAddress.broadcast else { return }
        lock.lock()
        arpTable[ip] = mac
        lock.unlock()
    }

    /// Look up a MAC address for a given IP.
    public func lookup(_ ip: IPv4Address) -> MACAddress? {
        lock.lock()
        defer { lock.unlock() }
        return arpTable[ip]
    }

    /// Register a static ARP entry (e.g., for DHCP-assigned hosts).
    public func register(ip: IPv4Address, mac: MACAddress) {
        lock.lock()
        arpTable[ip] = mac
        lock.unlock()
    }
}
