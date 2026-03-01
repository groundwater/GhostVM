import Foundation

/// A 6-byte MAC address.
public struct MACAddress: Equatable, Hashable, CustomStringConvertible {
    public let bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    public init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, _ b4: UInt8, _ b5: UInt8) {
        self.bytes = (b0, b1, b2, b3, b4, b5)
    }

    public init?(data: Data) {
        guard data.count >= 6 else { return nil }
        self.bytes = (data[data.startIndex], data[data.startIndex+1], data[data.startIndex+2],
                      data[data.startIndex+3], data[data.startIndex+4], data[data.startIndex+5])
    }

    /// Parse "AA:BB:CC:DD:EE:FF" format.
    public init?(string: String) {
        let parts = string.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        self.bytes = (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
    }

    public static let broadcast = MACAddress(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF)
    public static let zero = MACAddress(0, 0, 0, 0, 0, 0)

    public var isBroadcast: Bool { self == MACAddress.broadcast }

    public var data: Data {
        Data([bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5])
    }

    public var description: String {
        String(format: "%02x:%02x:%02x:%02x:%02x:%02x",
               bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5)
    }

    public static func == (lhs: MACAddress, rhs: MACAddress) -> Bool {
        lhs.bytes.0 == rhs.bytes.0 && lhs.bytes.1 == rhs.bytes.1 &&
        lhs.bytes.2 == rhs.bytes.2 && lhs.bytes.3 == rhs.bytes.3 &&
        lhs.bytes.4 == rhs.bytes.4 && lhs.bytes.5 == rhs.bytes.5
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bytes.0); hasher.combine(bytes.1); hasher.combine(bytes.2)
        hasher.combine(bytes.3); hasher.combine(bytes.4); hasher.combine(bytes.5)
    }
}

/// A simple IPv4 address backed by UInt32 (network byte order internally is host order).
public struct IPv4Address: Equatable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(_ value: UInt32) {
        self.rawValue = value
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        self.rawValue = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    /// Parse "a.b.c.d" format.
    public init?(string: String) {
        let parts = string.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        self.init(parts[0], parts[1], parts[2], parts[3])
    }

    public var octets: (UInt8, UInt8, UInt8, UInt8) {
        (UInt8((rawValue >> 24) & 0xFF), UInt8((rawValue >> 16) & 0xFF),
         UInt8((rawValue >> 8) & 0xFF), UInt8(rawValue & 0xFF))
    }

    public var data: Data {
        let o = octets
        return Data([o.0, o.1, o.2, o.3])
    }

    public init?(data: Data, offset: Int = 0) {
        guard data.count >= offset + 4 else { return nil }
        let base = data.startIndex + offset
        self.init(data[base], data[base+1], data[base+2], data[base+3])
    }

    public var description: String {
        let o = octets
        return "\(o.0).\(o.1).\(o.2).\(o.3)"
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Increment by n.
    public func advanced(by n: UInt32) -> IPv4Address {
        IPv4Address(rawValue &+ n)
    }
}

/// CIDR range for IPv4 (e.g., "10.0.0.0/24").
public struct CIDRRange: Equatable, CustomStringConvertible {
    public let network: IPv4Address
    public let prefixLength: Int
    public let mask: UInt32

    public init?(string: String) {
        let parts = string.split(separator: "/")
        guard parts.count == 2,
              let addr = IPv4Address(string: String(parts[0])),
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 32 else { return nil }
        self.prefixLength = prefix
        self.mask = prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)
        self.network = IPv4Address(addr.rawValue & self.mask)
    }

    public init(network: IPv4Address, prefixLength: Int) {
        self.prefixLength = prefixLength
        self.mask = prefixLength == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefixLength)
        self.network = IPv4Address(network.rawValue & self.mask)
    }

    public func contains(_ ip: IPv4Address) -> Bool {
        (ip.rawValue & mask) == network.rawValue
    }

    /// First usable host address (network + 1).
    public var firstHost: IPv4Address {
        network.advanced(by: 1)
    }

    /// Last usable host address (broadcast - 1).
    public var lastHost: IPv4Address {
        IPv4Address(network.rawValue | ~mask).advanced(by: 0 &- 1) // broadcast - 1
    }

    /// Broadcast address for this range.
    public var broadcastAddress: IPv4Address {
        IPv4Address(network.rawValue | ~mask)
    }

    /// Subnet mask as IPv4Address.
    public var subnetMask: IPv4Address {
        IPv4Address(mask)
    }

    public var description: String {
        "\(network)/\(prefixLength)"
    }
}
