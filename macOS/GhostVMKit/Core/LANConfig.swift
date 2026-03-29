import Foundation

public struct LANConfig: Codable, Equatable {
    public var subnet: String
    public var gateway: String

    public init(
        subnet: String = "10.100.0.0/24",
        gateway: String = "10.100.0.1"
    ) {
        self.subnet = subnet
        self.gateway = gateway
    }
}
