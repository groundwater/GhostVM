import Foundation

public enum RuleAction: String, Codable, CaseIterable {
    case allow
    case block
    case redirect
}

public enum RuleLayer: String, Codable, CaseIterable {
    case l2
    case l3
}

public enum RuleDirection: String, Codable, CaseIterable {
    case inbound
    case outbound
    case both
}

public enum NetworkZone: String, Codable, CaseIterable {
    case wan
    case lan
    case any
}

public enum IPProtocol: String, Codable, CaseIterable {
    case tcp
    case udp
    case icmp
    case any
}

public struct NetworkRule: Codable, Identifiable, Equatable {
    public var id: UUID
    public var enabled: Bool
    public var action: RuleAction
    public var layer: RuleLayer
    public var direction: RuleDirection

    // L2 match criteria (optional)
    public var srcMAC: String?
    public var dstMAC: String?
    public var etherType: String?
    public var blockBroadcast: Bool?

    // L3 match criteria (optional)
    public var srcCIDR: String?
    public var dstCIDR: String?
    public var ipProtocol: IPProtocol?
    public var dstPort: UInt16?
    public var srcPort: UInt16?

    public var comment: String?
    public var zone: NetworkZone?

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        action: RuleAction = .block,
        layer: RuleLayer = .l3,
        direction: RuleDirection = .both,
        srcMAC: String? = nil,
        dstMAC: String? = nil,
        etherType: String? = nil,
        blockBroadcast: Bool? = nil,
        srcCIDR: String? = nil,
        dstCIDR: String? = nil,
        ipProtocol: IPProtocol? = nil,
        dstPort: UInt16? = nil,
        srcPort: UInt16? = nil,
        comment: String? = nil,
        zone: NetworkZone? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.action = action
        self.layer = layer
        self.direction = direction
        self.srcMAC = srcMAC
        self.dstMAC = dstMAC
        self.etherType = etherType
        self.blockBroadcast = blockBroadcast
        self.srcCIDR = srcCIDR
        self.dstCIDR = dstCIDR
        self.ipProtocol = ipProtocol
        self.dstPort = dstPort
        self.srcPort = srcPort
        self.comment = comment
        self.zone = zone
    }

    /// Human-readable summary of what this rule matches.
    public var matchSummary: String {
        switch layer {
        case .l2:
            if blockBroadcast == true { return "broadcast" }
            var parts: [String] = []
            if let src = srcMAC { parts.append("src \(src)") }
            if let dst = dstMAC { parts.append("dst \(dst)") }
            if let ether = etherType { parts.append("ether \(ether)") }
            return parts.isEmpty ? "any" : parts.joined(separator: ", ")
        case .l3:
            var parts: [String] = []
            if let src = srcCIDR { parts.append("src \(src)") }
            if let dst = dstCIDR { parts.append("dst \(dst)") }
            if let proto = ipProtocol, proto != .any { parts.append(proto.rawValue) }
            if let dp = dstPort { parts.append(":\(dp)") }
            if let sp = srcPort { parts.append("from :\(sp)") }
            return parts.isEmpty ? "any" : parts.joined(separator: " ")
        }
    }

    /// Short direction label for display.
    public var directionLabel: String {
        switch direction {
        case .inbound: return "In"
        case .outbound: return "Out"
        case .both: return "Both"
        }
    }

    /// Short zone label for display.
    public var zoneLabel: String {
        switch zone {
        case .wan: return "WAN"
        case .lan: return "LAN"
        case .any, .none: return "Any"
        }
    }
}
