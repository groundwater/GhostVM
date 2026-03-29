import Foundation

public enum NetworkMode: String, Codable {
    case nat = "nat"
    case bridged = "bridged"
    case custom = "custom"
}

public struct NetworkConfig: Codable, Equatable, Hashable {
    public var mode: NetworkMode
    public var bridgeInterfaceIdentifier: String?
    public var customNetworkID: UUID?

    public init(mode: NetworkMode = .nat, bridgeInterfaceIdentifier: String? = nil, customNetworkID: UUID? = nil) {
        self.mode = mode
        self.bridgeInterfaceIdentifier = bridgeInterfaceIdentifier
        self.customNetworkID = customNetworkID
    }

    public static var defaultConfig: NetworkConfig {
        NetworkConfig(mode: .nat, bridgeInterfaceIdentifier: nil, customNetworkID: nil)
    }
}
