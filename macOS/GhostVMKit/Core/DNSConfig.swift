import Foundation

public enum DNSMode: String, Codable, CaseIterable {
    case passthrough
    case custom
    case blocked
}

public struct DNSConfig: Codable, Equatable {
    public var mode: DNSMode
    public var servers: [String]

    public init(
        mode: DNSMode = .passthrough,
        servers: [String] = []
    ) {
        self.mode = mode
        self.servers = servers
    }
}
