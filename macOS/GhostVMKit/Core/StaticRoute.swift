import Foundation

public struct StaticRoute: Codable, Identifiable, Equatable {
    public var id: UUID
    public var enabled: Bool
    public var destination: String
    public var gateway: String
    public var comment: String?

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        destination: String = "",
        gateway: String = "",
        comment: String? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.destination = destination
        self.gateway = gateway
        self.comment = comment
    }
}
