import Foundation

/// Identifies a network independently of the backend that implements it.
public struct ManagedNetworkID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Host networking implementations available to VM and container workloads.
public enum ManagedNetworkDriver: String, Codable, Sendable {
    /// Virtualization.framework's per-VM NAT attachment.
    case virtualizationNAT = "virtualization-nat"
    /// A direct attachment to a host interface.
    case bridged
    /// A shared vmnet network with centrally managed addresses.
    case vmnetShared = "vmnet-shared"
}

/// Backend-neutral network configuration owned by the runtime helper.
public struct ManagedNetwork: Codable, Equatable, Sendable {
    public var id: ManagedNetworkID
    public var name: String
    public var driver: ManagedNetworkDriver
    public var ipv4Subnet: String?
    public var gateway: String?
    public var bridgeInterfaceIdentifier: String?

    public init(
        id: ManagedNetworkID,
        name: String,
        driver: ManagedNetworkDriver,
        ipv4Subnet: String? = nil,
        gateway: String? = nil,
        bridgeInterfaceIdentifier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.driver = driver
        self.ipv4Subnet = ipv4Subnet
        self.gateway = gateway
        self.bridgeInterfaceIdentifier = bridgeInterfaceIdentifier
    }
}

public enum NetworkWorkloadKind: String, Codable, Hashable, Sendable {
    case virtualMachine = "virtual-machine"
    case container
}

/// A VM NIC or container interface attached to a managed network.
public struct ManagedNetworkEndpoint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var networkID: ManagedNetworkID
    public var workloadKind: NetworkWorkloadKind
    public var workloadID: String
    public var interfaceName: String?
    public var macAddress: String?
    public var ipv4Address: String?

    public init(
        id: UUID = UUID(),
        networkID: ManagedNetworkID,
        workloadKind: NetworkWorkloadKind,
        workloadID: String,
        interfaceName: String? = nil,
        macAddress: String? = nil,
        ipv4Address: String? = nil
    ) {
        self.id = id
        self.networkID = networkID
        self.workloadKind = workloadKind
        self.workloadID = workloadID
        self.interfaceName = interfaceName
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
    }
}

public enum NetworkManagerError: Error, Equatable {
    case networkAlreadyExists(ManagedNetworkID)
    case networkNotFound(ManagedNetworkID)
    case endpointAlreadyExists(UUID)
}

/// Single-owner control plane for VM and container network definitions.
/// Concrete backends translate endpoints into VZ or Containerization interfaces.
public actor NetworkManager {
    private var networksByID: [ManagedNetworkID: ManagedNetwork]
    private var endpointsByID: [UUID: ManagedNetworkEndpoint]

    public init(networks: [ManagedNetwork] = []) {
        self.networksByID = Dictionary(uniqueKeysWithValues: networks.map { ($0.id, $0) })
        self.endpointsByID = [:]
    }

    public func networks() -> [ManagedNetwork] {
        networksByID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func network(id: ManagedNetworkID) -> ManagedNetwork? {
        networksByID[id]
    }

    public func create(_ network: ManagedNetwork) throws {
        guard networksByID[network.id] == nil else {
            throw NetworkManagerError.networkAlreadyExists(network.id)
        }
        networksByID[network.id] = network
    }

    public func remove(id: ManagedNetworkID) throws {
        guard networksByID.removeValue(forKey: id) != nil else {
            throw NetworkManagerError.networkNotFound(id)
        }
        endpointsByID = endpointsByID.filter { $0.value.networkID != id }
    }

    public func attach(_ endpoint: ManagedNetworkEndpoint) throws {
        guard networksByID[endpoint.networkID] != nil else {
            throw NetworkManagerError.networkNotFound(endpoint.networkID)
        }
        guard endpointsByID[endpoint.id] == nil else {
            throw NetworkManagerError.endpointAlreadyExists(endpoint.id)
        }
        endpointsByID[endpoint.id] = endpoint
    }

    public func detach(endpointID: UUID) {
        endpointsByID.removeValue(forKey: endpointID)
    }

    public func endpoints(networkID: ManagedNetworkID? = nil) -> [ManagedNetworkEndpoint] {
        endpointsByID.values
            .filter { networkID == nil || $0.networkID == networkID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
