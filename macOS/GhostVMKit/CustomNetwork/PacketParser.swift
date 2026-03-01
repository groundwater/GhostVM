import Foundation

// MARK: - EtherType Constants

public enum EtherType {
    public static let ipv4: UInt16 = 0x0800
    public static let arp: UInt16 = 0x0806
    public static let ipv6: UInt16 = 0x86DD
}

// MARK: - IP Protocol Constants

public enum IPProto {
    public static let icmp: UInt8 = 1
    public static let tcp: UInt8 = 6
    public static let udp: UInt8 = 17
}

// MARK: - Parsed Structures

public struct EthernetFrame {
    public let dstMAC: MACAddress
    public let srcMAC: MACAddress
    public let etherType: UInt16
    public let payload: Data
    /// Offset of payload within original data.
    public let payloadOffset: Int

    public static let headerLength = 14
}

public struct IPv4Header {
    public let version: UInt8
    public let ihl: UInt8
    public let totalLength: UInt16
    public let identification: UInt16
    public let flags: UInt8
    public let fragmentOffset: UInt16
    public let ttl: UInt8
    public let proto: UInt8
    public let headerChecksum: UInt16
    public let srcIP: IPv4Address
    public let dstIP: IPv4Address
    public let headerLength: Int  // ihl * 4
    public let payload: Data
    /// Offset of this header within the Ethernet payload.
    public let payloadOffset: Int
}

public struct TCPHeader {
    public let srcPort: UInt16
    public let dstPort: UInt16
    public let sequenceNumber: UInt32
    public let ackNumber: UInt32
    public let dataOffset: UInt8  // in 32-bit words
    public let flags: UInt8
    public let windowSize: UInt16
    public let checksum: UInt16
    public let urgentPointer: UInt16
    public let payload: Data

    // TCP flag constants
    public static let FIN: UInt8 = 0x01
    public static let SYN: UInt8 = 0x02
    public static let RST: UInt8 = 0x04
    public static let PSH: UInt8 = 0x08
    public static let ACK: UInt8 = 0x10

    public var isSYN: Bool { flags & TCPHeader.SYN != 0 }
    public var isFIN: Bool { flags & TCPHeader.FIN != 0 }
    public var isRST: Bool { flags & TCPHeader.RST != 0 }
    public var isACK: Bool { flags & TCPHeader.ACK != 0 }
}

public struct UDPHeader {
    public let srcPort: UInt16
    public let dstPort: UInt16
    public let length: UInt16
    public let checksum: UInt16
    public let payload: Data

    public static let headerLength = 8
}

public struct ARPPacket {
    public let hardwareType: UInt16
    public let protocolType: UInt16
    public let hardwareSize: UInt8
    public let protocolSize: UInt8
    public let opcode: UInt16
    public let senderMAC: MACAddress
    public let senderIP: IPv4Address
    public let targetMAC: MACAddress
    public let targetIP: IPv4Address

    public static let request: UInt16 = 1
    public static let reply: UInt16 = 2
}

public struct ICMPHeader {
    public let type: UInt8
    public let code: UInt8
    public let checksum: UInt16
    public let payload: Data

    // Common types
    public static let echoReply: UInt8 = 0
    public static let echoRequest: UInt8 = 8
}

// MARK: - Parsed Packet

public enum ParsedPacket {
    case arp(EthernetFrame, ARPPacket)
    case tcp(EthernetFrame, IPv4Header, TCPHeader)
    case udp(EthernetFrame, IPv4Header, UDPHeader)
    case icmp(EthernetFrame, IPv4Header, ICMPHeader)
    case unknownIPv4(EthernetFrame, IPv4Header)
    case unknownEther(EthernetFrame)
}

// MARK: - Parser

public enum PacketParser {

    /// Parse raw Ethernet frame data into a structured packet.
    /// Returns nil for malformed or truncated data.
    public static func parse(_ data: Data) -> ParsedPacket? {
        guard let frame = parseEthernet(data) else { return nil }

        switch frame.etherType {
        case EtherType.arp:
            guard let arp = parseARP(frame.payload) else { return nil }
            return .arp(frame, arp)

        case EtherType.ipv4:
            guard let ip = parseIPv4(frame.payload) else { return nil }
            switch ip.proto {
            case IPProto.tcp:
                guard let tcp = parseTCP(ip.payload) else { return nil }
                return .tcp(frame, ip, tcp)
            case IPProto.udp:
                guard let udp = parseUDP(ip.payload) else { return nil }
                return .udp(frame, ip, udp)
            case IPProto.icmp:
                guard let icmp = parseICMP(ip.payload) else { return nil }
                return .icmp(frame, ip, icmp)
            default:
                return .unknownIPv4(frame, ip)
            }

        default:
            return .unknownEther(frame)
        }
    }

    // MARK: - Layer Parsers

    public static func parseEthernet(_ data: Data) -> EthernetFrame? {
        guard data.count >= EthernetFrame.headerLength else { return nil }
        return data.withUnsafeBytes { buf -> EthernetFrame? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            guard let dstMAC = MACAddress(data: Data(bytes: ptr, count: 6)),
                  let srcMAC = MACAddress(data: Data(bytes: ptr + 6, count: 6)) else { return nil }
            let etherType = UInt16(ptr[12]) << 8 | UInt16(ptr[13])
            let payloadOffset = EthernetFrame.headerLength
            let payload = data.suffix(from: data.startIndex + payloadOffset)
            return EthernetFrame(dstMAC: dstMAC, srcMAC: srcMAC, etherType: etherType,
                                 payload: payload, payloadOffset: payloadOffset)
        }
    }

    public static func parseIPv4(_ data: Data) -> IPv4Header? {
        guard data.count >= 20 else { return nil }
        return data.withUnsafeBytes { buf -> IPv4Header? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let versionIHL = ptr[0]
            let version = versionIHL >> 4
            guard version == 4 else { return nil }
            let ihl = versionIHL & 0x0F
            let headerLen = Int(ihl) * 4
            guard headerLen >= 20, data.count >= headerLen else { return nil }

            let totalLength = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
            let identification = UInt16(ptr[4]) << 8 | UInt16(ptr[5])
            let flagsFrag = UInt16(ptr[6]) << 8 | UInt16(ptr[7])
            let flags = UInt8(flagsFrag >> 13)
            let fragmentOffset = flagsFrag & 0x1FFF
            let ttl = ptr[8]
            let proto = ptr[9]
            let checksum = UInt16(ptr[10]) << 8 | UInt16(ptr[11])

            let srcIP = IPv4Address(ptr[12], ptr[13], ptr[14], ptr[15])
            let dstIP = IPv4Address(ptr[16], ptr[17], ptr[18], ptr[19])

            let payloadOffset = headerLen
            let payload = data.suffix(from: data.startIndex + payloadOffset)

            return IPv4Header(version: version, ihl: ihl, totalLength: totalLength,
                              identification: identification, flags: flags,
                              fragmentOffset: fragmentOffset, ttl: ttl, proto: proto,
                              headerChecksum: checksum, srcIP: srcIP, dstIP: dstIP,
                              headerLength: headerLen, payload: payload, payloadOffset: payloadOffset)
        }
    }

    public static func parseTCP(_ data: Data) -> TCPHeader? {
        guard data.count >= 20 else { return nil }
        return data.withUnsafeBytes { buf -> TCPHeader? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let srcPort = UInt16(ptr[0]) << 8 | UInt16(ptr[1])
            let dstPort = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
            let seq = UInt32(ptr[4]) << 24 | UInt32(ptr[5]) << 16 | UInt32(ptr[6]) << 8 | UInt32(ptr[7])
            let ack = UInt32(ptr[8]) << 24 | UInt32(ptr[9]) << 16 | UInt32(ptr[10]) << 8 | UInt32(ptr[11])
            let dataOffset = ptr[12] >> 4
            let headerLen = Int(dataOffset) * 4
            guard headerLen >= 20, data.count >= headerLen else { return nil }
            let flags = ptr[13]
            let windowSize = UInt16(ptr[14]) << 8 | UInt16(ptr[15])
            let checksum = UInt16(ptr[16]) << 8 | UInt16(ptr[17])
            let urgentPointer = UInt16(ptr[18]) << 8 | UInt16(ptr[19])
            let payload = data.suffix(from: data.startIndex + headerLen)
            return TCPHeader(srcPort: srcPort, dstPort: dstPort, sequenceNumber: seq,
                             ackNumber: ack, dataOffset: dataOffset, flags: flags,
                             windowSize: windowSize, checksum: checksum,
                             urgentPointer: urgentPointer, payload: payload)
        }
    }

    public static func parseUDP(_ data: Data) -> UDPHeader? {
        guard data.count >= UDPHeader.headerLength else { return nil }
        return data.withUnsafeBytes { buf -> UDPHeader? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let srcPort = UInt16(ptr[0]) << 8 | UInt16(ptr[1])
            let dstPort = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
            let length = UInt16(ptr[4]) << 8 | UInt16(ptr[5])
            let checksum = UInt16(ptr[6]) << 8 | UInt16(ptr[7])
            let payload = data.suffix(from: data.startIndex + UDPHeader.headerLength)
            return UDPHeader(srcPort: srcPort, dstPort: dstPort, length: length,
                             checksum: checksum, payload: payload)
        }
    }

    public static func parseARP(_ data: Data) -> ARPPacket? {
        guard data.count >= 28 else { return nil }
        return data.withUnsafeBytes { buf -> ARPPacket? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let hwType = UInt16(ptr[0]) << 8 | UInt16(ptr[1])
            let protoType = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
            let hwSize = ptr[4]
            let protoSize = ptr[5]
            let opcode = UInt16(ptr[6]) << 8 | UInt16(ptr[7])

            guard hwSize == 6, protoSize == 4 else { return nil }

            let senderMAC = MACAddress(ptr[8], ptr[9], ptr[10], ptr[11], ptr[12], ptr[13])
            let senderIP = IPv4Address(ptr[14], ptr[15], ptr[16], ptr[17])
            let targetMAC = MACAddress(ptr[18], ptr[19], ptr[20], ptr[21], ptr[22], ptr[23])
            let targetIP = IPv4Address(ptr[24], ptr[25], ptr[26], ptr[27])

            return ARPPacket(hardwareType: hwType, protocolType: protoType,
                             hardwareSize: hwSize, protocolSize: protoSize, opcode: opcode,
                             senderMAC: senderMAC, senderIP: senderIP,
                             targetMAC: targetMAC, targetIP: targetIP)
        }
    }

    public static func parseICMP(_ data: Data) -> ICMPHeader? {
        guard data.count >= 4 else { return nil }
        return data.withUnsafeBytes { buf -> ICMPHeader? in
            let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let type = ptr[0]
            let code = ptr[1]
            let checksum = UInt16(ptr[2]) << 8 | UInt16(ptr[3])
            let payload = data.suffix(from: data.startIndex + 4)
            return ICMPHeader(type: type, code: code, checksum: checksum, payload: payload)
        }
    }
}
