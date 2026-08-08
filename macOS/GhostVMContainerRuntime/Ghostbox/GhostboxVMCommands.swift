import Containerization
import Foundation
import GhostVMKit

struct GhostboxVMConfigurationCommands: GhostboxDomainHandler {
    let resource = "vmConfig"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "vmConfig.create" else { throw ghostboxUnsupported(method) }
        let decoded = try GhostboxParameters(
            parameters,
            allowed: ["vmConfig", "cpus", "memory", "interface", "mount", "bootLog", "nestedVirtualization"]
        )
        let interfaceReferences = try decoded.optionalReferences("interface", expectedKind: "interface") ?? []
        let interfaces: [any Interface] = try interfaceReferences.map {
            try session.value(for: $0, expectedKind: "interface", as: (any Interface).self)
        }
        let mountAssignments = try decoded.optionalStringArray("mount") ?? []
        var mountsByID: [String: [Containerization.Mount]] = [:]
        for assignment in mountAssignments {
            guard let separator = assignment.firstIndex(of: "="), separator != assignment.startIndex else {
                throw DirectDispatchError(.invalidArgument, "parameter 'mount' values must use workloadID=@mount/name")
            }
            let workloadID = String(assignment[..<separator])
            let rawReference = String(assignment[assignment.index(after: separator)...])
            let mountReference = try GhostboxReference.canonical(rawReference, expectedKind: "mount")
            let mount: Containerization.Mount = try session.value(for: mountReference, expectedKind: "mount")
            mountsByID[workloadID, default: []].append(mount)
        }
        let bootLogReference = try decoded.optionalReference("bootLog", expectedKind: "boot-log")
        let bootLog: BootLog? = try bootLogReference.map {
            try session.value(for: $0, expectedKind: "boot-log")
        }
        let record = GhostboxVMConfigurationRecord(
            value: VMConfiguration(
                cpus: try decoded.optionalInt("cpus") ?? 4,
                memoryInBytes: try decoded.optionalUInt64("memory") ?? 1_073_741_824,
                interfaces: interfaces,
                mountsByID: mountsByID,
                bootLog: bootLog,
                nestedVirtualization: try decoded.optionalBool("nestedVirtualization") ?? false
            ),
            interfaceReferences: interfaceReferences,
            mountAssignments: mountAssignments,
            bootLogReference: bootLogReference
        )
        let reference = try session.register(
            kind: "vm-config",
            name: decoded.requiredString("vmConfig"),
            value: record,
            equivalent: ghostboxVMConfigurationsEqual
        )
        return .reference(reference)
    }
}

struct GhostboxStandardVMConfigurationCommands: GhostboxDomainHandler {
    let resource = "standardVmConfig"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "standardVmConfig.create" else { throw ghostboxUnsupported(method) }
        let decoded = try GhostboxParameters(parameters, allowed: ["standardVmConfig", "vmConfig"])
        let configReference = try decoded.requiredReference("vmConfig", expectedKind: "vm-config")
        let config: GhostboxVMConfigurationRecord = try session.value(for: configReference, expectedKind: "vm-config")
        let record = GhostboxStandardVMConfigurationRecord(
            value: StandardVMConfig(configuration: config.value),
            configurationReference: configReference
        )
        let reference = try session.register(
            kind: "standard-vm-config",
            name: decoded.requiredString("standardVmConfig"),
            value: record,
            equivalent: { $0.configurationReference == $1.configurationReference }
        )
        return .reference(reference)
    }
}

struct GhostboxVMMCommands: GhostboxDomainHandler {
    let resource = "vmm"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "vmm.create":
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["vmm", "kernel", "initialFilesystem", "rosetta", "nestedVirtualization"]
            )
            let kernelReference = try decoded.requiredReference("kernel", expectedKind: "kernel")
            let kernel: Kernel = try session.value(for: kernelReference, expectedKind: "kernel")
            let filesystemReference = try decoded.requiredReference("initialFilesystem", expectedKind: "mount")
            let filesystem: Containerization.Mount = try session.value(for: filesystemReference, expectedKind: "mount")
            let rosetta = try decoded.optionalBool("rosetta") ?? false
            let nestedVirtualization = try decoded.optionalBool("nestedVirtualization") ?? false
            let record = GhostboxVMMRecord(
                value: VZVirtualMachineManager(
                    kernel: kernel,
                    initialFilesystem: filesystem,
                    rosetta: rosetta,
                    nestedVirtualization: nestedVirtualization
                ),
                kernelReference: kernelReference,
                initialFilesystemReference: filesystemReference,
                rosetta: rosetta,
                nestedVirtualization: nestedVirtualization
            )
            let reference = try session.register(
                kind: "vmm",
                name: decoded.requiredString("vmm"),
                value: record,
                equivalent: ghostboxVMMsEqual
            )
            return .reference(reference)

        case "vmm.createInstance":
            let decoded = try GhostboxParameters(parameters, allowed: ["vmm", "standardVmConfig"])
            let vmmReference = try decoded.requiredReference("vmm", expectedKind: "vmm")
            let vmm: GhostboxVMMRecord = try session.value(for: vmmReference, expectedKind: "vmm")
            let configReference = try decoded.requiredReference("standardVmConfig", expectedKind: "standard-vm-config")
            let config: GhostboxStandardVMConfigurationRecord = try session.value(
                for: configReference,
                expectedKind: "standard-vm-config"
            )
            let instance = try vmm.value.create(config: config.value)
            let record = GhostboxVMInstanceRecord(
                value: instance,
                vmmReference: vmmReference,
                configurationReference: configReference
            )
            let reference = try session.register(
                kind: "vm-instance",
                name: UUID().uuidString.lowercased(),
                value: record,
                equivalent: { $0.id == $1.id },
                cleanupPriority: 70,
                cleanup: { record in
                    switch record.value.state {
                    case .running, .starting, .stopping:
                        try? await record.value.stop()
                    case .unknown:
                        try? await record.value.resume()
                        try? await record.value.stop()
                    case .stopped:
                        break
                    }
                }
            )
            return .reference(reference)

        default:
            throw ghostboxUnsupported(method)
        }
    }
}

struct GhostboxVMInstanceCommands: GhostboxDomainHandler {
    let resource = "vmInstance"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        let allowed: Set<String> = method.rawValue == "vmInstance.dial" ? ["vmInstance", "port"] : ["vmInstance"]
        let decoded = try GhostboxParameters(parameters, allowed: allowed)
        let reference = try decoded.requiredReference("vmInstance", expectedKind: "vm-instance")
        let record: GhostboxVMInstanceRecord = try session.value(for: reference, expectedKind: "vm-instance")

        switch method.rawValue {
        case "vmInstance.state":
            return .string(ghostboxVMState(record.value.state))
        case "vmInstance.mounts":
            return .object(record.value.mounts.mapValues { .array($0.map(ghostboxAttachedFilesystemValue)) })
        case "vmInstance.virtiofsLayout":
            switch record.value.virtiofsLayout {
            case .unified: return .string("unified")
            case .perTag: return .string("per-tag")
            }
        case "vmInstance.start":
            try await record.value.start()
            return .void
        case "vmInstance.stop":
            try await record.value.stop()
            return .void
        case "vmInstance.pause":
            try await record.value.pause()
            return .void
        case "vmInstance.resume":
            try await record.value.resume()
            return .void
        case "vmInstance.dial":
            let handle = try await record.value.dial(decoded.requiredInteger("port", as: UInt32.self))
            let handleReference = try session.register(
                kind: "file-handle",
                name: UUID().uuidString.lowercased(),
                value: handle,
                equivalent: { $0 === $1 },
                cleanupPriority: 100,
                cleanup: { try? $0.close() }
            )
            return .reference(handleReference)
        default:
            throw ghostboxUnsupported(method)
        }
    }
}

enum GhostboxVMCommandHandlers {
    static let all: [any GhostboxDomainHandler] = [
        GhostboxVMConfigurationCommands(),
        GhostboxStandardVMConfigurationCommands(),
        GhostboxVMMCommands(),
        GhostboxVMInstanceCommands(),
    ]
}

struct GhostboxVMConfigurationRecord: Sendable {
    let value: VMConfiguration
    let interfaceReferences: [String]
    let mountAssignments: [String]
    let bootLogReference: String?
}

struct GhostboxStandardVMConfigurationRecord: Sendable {
    let value: StandardVMConfig
    let configurationReference: String
}

struct GhostboxVMMRecord: Sendable {
    let value: VZVirtualMachineManager
    let kernelReference: String
    let initialFilesystemReference: String
    let rosetta: Bool
    let nestedVirtualization: Bool
}

final class GhostboxVMInstanceRecord: Sendable {
    let id = UUID()
    let value: any VirtualMachineInstance
    let vmmReference: String
    let configurationReference: String

    init(value: any VirtualMachineInstance, vmmReference: String, configurationReference: String) {
        self.value = value
        self.vmmReference = vmmReference
        self.configurationReference = configurationReference
    }
}

private func ghostboxVMConfigurationsEqual(
    _ lhs: GhostboxVMConfigurationRecord,
    _ rhs: GhostboxVMConfigurationRecord
) -> Bool {
    lhs.value.cpus == rhs.value.cpus
        && lhs.value.memoryInBytes == rhs.value.memoryInBytes
        && lhs.interfaceReferences == rhs.interfaceReferences
        && lhs.mountAssignments == rhs.mountAssignments
        && lhs.bootLogReference == rhs.bootLogReference
        && lhs.value.nestedVirtualization == rhs.value.nestedVirtualization
}

private func ghostboxVMMsEqual(_ lhs: GhostboxVMMRecord, _ rhs: GhostboxVMMRecord) -> Bool {
    lhs.kernelReference == rhs.kernelReference
        && lhs.initialFilesystemReference == rhs.initialFilesystemReference
        && lhs.rosetta == rhs.rosetta
        && lhs.nestedVirtualization == rhs.nestedVirtualization
}

private func ghostboxVMState(_ state: VirtualMachineInstanceState) -> String {
    switch state {
    case .starting: return "starting"
    case .running: return "running"
    case .stopped: return "stopped"
    case .stopping: return "stopping"
    case .unknown: return "unknown"
    }
}

private func ghostboxAttachedFilesystemValue(_ filesystem: AttachedFilesystem) -> GhostboxDirectValue {
    .object([
        "type": .string(filesystem.type),
        "source": .string(filesystem.source),
        "destination": .string(filesystem.destination),
        "options": .strings(filesystem.options),
    ])
}
