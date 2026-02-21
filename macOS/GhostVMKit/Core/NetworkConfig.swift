import Foundation

public enum NetworkMode: String, Codable {
    case nat = "nat"
    case bridged = "bridged"
}

public struct NetworkConfig: Codable, Equatable {
    public var mode: NetworkMode
    public var bridgeInterfaceIdentifier: String?

    public init(mode: NetworkMode = .nat, bridgeInterfaceIdentifier: String? = nil) {
        self.mode = mode
        self.bridgeInterfaceIdentifier = bridgeInterfaceIdentifier
    }

    public static var defaultConfig: NetworkConfig {
        NetworkConfig(mode: .nat, bridgeInterfaceIdentifier: nil)
    }
}
