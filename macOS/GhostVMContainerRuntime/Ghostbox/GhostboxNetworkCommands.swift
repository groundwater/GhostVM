import Containerization
import ContainerizationExtras
import Foundation
import GhostVMKit
import Virtualization
import vmnet

struct GhostboxNetworkCommands: GhostboxDomainHandler {
    let resource = "network"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "network.vmnetCreate":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["network", "mode", "subnet", "prefixV6"]
            )
            let name = try decoded.requiredString("network")
            let mode = try ghostboxNetworkMode(decoded.optionalString("mode") ?? "shared")
            let subnet = try decoded.optionalString("subnet").map {
                try ghostboxCIDRv4($0, parameter: "subnet")
            }
            let prefixV6 = try decoded.optionalString("prefixV6").map {
                try ghostboxCIDRv6($0, parameter: "prefixV6")
            }
            let network: GhostboxNetwork
            if let shared: GhostboxNetwork = session.contextValue(ghostboxSharedNetworkContextKey) {
                guard mode == .VMNET_SHARED_MODE else {
                    throw DirectDispatchError(.invalidArgument, "the GhostVM network only supports shared mode")
                }
                guard subnet == nil || subnet == shared.subnet else {
                    throw DirectDispatchError(.invalidArgument, "the requested subnet does not match the GhostVM network")
                }
                guard prefixV6 == nil else {
                    throw DirectDispatchError(.unsupported, "the GhostVM shared network does not provide IPv6")
                }
                network = shared
            } else {
                network = try GhostboxNetwork(mode: mode, subnet: subnet, prefixV6: prefixV6)
            }
            let reference = try session.registerNew(
                kind: "network",
                name: name,
                makeValue: {
                    GhostboxMutableSlot(GhostboxNetworkRecord(
                        value: network
                    ))
                },
                equivalent: {
                    let lhs = $0.get()
                    let rhs = $1.get()
                    return lhs.retired == rhs.retired && ghostboxNetworksEqual(lhs.value, rhs.value)
                }
            )
            return .reference(reference)

        case GhostboxDirectMethod.networkDelete.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["network"])
            let reference = try decoded.requiredReference("network", expectedKind: "network")
            let slot: GhostboxMutableSlot<GhostboxNetworkRecord> = try session.mutableValue(
                for: reference,
                expectedKind: "network"
            )
            try slot.update { record in
                guard !record.retired else {
                    throw DirectDispatchError(.failedPrecondition, "network '\(reference)' is closing")
                }
                guard record.allocationIDs.isEmpty else {
                    throw DirectDispatchError(
                        .failedPrecondition,
                        "network '\(reference)' still has allocated interfaces"
                    )
                }
                record.retired = true
            }
            try session.unregister(reference, expectedKind: "network", matching: slot)
            return .void

        case "network.subnet", "network.prefixV6", "network.ipv4Gateway", "network.ipv6Gateway":
            let decoded = try GhostboxParameters(parameters, allowed: ["network"])
            let reference = try decoded.requiredReference("network", expectedKind: "network")
            let network = try ghostboxNetwork(reference, session: session)
            switch method.rawValue {
            case "network.subnet":
                return .string(network.subnet.description)
            case "network.prefixV6":
                return network.prefixV6.map { .string($0.description) } ?? .null
            case "network.ipv4Gateway":
                return .string(network.ipv4Gateway.description)
            default:
                return network.ipv6Gateway.map { .string($0.description) } ?? .null
            }

        case "network.createInterface", "network.createInterfaceMtu", "network.createInterfaceWithoutGateway":
            let allowed: Set<String> = method.rawValue == "network.createInterfaceMtu"
                ? ["network", "interface", "mtu"]
                : ["network", "interface"]
            let decoded = try GhostboxParameters(parameters, allowed: allowed)
            let networkReference = try decoded.requiredReference("network", expectedKind: "network")
            let name = try decoded.requiredString("interface")
            _ = try GhostboxReference.canonical(kind: "interface", name: name)
            let slot: GhostboxMutableSlot<GhostboxNetworkRecord> = try session.mutableValue(
                for: networkReference,
                expectedKind: "network"
            )
            var interface: (any Interface)?
            try slot.update { record in
                guard !record.retired else {
                    throw DirectDispatchError(.failedPrecondition, "network '\(networkReference)' is closing")
                }
                switch method.rawValue {
                case "network.createInterface":
                    interface = try record.value.createInterface(name)
                case "network.createInterfaceMtu":
                    interface = try record.value.createInterface(
                        name,
                        mtu: decoded.requiredInteger("mtu", as: UInt32.self)
                    )
                default:
                    interface = try record.value.createInterfaceWithoutGateway(name)
                }
                if interface != nil { record.allocationIDs.insert(name) }
            }
            guard let interface else { return .null }

            let record = GhostboxInterfaceRecord(
                value: interface,
                provenance: .init(networkReference: networkReference, allocationID: name)
            )
            do {
                let reference = try session.register(
                    kind: "interface",
                    name: name,
                    value: record,
                    equivalent: ghostboxInterfaceRecordsEqual
                )
                return .reference(reference)
            } catch {
                try? slot.update {
                    try $0.value.releaseInterface(name)
                    $0.allocationIDs.remove(name)
                }
                throw error
            }

        case "network.releaseInterface":
            let decoded = try GhostboxParameters(parameters, allowed: ["network", "interface"])
            let networkReference = try decoded.requiredReference("network", expectedKind: "network")
            let interfaceReference = try decoded.requiredReference("interface", expectedKind: "interface")
            let record = try ghostboxInterfaceRecord(interfaceReference, session: session)
            guard let provenance = record.provenance else {
                throw DirectDispatchError(
                    .invalidArgument,
                    "interface '\(interfaceReference)' was not allocated by a network"
                )
            }
            guard provenance.networkReference == networkReference else {
                throw DirectDispatchError(
                    .invalidArgument,
                    "interface '\(interfaceReference)' does not belong to network '\(networkReference)'"
                )
            }
            let slot: GhostboxMutableSlot<GhostboxNetworkRecord> = try session.mutableValue(
                for: networkReference,
                expectedKind: "network"
            )
            try slot.update {
                guard !$0.retired else {
                    throw DirectDispatchError(.failedPrecondition, "network '\(networkReference)' is closing")
                }
                try $0.value.releaseInterface(provenance.allocationID)
                $0.allocationIDs.remove(provenance.allocationID)
            }
            try session.unregister(interfaceReference, expectedKind: "interface", matching: record)
            return .void

        default:
            throw ghostboxUnsupported(method)
        }
    }
}

struct GhostboxNetworkRecord: Sendable {
    var value: GhostboxNetwork
    var allocationIDs: Set<String> = []
    var retired = false
}

func ghostboxNetwork(_ reference: String, session: GhostboxSession) throws -> GhostboxNetwork {
    let record: GhostboxNetworkRecord = try session.valueSnapshot(
        for: reference,
        expectedKind: "network"
    )
    guard !record.retired else {
        throw DirectDispatchError(.failedPrecondition, "network '\(reference)' is closing")
    }
    return record.value
}

struct GhostboxInterfaceCommands: GhostboxDomainHandler {
    let resource = "interface"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "interface.natCreate":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: [
                    "interface", "ipv4Address", "ipv4Gateway", "ipv6Address",
                    "ipv6Gateway", "macAddress", "mtu",
                ]
            )
            let interface = NATInterface(
                ipv4Address: try ghostboxCIDRv4(
                    decoded.requiredString("ipv4Address"),
                    parameter: "ipv4Address"
                ),
                ipv4Gateway: try decoded.optionalString("ipv4Gateway").map {
                    try ghostboxIPv4Address($0, parameter: "ipv4Gateway")
                },
                ipv6Address: try decoded.optionalString("ipv6Address").map {
                    try ghostboxCIDRv6($0, parameter: "ipv6Address")
                },
                ipv6Gateway: try decoded.optionalString("ipv6Gateway").map {
                    try ghostboxIPv6Address($0, parameter: "ipv6Gateway")
                },
                macAddress: try decoded.optionalString("macAddress").map {
                    try ghostboxMACAddress($0, parameter: "macAddress")
                },
                mtu: try decoded.optionalInteger("mtu", as: UInt32.self) ?? 1500
            )
            let record = GhostboxInterfaceRecord(value: interface, provenance: nil)
            let reference = try session.register(
                kind: "interface",
                name: decoded.requiredString("interface"),
                value: record,
                equivalent: ghostboxInterfaceRecordsEqual
            )
            return .reference(reference)

        case "interface.ipv4Address", "interface.ipv4Gateway", "interface.ipv6Address",
             "interface.ipv6Gateway", "interface.macAddress", "interface.mtu":
            let decoded = try GhostboxParameters(parameters, allowed: ["interface"])
            let reference = try decoded.requiredReference("interface", expectedKind: "interface")
            let interface = try ghostboxInterface(reference, session: session)
            switch method.rawValue {
            case "interface.ipv4Address":
                return .string(interface.ipv4Address.description)
            case "interface.ipv4Gateway":
                return interface.ipv4Gateway.map { .string($0.description) } ?? .null
            case "interface.ipv6Address":
                return interface.ipv6Address.map { .string($0.description) } ?? .null
            case "interface.ipv6Gateway":
                return interface.ipv6Gateway.map { .string($0.description) } ?? .null
            case "interface.macAddress":
                return interface.macAddress.map { .string($0.description) } ?? .null
            default:
                return .unsignedInteger(UInt64(interface.mtu))
            }

        default:
            throw ghostboxUnsupported(method)
        }
    }
}

struct GhostboxInterfaceProvenance: Sendable, Equatable {
    let networkReference: String
    let allocationID: String
}

struct GhostboxInterfaceRecord: Interface, VZInterface, Sendable {
    let value: any Interface
    let provenance: GhostboxInterfaceProvenance?

    var ipv4Address: CIDRv4 { value.ipv4Address }
    var ipv4Gateway: IPv4Address? { value.ipv4Gateway }
    var ipv6Address: CIDRv6? { value.ipv6Address }
    var ipv6Gateway: IPv6Address? { value.ipv6Gateway }
    var macAddress: MACAddress? { value.macAddress }
    var mtu: UInt32 { value.mtu }

    func device() throws -> VZVirtioNetworkDeviceConfiguration {
        guard let value = value as? any VZInterface else {
            throw DirectDispatchError(.invalidArgument, "interface type is not supported by Virtualization")
        }
        return try value.device()
    }
}

func ghostboxInterface(
    _ reference: String,
    session: GhostboxSession
) throws -> any Interface {
    try ghostboxInterfaceRecord(reference, session: session).value
}

func ghostboxInterfaceRecord(
    _ reference: String,
    session: GhostboxSession
) throws -> GhostboxInterfaceRecord {
    try session.value(for: reference, expectedKind: "interface")
}

private func ghostboxNetworkMode(_ value: String) throws -> vmnet.operating_modes_t {
    switch value {
    case "shared": return .VMNET_SHARED_MODE
    case "host": return .VMNET_HOST_MODE
    case "bridged": return .VMNET_BRIDGED_MODE
    default:
        throw DirectDispatchError(.invalidArgument, "unknown network mode '\(value)'")
    }
}

private func ghostboxCIDRv4(_ value: String, parameter: String) throws -> CIDRv4 {
    try ghostboxCIDR(value, parameter: parameter, parse: CIDRv4.init)
}

private func ghostboxCIDRv6(_ value: String, parameter: String) throws -> CIDRv6 {
    try ghostboxCIDR(value, parameter: parameter, parse: CIDRv6.init)
}

private func ghostboxCIDR<Value>(
    _ value: String,
    parameter: String,
    parse: (String) throws -> Value
) throws -> Value {
    guard value.split(separator: "/", omittingEmptySubsequences: false).count == 2 else {
        throw DirectDispatchError(.invalidArgument, "parameter '\(parameter)' is not a valid CIDR value")
    }
    return try ghostboxParsed(value, parameter: parameter, parse: parse)
}

private func ghostboxIPv4Address(_ value: String, parameter: String) throws -> IPv4Address {
    try ghostboxParsed(value, parameter: parameter, parse: IPv4Address.init)
}

private func ghostboxIPv6Address(_ value: String, parameter: String) throws -> IPv6Address {
    try ghostboxParsed(value, parameter: parameter, parse: IPv6Address.init)
}

private func ghostboxMACAddress(_ value: String, parameter: String) throws -> MACAddress {
    try ghostboxParsed(value, parameter: parameter, parse: MACAddress.init)
}

private func ghostboxParsed<Value>(
    _ value: String,
    parameter: String,
    parse: (String) throws -> Value
) throws -> Value {
    do {
        return try parse(value)
    } catch {
        throw DirectDispatchError(
            .invalidArgument,
            "parameter '\(parameter)' is malformed: \(error.localizedDescription)"
        )
    }
}

private func ghostboxNetworksEqual(_ lhs: GhostboxNetwork, _ rhs: GhostboxNetwork) -> Bool {
    lhs.subnet == rhs.subnet && lhs.prefixV6 == rhs.prefixV6
}

func ghostboxInterfaceRecordsEqual(
    _ lhs: GhostboxInterfaceRecord,
    _ rhs: GhostboxInterfaceRecord
) -> Bool {
    lhs.ipv4Address == rhs.ipv4Address
        && lhs.ipv4Gateway == rhs.ipv4Gateway
        && lhs.ipv6Address == rhs.ipv6Address
        && lhs.ipv6Gateway == rhs.ipv6Gateway
        && lhs.macAddress == rhs.macAddress
        && lhs.mtu == rhs.mtu
        && lhs.provenance == rhs.provenance
}
