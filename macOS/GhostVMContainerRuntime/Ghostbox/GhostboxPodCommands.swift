import Containerization
import ContainerizationOS
import Foundation
import GhostVMKit

struct GhostboxPodVolumeCommands: GhostboxDomainHandler {
    let resource = "podVolume"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        guard method.rawValue == "podVolume.create" else { throw ghostboxUnsupported(method) }
        let decoded = try GhostboxParameters(parameters, allowed: ["podVolume", "name", "source", "format"])
        let source = try ghostboxPodVolumeSource(decoded.requiredObject("source"))
        let volume = LinuxPod.PodVolume(
            name: try decoded.requiredString("name"),
            source: source,
            format: try decoded.requiredString("format")
        )
        let reference = try session.register(
            kind: "pod-volume", name: decoded.requiredString("podVolume"), value: volume,
            equivalent: { $0.name == $1.name && $0.format == $1.format }
        )
        return .reference(reference)
    }
}

struct GhostboxPodConfigurationCommands: GhostboxDomainHandler {
    let resource = "podConfig"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        if method.rawValue == "podConfig.create" {
            let decoded = try GhostboxParameters(parameters, allowed: ["podConfig"])
            let reference = try session.registerMutable(
                kind: "pod-config", name: decoded.requiredString("podConfig"),
                value: LinuxPod.Configuration(), equivalent: ghostboxPodConfigurationsEqual
            )
            return .reference(reference)
        }
        let valueName = ghostboxPodConfigValueName(method.rawValue)
        let decoded = try GhostboxParameters(parameters, allowed: ["podConfig", valueName])
        let reference = try decoded.requiredReference("podConfig", expectedKind: "pod-config")
        switch method.rawValue {
        case "podConfig.setCPUs":
            let value = try decoded.requiredInt("cpus")
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.cpus = value }
        case "podConfig.setMemory":
            let value = try decoded.requiredUInt64("bytes")
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.memoryInBytes = value }
        case "podConfig.setInterfaces":
            let references = try decoded.requiredReferences("interface", expectedKind: "interface")
            let values: [any Interface] = try references.map {
                try session.value(for: $0, expectedKind: "interface", as: (any Interface).self)
            }
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.interfaces = values }
        case "podConfig.setVirtualization":
            let value = try decoded.requiredBool("enabled")
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.virtualization = value }
        case "podConfig.setBootLog":
            let objectReference = try decoded.requiredNullableReference("bootLog", expectedKind: "boot-log")
            let value: BootLog? = try objectReference.map { try session.value(for: $0, expectedKind: "boot-log") }
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.bootLog = value }
        case "podConfig.setShareProcessNamespace":
            let value = try decoded.requiredBool("enabled")
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.shareProcessNamespace = value }
        case "podConfig.setHostname":
            let value = try decoded.requiredNullableString("hostname")
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.hostname = value }
        case "podConfig.setDNS":
            let objectReference = try decoded.requiredNullableReference("dns", expectedKind: "dns")
            let value: DNS? = try objectReference.map { try session.value(for: $0, expectedKind: "dns") }
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.dns = value }
        case "podConfig.setHosts":
            let objectReference = try decoded.requiredNullableReference("hosts", expectedKind: "hosts")
            let value: Hosts? = try objectReference.map {
                let record: GhostboxHostsRecord = try session.value(for: $0, expectedKind: "hosts")
                return record.value
            }
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.hosts = value }
        case "podConfig.setVolumes":
            let references = try decoded.requiredReferences("podVolume", expectedKind: "pod-volume")
            let values: [LinuxPod.PodVolume] = try references.map { try session.value(for: $0, expectedKind: "pod-volume") }
            try session.updateValue(for: reference, expectedKind: "pod-config", as: LinuxPod.Configuration.self) { $0.volumes = values }
        default: throw ghostboxUnsupported(method)
        }
        return .void
    }
}

struct GhostboxPodContainerConfigurationCommands: GhostboxDomainHandler {
    let resource = "podContainerConfig"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        if method.rawValue == "podContainerConfig.create" {
            let decoded = try GhostboxParameters(parameters, allowed: ["podContainerConfig"])
            let reference = try session.registerMutable(
                kind: "pod-container-config", name: decoded.requiredString("podContainerConfig"),
                value: LinuxPod.ContainerConfiguration(), equivalent: ghostboxPodContainerConfigurationsEqual
            )
            return .reference(reference)
        }
        let valueName = ghostboxPodContainerConfigValueName(method.rawValue)
        let decoded = try GhostboxParameters(parameters, allowed: ["podContainerConfig", valueName])
        let reference = try decoded.requiredReference("podContainerConfig", expectedKind: "pod-container-config")
        switch method.rawValue {
        case "podContainerConfig.setProcess":
            let processReference = try decoded.requiredReference("processConfig", expectedKind: "process-config")
            let value = try ghostboxProcessConfiguration(processReference, session: session)
            try update(reference, session: session) { $0.process = value }
        case "podContainerConfig.setCPUs":
            let value: Int? = try decoded.requiredNullableInteger("cpus")
            try update(reference, session: session) { $0.cpus = value }
        case "podContainerConfig.setMemory":
            let value: UInt64? = try decoded.requiredNullableInteger("bytes")
            try update(reference, session: session) { $0.memoryInBytes = value }
        case "podContainerConfig.setHostname":
            let value = try decoded.requiredNullableString("hostname")
            try update(reference, session: session) { $0.hostname = value }
        case "podContainerConfig.setSysctl":
            let value = try ghostboxPodAssignments(decoded.requiredStringArray("keyValue"))
            try update(reference, session: session) { $0.sysctl = value }
        case "podContainerConfig.setMounts":
            let references = try decoded.requiredReferences("mount", expectedKind: "mount")
            let value: [Containerization.Mount] = try references.map { try session.value(for: $0, expectedKind: "mount") }
            try update(reference, session: session) { $0.mounts = value }
        case "podContainerConfig.setMaskedPaths":
            let value = try decoded.requiredStringArray("path")
            try update(reference, session: session) { $0.maskedPaths = value }
        case "podContainerConfig.setReadonlyPaths":
            let value = try decoded.requiredStringArray("path")
            try update(reference, session: session) { $0.readonlyPaths = value }
        case "podContainerConfig.setSockets":
            let references = try decoded.requiredReferences("socket", expectedKind: "socket")
            let value: [UnixSocketConfiguration] = try references.map { try session.value(for: $0, expectedKind: "socket") }
            try update(reference, session: session) { $0.sockets = value }
        case "podContainerConfig.setDNS":
            let objectReference = try decoded.requiredNullableReference("dns", expectedKind: "dns")
            let value: DNS? = try objectReference.map { try session.value(for: $0, expectedKind: "dns") }
            try update(reference, session: session) { $0.dns = value }
        case "podContainerConfig.setHosts":
            let objectReference = try decoded.requiredNullableReference("hosts", expectedKind: "hosts")
            let value: Hosts? = try objectReference.map {
                let record: GhostboxHostsRecord = try session.value(for: $0, expectedKind: "hosts")
                return record.value
            }
            try update(reference, session: session) { $0.hosts = value }
        case "podContainerConfig.setUseInit":
            let value = try decoded.requiredBool("enabled")
            try update(reference, session: session) { $0.useInit = value }
        default: throw ghostboxUnsupported(method)
        }
        return .void
    }

    private func update(
        _ reference: String,
        session: GhostboxSession,
        _ body: (inout LinuxPod.ContainerConfiguration) throws -> Void
    ) throws {
        try session.updateValue(for: reference, expectedKind: "pod-container-config", body)
    }
}

struct GhostboxPodCommands: GhostboxDomainHandler {
    let resource = "pod"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        if method.rawValue == "pod.createDirect" {
            return try create(parameters: parameters, session: session)
        }
        let decoded = try GhostboxParameters(parameters, allowed: ghostboxPodAllowedParameters(method.rawValue))
        let podReference = try decoded.requiredReference("pod", expectedKind: "pod")
        let record: GhostboxPodRecord = try session.value(for: podReference, expectedKind: "pod")
        let pod = record.value
        switch method.rawValue {
        case "pod.id": return .string(pod.id)
        case "pod.config": return .reference(record.configurationReference)
        case "pod.cpus": return .integer(Int64(pod.cpus))
        case "pod.memory": return .unsignedInteger(pod.memoryInBytes)
        case "pod.interfaces":
            let references = try pod.interfaces.enumerated().map { index, interface in
                try session.register(
                    kind: "interface", name: "\(ghostboxReferenceName(podReference))-\(index)",
                    value: GhostboxInterfaceRecord(value: interface, provenance: nil),
                    equivalent: ghostboxInterfaceRecordsEqual
                )
            }
            return .references(references)
        case "pod.addContainer":
            let containerID = try decoded.requiredString("container")
            let rootfsReference = try decoded.requiredReference("rootfs", expectedKind: "mount")
            let rootfs: Containerization.Mount = try session.value(for: rootfsReference, expectedKind: "mount")
            let configReference = try decoded.requiredReference("configuration", expectedKind: "pod-container-config")
            let config: LinuxPod.ContainerConfiguration = try session.valueSnapshot(
                for: configReference, expectedKind: "pod-container-config"
            )
            try await pod.addContainer(containerID, rootfs: rootfs) { $0 = config }
            return .reference(try ghostboxPodContainerReference(podReference: podReference, containerID: containerID, session: session))
        case "pod.create": try await pod.create(); return .void
        case "pod.startContainer": try await pod.startContainer(try containerID(decoded, podReference: podReference, session: session)); return .void
        case "pod.stopContainer": try await pod.stopContainer(try containerID(decoded, podReference: podReference, session: session)); return .void
        case "pod.stop": try await pod.stop(); return .void
        case "pod.killContainer":
            try await pod.killContainer(
                try containerID(decoded, podReference: podReference, session: session),
                signal: Signal(decoded.requiredString("signal"))
            )
            return .void
        case "pod.waitContainer":
            return ghostboxExitStatusValue(try await pod.waitContainer(
                try containerID(decoded, podReference: podReference, session: session),
                timeoutInSeconds: decoded.optionalInt64("timeoutSeconds")
            ))
        case "pod.resizeContainer":
            try await pod.resizeContainer(
                try containerID(decoded, podReference: podReference, session: session),
                to: Terminal.Size(
                    width: decoded.requiredInteger("width", as: UInt16.self),
                    height: decoded.requiredInteger("height", as: UInt16.self)
                )
            )
            return .void
        case "pod.execInContainer":
            let id = try containerID(decoded, podReference: podReference, session: session)
            let processID = try decoded.requiredString("process")
            let configReference = try decoded.requiredReference("configuration", expectedKind: "process-config")
            let config = try ghostboxProcessConfiguration(configReference, session: session)
            let process = try await pod.execInContainer(id, processID: processID) { $0 = config }
            return .reference(try ghostboxRegisterProcess(
                process, name: "\(ghostboxReferenceName(podReference))-\(id)-\(processID)", session: session
            ))
        case "pod.listContainers":
            let ids = await pod.listContainers()
            return .references(try ids.map {
                try ghostboxPodContainerReference(podReference: podReference, containerID: $0, session: session)
            })
        case "pod.statistics":
            let containerReferences = try decoded.optionalReferences("container", expectedKind: "pod-container")
            let ids = try containerReferences?.map {
                let handle: GhostboxPodContainerHandle = try session.value(for: $0, expectedKind: "pod-container")
                guard handle.podReference == podReference else {
                    throw DirectDispatchError(.invalidArgument, "pod container belongs to another pod")
                }
                return handle.containerID
            }
            let values = try await pod.statistics(
                containerIDs: ids,
                categories: try ghostboxStatCategories(decoded.optionalStringArray("category"))
            )
            return .array(values.map(ghostboxStatisticsValue))
        case "pod.dialVsock":
            return .reference(try ghostboxRegisterFileHandle(
                await pod.dialVsock(port: decoded.requiredInteger("port", as: UInt32.self)), session: session
            ))
        case "pod.filesystemOperation":
            try await pod.filesystemOperation(
                try containerID(decoded, podReference: podReference, session: session),
                operation: try ghostboxFilesystemOperation(decoded.requiredString("operation")),
                path: decoded.requiredString("path")
            )
            return .void
        case "pod.closeContainerStdin":
            try await pod.closeContainerStdin(try containerID(decoded, podReference: podReference, session: session))
            return .void
        case "pod.relayUnixSocket":
            let socketReference = try decoded.requiredReference("socket", expectedKind: "socket")
            let socket: UnixSocketConfiguration = try session.value(for: socketReference, expectedKind: "socket")
            try await pod.relayUnixSocket(
                try containerID(decoded, podReference: podReference, session: session), socket: socket
            )
            return .void
        default: throw ghostboxUnsupported(method)
        }
    }

    private func create(
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) throws -> GhostboxDirectValue {
        let decoded = try GhostboxParameters(parameters, allowed: ["pod", "vmm", "configuration"])
        let name = try decoded.requiredString("pod")
        let vmmReference = try decoded.requiredReference("vmm", expectedKind: "vmm")
        let vmm: GhostboxVMMRecord = try session.value(for: vmmReference, expectedKind: "vmm")
        let sourceConfigReference = try decoded.requiredReference("configuration", expectedKind: "pod-config")
        let config: LinuxPod.Configuration = try session.valueSnapshot(for: sourceConfigReference, expectedKind: "pod-config")
        let snapshotReference = try session.register(
            kind: "pod-config", name: "\(name)-snapshot", value: config,
            equivalent: ghostboxPodConfigurationsEqual
        )
        let pod = try LinuxPod(name, vmm: vmm.value) { $0 = config }
        let reference = try session.register(
            kind: "pod", name: name,
            value: GhostboxPodRecord(value: pod, configurationReference: snapshotReference),
            equivalent: { $0.value === $1.value },
            cleanupPriority: 80,
            cleanup: { try? await $0.value.stop() }
        )
        return .reference(reference)
    }

    private func containerID(
        _ decoded: GhostboxParameters,
        podReference: String,
        session: GhostboxSession
    ) throws -> String {
        let reference = try decoded.requiredReference("podContainer", expectedKind: "pod-container")
        let handle: GhostboxPodContainerHandle = try session.value(for: reference, expectedKind: "pod-container")
        guard handle.podReference == podReference else {
            throw DirectDispatchError(.invalidArgument, "pod container belongs to another pod")
        }
        return handle.containerID
    }
}

enum GhostboxPodCommandHandlers {
    static let all: [any GhostboxDomainHandler] = [
        GhostboxPodVolumeCommands(),
        GhostboxPodConfigurationCommands(),
        GhostboxPodContainerConfigurationCommands(),
        GhostboxPodCommands(),
    ]
}

struct GhostboxPodRecord: Sendable {
    let value: LinuxPod
    let configurationReference: String
}

struct GhostboxPodContainerHandle: Sendable, Equatable {
    let podReference: String
    let containerID: String
}

private func ghostboxPodContainerReference(
    podReference: String,
    containerID: String,
    session: GhostboxSession
) throws -> String {
    let handle = GhostboxPodContainerHandle(podReference: podReference, containerID: containerID)
    return try session.register(
        kind: "pod-container",
        name: "\(ghostboxReferenceName(podReference)).\(containerID)",
        value: handle,
        equivalent: ==
    )
}

private func ghostboxPodVolumeSource(
    _ object: [String: GhostboxJSONValue]
) throws -> LinuxPod.PodVolume.Source {
    guard case .string(let type)? = object["type"] else {
        throw DirectDispatchError(.invalidArgument, "pod volume source requires a string 'type'")
    }
    switch type {
    case "nbd":
        guard case .string(let rawURL)? = object["url"], let url = URL(string: rawURL), url.scheme != nil else {
            throw DirectDispatchError(.invalidArgument, "nbd pod volume source requires an absolute 'url'")
        }
        let timeout = try ghostboxPodDouble(object["timeout"], name: "timeout")
        let readOnly = try ghostboxPodBool(object["readOnly"], name: "readOnly") ?? false
        return .nbd(url: url, timeout: timeout, readOnly: readOnly)
    case "disk-image":
        guard case .string(let path)? = object["path"] else {
            throw DirectDispatchError(.invalidArgument, "disk-image pod volume source requires 'path'")
        }
        return .diskImage(
            path: ghostboxHostURL(path),
            readOnly: try ghostboxPodBool(object["readOnly"], name: "readOnly") ?? false
        )
    case "tmpfs":
        return .tmpfs(sizeBytes: try ghostboxPodUInt64(object["sizeBytes"], name: "sizeBytes"))
    default:
        throw DirectDispatchError(.invalidArgument, "unknown pod volume source type '\(type)'")
    }
}

private func ghostboxPodConfigValueName(_ method: String) -> String {
    switch method {
    case "podConfig.setCPUs": return "cpus"
    case "podConfig.setMemory": return "bytes"
    case "podConfig.setInterfaces": return "interface"
    case "podConfig.setVirtualization", "podConfig.setShareProcessNamespace": return "enabled"
    case "podConfig.setBootLog": return "bootLog"
    case "podConfig.setHostname": return "hostname"
    case "podConfig.setDNS": return "dns"
    case "podConfig.setHosts": return "hosts"
    case "podConfig.setVolumes": return "podVolume"
    default: return "value"
    }
}

private func ghostboxPodContainerConfigValueName(_ method: String) -> String {
    switch method {
    case "podContainerConfig.setProcess": return "processConfig"
    case "podContainerConfig.setCPUs": return "cpus"
    case "podContainerConfig.setMemory": return "bytes"
    case "podContainerConfig.setHostname": return "hostname"
    case "podContainerConfig.setSysctl": return "keyValue"
    case "podContainerConfig.setMounts": return "mount"
    case "podContainerConfig.setMaskedPaths", "podContainerConfig.setReadonlyPaths": return "path"
    case "podContainerConfig.setSockets": return "socket"
    case "podContainerConfig.setDNS": return "dns"
    case "podContainerConfig.setHosts": return "hosts"
    case "podContainerConfig.setUseInit": return "enabled"
    default: return "value"
    }
}

private func ghostboxPodAllowedParameters(_ method: String) -> Set<String> {
    switch method {
    case "pod.addContainer": return ["pod", "container", "rootfs", "configuration"]
    case "pod.startContainer", "pod.stopContainer", "pod.closeContainerStdin": return ["pod", "podContainer"]
    case "pod.killContainer": return ["pod", "podContainer", "signal"]
    case "pod.waitContainer": return ["pod", "podContainer", "timeoutSeconds"]
    case "pod.resizeContainer": return ["pod", "podContainer", "width", "height"]
    case "pod.execInContainer": return ["pod", "podContainer", "process", "configuration"]
    case "pod.statistics": return ["pod", "container", "category"]
    case "pod.dialVsock": return ["pod", "port"]
    case "pod.filesystemOperation": return ["pod", "podContainer", "operation", "path"]
    case "pod.relayUnixSocket": return ["pod", "podContainer", "socket"]
    default: return ["pod"]
    }
}

private func ghostboxPodAssignments(_ values: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for value in values {
        guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
            throw DirectDispatchError(.invalidArgument, "sysctl values must use KEY=VALUE")
        }
        let key = String(value[..<separator])
        guard result[key] == nil else { throw DirectDispatchError(.invalidArgument, "duplicate sysctl '\(key)'") }
        result[key] = String(value[value.index(after: separator)...])
    }
    return result
}

private func ghostboxPodBool(_ value: GhostboxJSONValue?, name: String) throws -> Bool? {
    guard let value else { return nil }
    guard case .boolean(let result) = value else {
        throw DirectDispatchError(.invalidArgument, "pod volume source '\(name)' must be a boolean")
    }
    return result
}

private func ghostboxPodUInt64(_ value: GhostboxJSONValue?, name: String) throws -> UInt64? {
    guard let value else { return nil }
    switch value {
    case .unsignedInteger(let result): return result
    case .integer(let result) where result >= 0: return UInt64(result)
    default: throw DirectDispatchError(.invalidArgument, "pod volume source '\(name)' must be an unsigned integer")
    }
}

private func ghostboxPodDouble(_ value: GhostboxJSONValue?, name: String) throws -> Double? {
    guard let integer = try ghostboxPodUInt64(value, name: name) else { return nil }
    return Double(integer)
}

private func ghostboxPodConfigurationsEqual(_ lhs: LinuxPod.Configuration, _ rhs: LinuxPod.Configuration) -> Bool {
    lhs.cpus == rhs.cpus
        && lhs.memoryInBytes == rhs.memoryInBytes
        && lhs.virtualization == rhs.virtualization
        && lhs.shareProcessNamespace == rhs.shareProcessNamespace
        && lhs.hostname == rhs.hostname
        && lhs.interfaces.count == rhs.interfaces.count
        && lhs.volumes.map(\.name) == rhs.volumes.map(\.name)
}

private func ghostboxPodContainerConfigurationsEqual(
    _ lhs: LinuxPod.ContainerConfiguration,
    _ rhs: LinuxPod.ContainerConfiguration
) -> Bool {
    ghostboxProcessConfigurationEqual(lhs.process, rhs.process)
        && lhs.cpus == rhs.cpus
        && lhs.memoryInBytes == rhs.memoryInBytes
        && lhs.hostname == rhs.hostname
        && lhs.sysctl == rhs.sysctl
        && lhs.mounts.count == rhs.mounts.count
        && lhs.maskedPaths == rhs.maskedPaths
        && lhs.readonlyPaths == rhs.readonlyPaths
        && lhs.sockets.count == rhs.sockets.count
        && lhs.useInit == rhs.useInit
}
