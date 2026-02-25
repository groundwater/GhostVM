import Foundation

public struct DHCPStaticLease: Codable, Identifiable, Equatable {
    public var id: UUID
    public var mac: String
    public var ip: String
    public var hostname: String
    public var dnsServer: String?
    public var gatewayOverride: String?
    public var pxeServer: String?
    public var pxeFilename: String?

    public init(
        id: UUID = UUID(),
        mac: String = "",
        ip: String = "",
        hostname: String = "",
        dnsServer: String? = nil,
        gatewayOverride: String? = nil,
        pxeServer: String? = nil,
        pxeFilename: String? = nil
    ) {
        self.id = id
        self.mac = mac
        self.ip = ip
        self.hostname = hostname
        self.dnsServer = dnsServer
        self.gatewayOverride = gatewayOverride
        self.pxeServer = pxeServer
        self.pxeFilename = pxeFilename
    }
}

public struct DHCPConfig: Codable, Equatable {
    public var enabled: Bool
    public var rangeStart: String
    public var rangeEnd: String
    public var staticLeases: [DHCPStaticLease]

    public init(
        enabled: Bool = true,
        rangeStart: String = "10.100.0.10",
        rangeEnd: String = "10.100.0.254",
        staticLeases: [DHCPStaticLease] = []
    ) {
        self.enabled = enabled
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.staticLeases = staticLeases
    }
}
