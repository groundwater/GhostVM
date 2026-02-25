import Foundation
import Darwin

/// Describes a host network interface detected via getifaddrs.
public struct HostNetworkInterface: Identifiable, Equatable {
    public let id: String  // BSD name, e.g. "bridge100"
    public let name: String
    public let kind: InterfaceKind
    public let ipv4Address: String?
    public let isUp: Bool

    public var displayName: String {
        if let ip = ipv4Address {
            return "\(name) (\(ip))"
        }
        return name
    }

    public enum InterfaceKind: String, CaseIterable {
        case hardware       // en0, en1 — Wi-Fi, Ethernet
        case dockerBridge   // bridge100+ — Docker Desktop
        case vmnet          // vmnet0-8 — Parallels / VMware
        case tap            // tap0+ — QEMU / UTM
        case utun           // utun0+ — VPN tunnels, WireGuard
        case bridge         // bridge0+ — macOS system bridges
        case loopback       // lo0
        case other

        public var label: String {
            switch self {
            case .hardware: return "Hardware"
            case .dockerBridge: return "Docker"
            case .vmnet: return "VMware/Parallels"
            case .tap: return "TAP (QEMU/UTM)"
            case .utun: return "VPN Tunnel"
            case .bridge: return "System Bridge"
            case .loopback: return "Loopback"
            case .other: return "Other"
            }
        }

        /// Whether this kind is interesting for VM bridging.
        public var isBridgeable: Bool {
            switch self {
            case .hardware, .dockerBridge, .vmnet, .tap, .bridge:
                return true
            case .utun, .loopback, .other:
                return false
            }
        }
    }
}

/// Scans host network interfaces using getifaddrs (sees everything, not just VZ-bridgeable).
public enum HostNetworkScanner {

    /// Returns all detected interfaces with IPv4 info, classified by kind.
    public static func scan() -> [HostNetworkInterface] {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let firstAddr = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        // Collect unique interface names and their IPv4 addresses
        var seen: [String: (ipv4: String?, flags: UInt32)] = [:]

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ifa = current {
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = ifa.pointee.ifa_flags

            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                // Extract IPv4 address
                let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addrCopy = addr
                inet_ntop(AF_INET, &addrCopy, &buf, socklen_t(INET_ADDRSTRLEN))
                let ipStr = String(cString: buf)
                seen[name] = (ipv4: ipStr, flags: flags)
            } else if seen[name] == nil {
                seen[name] = (ipv4: nil, flags: flags)
            }

            current = ifa.pointee.ifa_next
        }

        return seen.map { name, info in
            HostNetworkInterface(
                id: name,
                name: friendlyName(for: name),
                kind: classify(name),
                ipv4Address: info.ipv4,
                isUp: (info.flags & UInt32(IFF_UP)) != 0
            )
        }
        .sorted { a, b in
            if a.kind.isBridgeable != b.kind.isBridgeable { return a.kind.isBridgeable }
            return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        }
    }

    /// Returns only interfaces that are up and suitable for VM bridging.
    public static func bridgeableInterfaces() -> [HostNetworkInterface] {
        scan().filter { $0.isUp && $0.kind.isBridgeable }
    }

    /// Returns only virtual/software interfaces (Docker bridges, vmnet, tap, utun).
    public static func virtualInterfaces() -> [HostNetworkInterface] {
        scan().filter { $0.isUp && $0.kind != .hardware && $0.kind != .loopback && $0.kind != .other }
    }

    private static func classify(_ name: String) -> HostNetworkInterface.InterfaceKind {
        if name == "lo0" { return .loopback }
        if name.hasPrefix("en") { return .hardware }
        if name.hasPrefix("vmnet") { return .vmnet }
        if name.hasPrefix("tap") { return .tap }
        if name.hasPrefix("utun") { return .utun }

        // Docker Desktop creates bridge100, bridge101, etc.
        // macOS system bridge is bridge0
        if name.hasPrefix("bridge") {
            if let numStr = name.dropFirst("bridge".count).description as String?,
               let num = Int(numStr), num >= 100 {
                return .dockerBridge
            }
            return .bridge
        }

        // Some filter/tunnel interfaces
        if name.hasPrefix("gif") || name.hasPrefix("stf") || name.hasPrefix("anpi") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("ap") {
            return .other
        }

        return .other
    }

    private static func friendlyName(for bsdName: String) -> String {
        switch classify(bsdName) {
        case .hardware:
            return "Hardware (\(bsdName))"
        case .dockerBridge:
            return "Docker Bridge (\(bsdName))"
        case .vmnet:
            return "VMnet (\(bsdName))"
        case .tap:
            return "TAP (\(bsdName))"
        case .utun:
            return "VPN Tunnel (\(bsdName))"
        case .bridge:
            return "System Bridge (\(bsdName))"
        case .loopback:
            return "Loopback"
        case .other:
            return bsdName
        }
    }
}
