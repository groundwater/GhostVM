import Foundation

public enum AliasType: String, Codable, CaseIterable {
    case hosts
    case networks
    case ports
}

public struct NetworkAlias: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var type: AliasType
    public var entries: [String]

    public init(
        id: UUID = UUID(),
        name: String = "",
        type: AliasType = .hosts,
        entries: [String] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.entries = entries
    }
}
