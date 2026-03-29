import Foundation

public struct PortForwardRule: Codable, Identifiable, Equatable {
    public var id: UUID
    public var enabled: Bool
    public var proto: IPProtocol
    public var externalPort: UInt16
    public var internalIP: String
    public var internalPort: UInt16
    public var comment: String?

    public init(
        id: UUID = UUID(),
        enabled: Bool = true,
        proto: IPProtocol = .tcp,
        externalPort: UInt16 = 0,
        internalIP: String = "",
        internalPort: UInt16 = 0,
        comment: String? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.proto = proto
        self.externalPort = externalPort
        self.internalIP = internalIP
        self.internalPort = internalPort
        self.comment = comment
    }
}
