import Foundation
import GhostVMKit

/// Inspects Ethernet frames and decides whether to allow or drop them
/// based on the active `NetworkAccessPolicy`.
struct PacketFilter {
    var policy: NetworkAccessPolicy

    /// IPv4 address of the vmnet gateway (in host byte order).
    /// Set after vmnet starts so internetOnly can exempt it.
    var vmnetGatewayIP: UInt32?

    func shouldAllow(frame: Data) -> Bool {
        switch policy {
        case .fullAccess:
            return true
        case .disableNetwork:
            return false
        case .internetOnly:
            return shouldAllowInternetOnly(frame: frame)
        }
    }

    // MARK: - Internet Only

    /// Allows all traffic except to RFC1918, link-local, and multicast destinations.
    /// Exempts the vmnet gateway so internet traffic can still flow.
    private func shouldAllowInternetOnly(frame: Data) -> Bool {
        guard frame.count >= 14 else { return false }

        let etherType = readUInt16BE(frame, offset: 12)

        // ARP is local-only traffic — block it
        if etherType == 0x0806 { return false }

        // IPv4
        if etherType == 0x0800 {
            guard frame.count >= 34 else { return false }
            let destIP = readUInt32BE(frame, offset: 30)
            if isLocalIPv4(destIP) {
                // Exempt vmnet gateway
                if let gateway = vmnetGatewayIP, destIP == gateway { return true }
                return false
            }
            return true
        }

        // IPv6
        if etherType == 0x86DD {
            guard frame.count >= 38 else { return false }
            // Destination address starts at offset 24 in IPv6 header (14 + 24 = 38)
            let destAddr = readIPv6Dest(frame, offset: 38)
            if isLocalIPv6(destAddr) { return false }
            return true
        }

        // Other EtherTypes (e.g. 802.1Q) — allow by default
        return true
    }

    // MARK: - Address Classification

    /// Returns true if the IPv4 address (host byte order) is RFC1918, link-local, or multicast.
    private func isLocalIPv4(_ ip: UInt32) -> Bool {
        let a = (ip >> 24) & 0xFF
        let b = (ip >> 16) & 0xFF

        // 10.0.0.0/8
        if a == 10 { return true }
        // 172.16.0.0/12
        if a == 172 && (b >= 16 && b <= 31) { return true }
        // 192.168.0.0/16
        if a == 192 && b == 168 { return true }
        // 169.254.0.0/16 (link-local)
        if a == 169 && b == 254 { return true }
        // 224.0.0.0/4 (multicast)
        if a >= 224 && a <= 239 { return true }
        // 255.255.255.255 (broadcast)
        if ip == 0xFFFFFFFF { return true }
        // 127.0.0.0/8 (loopback)
        if a == 127 { return true }

        return false
    }

    /// Returns true if the IPv6 destination is link-local (fe80::/10), multicast (ff00::/8),
    /// or loopback (::1).
    private func isLocalIPv6(_ addr: (UInt64, UInt64)) -> Bool {
        let hi = addr.0
        let lo = addr.1

        // Link-local: fe80::/10
        if (hi >> 54) == (0xFE80 >> 6) { return true }
        // Multicast: ff00::/8
        if (hi >> 56) == 0xFF { return true }
        // Loopback: ::1
        if hi == 0 && lo == 1 { return true }

        return false
    }

    // MARK: - Byte Reading Helpers

    private func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        return data.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        }
    }

    private func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        return data.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset]) << 24
                | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8
                | UInt32(bytes[offset + 3])
        }
    }

    /// Reads a 16-byte IPv6 address as two UInt64s (big-endian).
    private func readIPv6Dest(_ data: Data, offset: Int) -> (UInt64, UInt64) {
        return data.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            var hi: UInt64 = 0
            var lo: UInt64 = 0
            for i in 0..<8 {
                hi = (hi << 8) | UInt64(bytes[offset + i])
            }
            for i in 8..<16 {
                lo = (lo << 8) | UInt64(bytes[offset + i])
            }
            return (hi, lo)
        }
    }
}
