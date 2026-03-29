import Foundation

/// Describes a single network interface (NIC) attached to a VM.
/// Each interface pairs a `NetworkConfig` (mode, bridge ID, custom network) with its own MAC address and label.
public struct NetworkInterfaceConfig: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var label: String
    public var networkConfig: NetworkConfig
    /// Empty string means "auto-generate before first use".
    public var macAddress: String

    public init(
        id: UUID = UUID(),
        label: String = "Network",
        networkConfig: NetworkConfig = .defaultConfig,
        macAddress: String = ""
    ) {
        self.id = id
        self.label = label
        self.networkConfig = networkConfig
        self.macAddress = macAddress
    }
}
