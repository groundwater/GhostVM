import Foundation

// MARK: - Checksum

public enum Checksum {
    /// Standard Internet checksum (RFC 1071).
    public static func internetChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let count = data.count
        data.withUnsafeBytes { buf in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var i = 0
            while i + 1 < count {
                sum += UInt32(ptr[i]) << 8 | UInt32(ptr[i + 1])
                i += 2
            }
            if i < count {
                sum += UInt32(ptr[i]) << 8
            }
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum & 0xFFFF)
    }

    /// TCP/UDP checksum with pseudo-header.
    public static func tcpUDPChecksum(srcIP: IPv4Address, dstIP: IPv4Address, proto: UInt8, payload: Data) -> UInt16 {
        var pseudo = Data()
        pseudo.append(srcIP.data)
        pseudo.append(dstIP.data)
        pseudo.append(0) // reserved
        pseudo.append(proto)
        let len = UInt16(payload.count)
        pseudo.append(UInt8(len >> 8))
        pseudo.append(UInt8(len & 0xFF))
        pseudo.append(payload)
        return internetChecksum(pseudo)
    }
}

// MARK: - PacketBuilder

public enum PacketBuilder {

    // MARK: - Ethernet

    /// Build a raw Ethernet frame.
    public static func ethernetFrame(dst: MACAddress, src: MACAddress, etherType: UInt16, payload: Data) -> Data {
        var frame = Data(capacity: 14 + payload.count)
        frame.append(dst.data)
        frame.append(src.data)
        frame.append(UInt8(etherType >> 8))
        frame.append(UInt8(etherType & 0xFF))
        frame.append(payload)
        return frame
    }

    // MARK: - ARP

    /// Build an ARP reply.
    public static func arpReply(
        senderMAC: MACAddress, senderIP: IPv4Address,
        targetMAC: MACAddress, targetIP: IPv4Address
    ) -> Data {
        var arp = Data(capacity: 28)
        arp.append(contentsOf: [0x00, 0x01]) // hardware type: Ethernet
        arp.append(contentsOf: [0x08, 0x00]) // protocol type: IPv4
        arp.append(6)  // hardware size
        arp.append(4)  // protocol size
        arp.append(contentsOf: [0x00, 0x02]) // opcode: reply
        arp.append(senderMAC.data)
        arp.append(senderIP.data)
        arp.append(targetMAC.data)
        arp.append(targetIP.data)
        return arp
    }

    /// Build a full ARP reply Ethernet frame.
    public static func arpReplyFrame(
        senderMAC: MACAddress, senderIP: IPv4Address,
        targetMAC: MACAddress, targetIP: IPv4Address
    ) -> Data {
        let arpPayload = arpReply(senderMAC: senderMAC, senderIP: senderIP,
                                  targetMAC: targetMAC, targetIP: targetIP)
        return ethernetFrame(dst: targetMAC, src: senderMAC, etherType: EtherType.arp, payload: arpPayload)
    }

    // MARK: - IPv4

    /// Build an IPv4 packet (without Ethernet framing).
    /// Checksum is computed automatically.
    public static func ipv4Packet(
        srcIP: IPv4Address, dstIP: IPv4Address, proto: UInt8, ttl: UInt8 = 64,
        identification: UInt16 = 0, payload: Data
    ) -> Data {
        let headerLen = 20
        let totalLen = UInt16(headerLen + payload.count)
        var header = Data(capacity: headerLen)
        header.append(0x45) // version=4, ihl=5
        header.append(0x00) // DSCP/ECN
        header.append(UInt8(totalLen >> 8))
        header.append(UInt8(totalLen & 0xFF))
        header.append(UInt8(identification >> 8))
        header.append(UInt8(identification & 0xFF))
        header.append(contentsOf: [0x40, 0x00]) // Don't Fragment, offset=0
        header.append(ttl)
        header.append(proto)
        header.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        header.append(srcIP.data)
        header.append(dstIP.data)

        // Compute and insert header checksum
        let cksum = Checksum.internetChecksum(header)
        header[10] = UInt8(cksum >> 8)
        header[11] = UInt8(cksum & 0xFF)

        var packet = header
        packet.append(payload)
        return packet
    }

    // MARK: - UDP

    /// Build a UDP segment (without IP header).
    /// Checksum is computed using the pseudo-header.
    public static func udpSegment(
        srcPort: UInt16, dstPort: UInt16,
        srcIP: IPv4Address, dstIP: IPv4Address,
        payload: Data
    ) -> Data {
        let length = UInt16(UDPHeader.headerLength + payload.count)
        var segment = Data(capacity: Int(length))
        segment.append(UInt8(srcPort >> 8))
        segment.append(UInt8(srcPort & 0xFF))
        segment.append(UInt8(dstPort >> 8))
        segment.append(UInt8(dstPort & 0xFF))
        segment.append(UInt8(length >> 8))
        segment.append(UInt8(length & 0xFF))
        segment.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        segment.append(payload)

        let cksum = Checksum.tcpUDPChecksum(srcIP: srcIP, dstIP: dstIP, proto: IPProto.udp, payload: segment)
        segment[6] = UInt8(cksum >> 8)
        segment[7] = UInt8(cksum & 0xFF)

        return segment
    }

    /// Build a complete UDP/IPv4 Ethernet frame.
    public static func udpFrame(
        dstMAC: MACAddress, srcMAC: MACAddress,
        srcIP: IPv4Address, dstIP: IPv4Address,
        srcPort: UInt16, dstPort: UInt16,
        payload: Data
    ) -> Data {
        let udp = udpSegment(srcPort: srcPort, dstPort: dstPort, srcIP: srcIP, dstIP: dstIP, payload: payload)
        let ip = ipv4Packet(srcIP: srcIP, dstIP: dstIP, proto: IPProto.udp, payload: udp)
        return ethernetFrame(dst: dstMAC, src: srcMAC, etherType: EtherType.ipv4, payload: ip)
    }

    // MARK: - TCP

    /// Build a TCP segment (without IP header).
    /// Checksum is computed using the pseudo-header.
    public static func tcpSegment(
        srcPort: UInt16, dstPort: UInt16,
        sequenceNumber: UInt32, ackNumber: UInt32,
        flags: UInt8, windowSize: UInt16 = 65535,
        srcIP: IPv4Address, dstIP: IPv4Address,
        payload: Data = Data()
    ) -> Data {
        let dataOffset: UInt8 = 5 // 20 bytes, no options
        let headerLen = 20
        var segment = Data(capacity: headerLen + payload.count)
        segment.append(UInt8(srcPort >> 8))
        segment.append(UInt8(srcPort & 0xFF))
        segment.append(UInt8(dstPort >> 8))
        segment.append(UInt8(dstPort & 0xFF))
        segment.append(UInt8(sequenceNumber >> 24))
        segment.append(UInt8((sequenceNumber >> 16) & 0xFF))
        segment.append(UInt8((sequenceNumber >> 8) & 0xFF))
        segment.append(UInt8(sequenceNumber & 0xFF))
        segment.append(UInt8(ackNumber >> 24))
        segment.append(UInt8((ackNumber >> 16) & 0xFF))
        segment.append(UInt8((ackNumber >> 8) & 0xFF))
        segment.append(UInt8(ackNumber & 0xFF))
        segment.append(dataOffset << 4)
        segment.append(flags)
        segment.append(UInt8(windowSize >> 8))
        segment.append(UInt8(windowSize & 0xFF))
        segment.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        segment.append(contentsOf: [0x00, 0x00]) // urgent pointer

        segment.append(payload)

        let cksum = Checksum.tcpUDPChecksum(srcIP: srcIP, dstIP: dstIP, proto: IPProto.tcp, payload: segment)
        segment[16] = UInt8(cksum >> 8)
        segment[17] = UInt8(cksum & 0xFF)

        return segment
    }

    /// Build a complete TCP/IPv4 Ethernet frame.
    public static func tcpFrame(
        dstMAC: MACAddress, srcMAC: MACAddress,
        srcIP: IPv4Address, dstIP: IPv4Address,
        srcPort: UInt16, dstPort: UInt16,
        sequenceNumber: UInt32, ackNumber: UInt32,
        flags: UInt8, windowSize: UInt16 = 65535,
        payload: Data = Data()
    ) -> Data {
        let tcp = tcpSegment(srcPort: srcPort, dstPort: dstPort,
                             sequenceNumber: sequenceNumber, ackNumber: ackNumber,
                             flags: flags, windowSize: windowSize,
                             srcIP: srcIP, dstIP: dstIP, payload: payload)
        let ip = ipv4Packet(srcIP: srcIP, dstIP: dstIP, proto: IPProto.tcp, payload: tcp)
        return ethernetFrame(dst: dstMAC, src: srcMAC, etherType: EtherType.ipv4, payload: ip)
    }

    // MARK: - ICMP

    /// Build an ICMP echo reply from a request.
    public static func icmpEchoReply(requestPayload: Data) -> Data {
        var icmp = Data(capacity: 4 + requestPayload.count)
        icmp.append(ICMPHeader.echoReply) // type
        icmp.append(0) // code
        icmp.append(contentsOf: [0x00, 0x00]) // checksum placeholder
        icmp.append(requestPayload) // includes identifier, sequence, data

        let cksum = Checksum.internetChecksum(icmp)
        icmp[2] = UInt8(cksum >> 8)
        icmp[3] = UInt8(cksum & 0xFF)

        return icmp
    }

    /// Build a complete ICMP echo reply Ethernet frame.
    public static func icmpEchoReplyFrame(
        dstMAC: MACAddress, srcMAC: MACAddress,
        srcIP: IPv4Address, dstIP: IPv4Address,
        requestPayload: Data
    ) -> Data {
        let icmp = icmpEchoReply(requestPayload: requestPayload)
        let ip = ipv4Packet(srcIP: srcIP, dstIP: dstIP, proto: IPProto.icmp, payload: icmp)
        return ethernetFrame(dst: dstMAC, src: srcMAC, etherType: EtherType.ipv4, payload: ip)
    }
}
