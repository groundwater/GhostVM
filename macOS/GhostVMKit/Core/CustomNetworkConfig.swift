import Foundation

public struct CustomNetworkConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var subnet: String
    public var gatewayIP: String
    public var dhcpEnabled: Bool
    public var dhcpRangeStart: String
    public var dhcpRangeEnd: String
    public var internetAccess: Bool
    /// BSD name of a host interface to bridge/join (e.g. "bridge100" for Docker, "vmnet1" for Parallels).
    /// When set, the custom network routes traffic to this host interface instead of (or in addition to) the internet.
    public var upstreamInterface: String?
    public var rules: [NetworkRule]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "New Network",
        subnet: String = "10.100.0.0/24",
        gatewayIP: String = "10.100.0.1",
        dhcpEnabled: Bool = true,
        dhcpRangeStart: String = "10.100.0.10",
        dhcpRangeEnd: String = "10.100.0.254",
        internetAccess: Bool = true,
        upstreamInterface: String? = nil,
        rules: [NetworkRule] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.subnet = subnet
        self.gatewayIP = gatewayIP
        self.dhcpEnabled = dhcpEnabled
        self.dhcpRangeStart = dhcpRangeStart
        self.dhcpRangeEnd = dhcpRangeEnd
        self.internetAccess = internetAccess
        self.upstreamInterface = upstreamInterface
        self.rules = rules
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Summary line for display in pickers and lists.
    public var summaryLine: String {
        var parts = [subnet]
        let ruleCount = rules.count
        parts.append(ruleCount == 1 ? "1 rule" : "\(ruleCount) rules")
        if let upstream = upstreamInterface {
            parts.append("via \(upstream)")
        } else {
            parts.append(internetAccess ? "Internet \u{2713}" : "Isolated")
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
