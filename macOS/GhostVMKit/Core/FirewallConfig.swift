import Foundation

public enum FirewallDefaultPolicy: String, Codable, CaseIterable {
    case allow
    case block
}

public struct FirewallConfig: Codable, Equatable {
    public var defaultPolicy: FirewallDefaultPolicy
    public var rules: [NetworkRule]

    public init(
        defaultPolicy: FirewallDefaultPolicy = .allow,
        rules: [NetworkRule] = []
    ) {
        self.defaultPolicy = defaultPolicy
        self.rules = rules
    }
}
