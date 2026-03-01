import Foundation

/// Result of firewall evaluation.
public enum FirewallAction: Equatable {
    case allow
    case block
}

/// Evaluates packets against firewall rules with first-match-wins semantics.
public final class FirewallEngine {
    private let rules: [NetworkRule]
    private let defaultPolicy: FirewallDefaultPolicy
    private let aliases: [NetworkAlias]

    /// Pre-parsed alias lookups.
    private let hostAliases: [String: Set<String>]     // name → set of IPs/CIDRs
    private let networkAliases: [String: Set<String>]   // name → set of CIDRs
    private let portAliases: [String: Set<UInt16>]      // name → set of ports

    public init(config: FirewallConfig, aliases: [NetworkAlias] = []) {
        self.rules = config.rules
        self.defaultPolicy = config.defaultPolicy
        self.aliases = aliases

        var ha: [String: Set<String>] = [:]
        var na: [String: Set<String>] = [:]
        var pa: [String: Set<UInt16>] = [:]
        for alias in aliases {
            switch alias.type {
            case .hosts:
                ha[alias.name] = Set(alias.entries)
            case .networks:
                na[alias.name] = Set(alias.entries)
            case .ports:
                pa[alias.name] = Set(alias.entries.compactMap { UInt16($0) })
            }
        }
        self.hostAliases = ha
        self.networkAliases = na
        self.portAliases = pa
    }

    /// Evaluate a parsed packet against firewall rules.
    /// Returns .allow or .block.
    public func evaluate(packet: ParsedPacket, direction: RuleDirection) -> FirewallAction {
        for rule in rules {
            guard rule.enabled else { continue }
            guard directionMatches(rule.direction, actual: direction) else { continue }

            if matches(rule: rule, packet: packet) {
                switch rule.action {
                case .allow:
                    return .allow
                case .block:
                    return .block
                case .redirect:
                    return .allow // redirects are treated as allow for now
                }
            }
        }

        // Default policy
        return defaultPolicy == .allow ? .allow : .block
    }

    // MARK: - Matching

    private func directionMatches(_ ruleDir: RuleDirection, actual: RuleDirection) -> Bool {
        if ruleDir == .both { return true }
        return ruleDir == actual
    }

    private func matches(rule: NetworkRule, packet: ParsedPacket) -> Bool {
        switch rule.layer {
        case .l2:
            return matchesL2(rule: rule, packet: packet)
        case .l3:
            return matchesL3(rule: rule, packet: packet)
        }
    }

    private func matchesL2(rule: NetworkRule, packet: ParsedPacket) -> Bool {
        let frame: EthernetFrame
        switch packet {
        case .arp(let f, _): frame = f
        case .tcp(let f, _, _): frame = f
        case .udp(let f, _, _): frame = f
        case .icmp(let f, _, _): frame = f
        case .unknownIPv4(let f, _): frame = f
        case .unknownEther(let f): frame = f
        }

        // Broadcast check
        if rule.blockBroadcast == true && frame.dstMAC.isBroadcast {
            return true
        }

        // Source MAC
        if let srcMAC = rule.srcMAC, let mac = MACAddress(string: srcMAC) {
            if frame.srcMAC != mac { return false }
        }

        // Destination MAC
        if let dstMAC = rule.dstMAC, let mac = MACAddress(string: dstMAC) {
            if frame.dstMAC != mac { return false }
        }

        // EtherType
        if let etherTypeStr = rule.etherType, let etherType = UInt16(etherTypeStr.replacingOccurrences(of: "0x", with: ""), radix: 16) {
            if frame.etherType != etherType { return false }
        }

        return true
    }

    private func matchesL3(rule: NetworkRule, packet: ParsedPacket) -> Bool {
        let ip: IPv4Header
        let transportProto: UInt8
        var srcPort: UInt16?
        var dstPort: UInt16?

        switch packet {
        case .tcp(_, let i, let t):
            ip = i; transportProto = IPProto.tcp
            srcPort = t.srcPort; dstPort = t.dstPort
        case .udp(_, let i, let u):
            ip = i; transportProto = IPProto.udp
            srcPort = u.srcPort; dstPort = u.dstPort
        case .icmp(_, let i, _):
            ip = i; transportProto = IPProto.icmp
        case .unknownIPv4(_, let i):
            ip = i; transportProto = i.proto
        default:
            return false // L3 rules don't match non-IP packets
        }

        // Source CIDR
        if let srcCIDRStr = rule.srcCIDR {
            if !matchesCIDROrAlias(srcCIDRStr, ip: ip.srcIP) { return false }
        }

        // Destination CIDR
        if let dstCIDRStr = rule.dstCIDR {
            if !matchesCIDROrAlias(dstCIDRStr, ip: ip.dstIP) { return false }
        }

        // IP Protocol
        if let ruleProto = rule.ipProtocol, ruleProto != .any {
            let protoValue: UInt8
            switch ruleProto {
            case .tcp: protoValue = IPProto.tcp
            case .udp: protoValue = IPProto.udp
            case .icmp: protoValue = IPProto.icmp
            case .any: protoValue = transportProto // always matches
            }
            if transportProto != protoValue { return false }
        }

        // Source port
        if let ruleSrcPort = rule.srcPort {
            guard let sp = srcPort else { return false }
            if sp != ruleSrcPort { return false }
        }

        // Destination port
        if let ruleDstPort = rule.dstPort {
            guard let dp = dstPort else { return false }
            if dp != ruleDstPort { return false }
        }

        return true
    }

    private func matchesCIDROrAlias(_ value: String, ip: IPv4Address) -> Bool {
        // Check if it's a CIDR
        if let cidr = CIDRRange(string: value) {
            return cidr.contains(ip)
        }

        // Check if it's an alias name
        if let hosts = hostAliases[value] {
            return hosts.contains(ip.description)
        }
        if let networks = networkAliases[value] {
            return networks.contains { cidrStr in
                CIDRRange(string: cidrStr)?.contains(ip) ?? false
            }
        }

        // Try as a plain IP
        if let plainIP = IPv4Address(string: value) {
            return plainIP == ip
        }

        return false
    }
}
