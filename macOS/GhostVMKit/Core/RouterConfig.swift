import Foundation

public struct RouterConfig: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var wan: WANConfig
    public var lan: LANConfig
    public var dhcp: DHCPConfig
    public var dns: DNSConfig
    public var firewall: FirewallConfig
    public var portForwarding: [PortForwardRule]
    public var staticRoutes: [StaticRoute]
    public var aliases: [NetworkAlias]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        name: String = "New Network",
        wan: WANConfig = WANConfig(),
        lan: LANConfig = LANConfig(),
        dhcp: DHCPConfig = DHCPConfig(),
        dns: DNSConfig = DNSConfig(),
        firewall: FirewallConfig = FirewallConfig(),
        portForwarding: [PortForwardRule] = [],
        staticRoutes: [StaticRoute] = [],
        aliases: [NetworkAlias] = [],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.wan = wan
        self.lan = lan
        self.dhcp = dhcp
        self.dns = dns
        self.firewall = firewall
        self.portForwarding = portForwarding
        self.staticRoutes = staticRoutes
        self.aliases = aliases
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Migrate from legacy CustomNetworkConfig.
    public init(migratingFrom old: CustomNetworkConfig) {
        self.id = old.id
        self.name = old.name
        self.createdAt = old.createdAt
        self.modifiedAt = old.modifiedAt

        self.lan = LANConfig(subnet: old.subnet, gateway: old.gatewayIP)

        self.dhcp = DHCPConfig(
            enabled: old.dhcpEnabled,
            rangeStart: old.dhcpRangeStart,
            rangeEnd: old.dhcpRangeEnd
        )

        if old.internetAccess {
            self.wan = WANConfig(upstream: old.upstreamInterface, mode: .nat, masquerade: true)
        } else {
            self.wan = WANConfig(upstream: old.upstreamInterface, mode: .isolated, masquerade: false)
        }

        self.dns = DNSConfig()
        self.firewall = FirewallConfig(rules: old.rules)
        self.portForwarding = []
        self.staticRoutes = []
        self.aliases = []
    }

    /// Human-readable summary for display in pickers and lists.
    public var summaryLine: String {
        var parts = [lan.subnet]

        switch wan.mode {
        case .nat:
            if let upstream = wan.upstream {
                parts.append("NAT via \(upstream)")
            } else {
                parts.append("NAT")
            }
        case .passthrough:
            if let upstream = wan.upstream {
                parts.append("Bridge \(upstream)")
            } else {
                parts.append("Passthrough")
            }
        case .isolated:
            parts.append("Isolated")
        }

        if dhcp.enabled {
            parts.append("DHCP")
        }

        let ruleCount = firewall.rules.count
        if ruleCount > 0 {
            parts.append(ruleCount == 1 ? "1 rule" : "\(ruleCount) rules")
        }

        let fwdCount = portForwarding.count
        if fwdCount > 0 {
            parts.append(fwdCount == 1 ? "1 fwd" : "\(fwdCount) fwds")
        }

        return parts.joined(separator: " \u{00B7} ")
    }
}
