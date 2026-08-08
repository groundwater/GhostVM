import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Foundation
import GhostVMKit

struct GhostboxManagerCommands: GhostboxDomainHandler {
    let resource = "manager"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        switch method.rawValue {
        case "manager.create", "manager.createAtRoot", "manager.createFromReference",
             "manager.createFromReferenceAtRoot", "manager.createWithVMM":
            return try await createManager(method: method, parameters: parameters, session: session)
        case "manager.imageStore":
            let decoded = try GhostboxParameters(parameters, allowed: ["manager"])
            let record = try manager(decoded, session: session)
            return .reference(record.imageStoreReference)
        case GhostboxDirectMethod.managerClose.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["manager"])
            let managerReference = try decoded.requiredReference("manager", expectedKind: "manager")
            let record: GhostboxManagerRecord = try session.value(for: managerReference, expectedKind: "manager")
            try await record.box.retireIfUnused(reference: managerReference)
            try session.unregister(managerReference, expectedKind: "manager", matching: record)
            if record.ownsImageStoreReference {
                let store: ImageStore = try session.value(
                    for: record.imageStoreReference,
                    expectedKind: "image-store"
                )
                try session.unregister(record.imageStoreReference, expectedKind: "image-store", matching: store)
            }
            return .void
        case "manager.createContainer", "manager.createContainerFromImage", "manager.createContainerFromMounts":
            return try await createContainer(method: method, parameters: parameters, session: session)
        case "manager.releaseNetwork", "manager.delete":
            let decoded = try GhostboxParameters(parameters, allowed: ["manager", "container"])
            let managerReference = try decoded.requiredReference("manager", expectedKind: "manager")
            let record: GhostboxManagerRecord = try session.value(for: managerReference, expectedKind: "manager")
            let containerReference = try decoded.requiredReference("container", expectedKind: "container")
            let container: GhostboxContainerRecord = try session.value(for: containerReference, expectedKind: "container")
            guard container.managerReference == managerReference else {
                throw DirectDispatchError(.invalidArgument, "container does not belong to the requested manager")
            }
            if method.rawValue == "manager.releaseNetwork" {
                try await record.box.releaseNetwork(container.value.id)
            } else {
                guard let generation = container.managerGeneration else {
                    throw DirectDispatchError(.invalidArgument, "container has no manager allocation generation")
                }
                try await record.box.delete(container.value.id, generation: generation)
                try session.unregister(containerReference, expectedKind: "container", matching: container)
            }
            return .void
        default:
            throw ghostboxUnsupported(method)
        }
    }

    private func createManager(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        var allowed: Set<String> = ["manager", "network"]
        if method.rawValue == "manager.createWithVMM" {
            allowed.insert("vmm")
        } else {
            allowed.formUnion(["kernel", "rosetta", "nestedVirtualization"])
            if method.rawValue.contains("FromReference") {
                allowed.formUnion(["initfsReference"])
            } else {
                allowed.insert("initfs")
            }
            if method.rawValue.contains("AtRoot") {
                allowed.insert("root")
            } else {
                allowed.insert("imageStore")
            }
        }
        let decoded = try GhostboxParameters(parameters, allowed: allowed)
        let managerName = try decoded.requiredString("manager")
        _ = try GhostboxReference.canonical(kind: "manager", name: managerName)
        let network = try ghostboxManagerNetwork(decoded, session: session)
        let manager: ContainerManager
        let provenance: String
        var imageStoreReference: String?

        if method.rawValue == "manager.createWithVMM" {
            let vmmReference = try decoded.requiredReference("vmm", expectedKind: "vmm")
            let vmm: GhostboxVMMRecord = try session.value(for: vmmReference, expectedKind: "vmm")
            manager = try ContainerManager(vmm: vmm.value, network: network)
            provenance = "vmm:\(vmmReference)"
        } else {
            let kernelReference = try decoded.requiredReference("kernel", expectedKind: "kernel")
            let kernel: Kernel = try session.value(for: kernelReference, expectedKind: "kernel")
            let rosetta = try decoded.optionalBool("rosetta") ?? false
            let nested = try decoded.optionalBool("nestedVirtualization") ?? false
            if method.rawValue == "manager.create" {
                let initfsReference = try decoded.requiredReference("initfs", expectedKind: "mount")
                let initfs: Containerization.Mount = try session.value(for: initfsReference, expectedKind: "mount")
                let suppliedImageStoreReference = try decoded.requiredReference("imageStore", expectedKind: "image-store")
                imageStoreReference = suppliedImageStoreReference
                let store: ImageStore = try session.value(for: suppliedImageStoreReference, expectedKind: "image-store")
                manager = try ContainerManager(
                    kernel: kernel, initfs: initfs, imageStore: store, network: network,
                    rosetta: rosetta, nestedVirtualization: nested
                )
                provenance = "kernel:\(kernelReference)|initfs:\(initfsReference)"
            } else if method.rawValue == "manager.createAtRoot" {
                let initfsReference = try decoded.requiredReference("initfs", expectedKind: "mount")
                let initfs: Containerization.Mount = try session.value(for: initfsReference, expectedKind: "mount")
                manager = try ContainerManager(
                    kernel: kernel, initfs: initfs, root: try decoded.optionalString("root").map(ghostboxHostURL),
                    network: network, rosetta: rosetta, nestedVirtualization: nested
                )
                provenance = "kernel:\(kernelReference)|initfs:\(initfsReference)"
            } else if method.rawValue == "manager.createFromReference" {
                let suppliedImageStoreReference = try decoded.requiredReference("imageStore", expectedKind: "image-store")
                imageStoreReference = suppliedImageStoreReference
                let store: ImageStore = try session.value(for: suppliedImageStoreReference, expectedKind: "image-store")
                let initfsReference = try decoded.requiredString("initfsReference")
                let initfs = try await ghostboxInitBlock(reference: initfsReference, imageStore: store)
                manager = try ContainerManager(
                    kernel: kernel, initfs: initfs, imageStore: store, network: network,
                    rosetta: rosetta, nestedVirtualization: nested
                )
                provenance = "kernel:\(kernelReference)|initfs-reference:\(initfsReference)"
            } else {
                let initfsReference = try decoded.requiredString("initfsReference")
                let store: ImageStore
                if let root = try decoded.optionalString("root") {
                    store = try ImageStore(path: ghostboxHostURL(root))
                } else {
                    store = .default
                }
                let initfs = try await ghostboxInitBlock(reference: initfsReference, imageStore: store)
                manager = try ContainerManager(
                    kernel: kernel, initfs: initfs, imageStore: store, network: network,
                    rosetta: rosetta, nestedVirtualization: nested
                )
                provenance = "kernel:\(kernelReference)|initfs-reference:\(initfsReference)"
            }
        }

        let resolvedImageStoreReference: String
        if let imageStoreReference {
            resolvedImageStoreReference = imageStoreReference
        } else {
            resolvedImageStoreReference = try session.register(
                kind: "image-store",
                name: "\(managerName)-images",
                value: manager.imageStore,
                equivalent: { $0 === $1 }
            )
        }
        let record = GhostboxManagerRecord(
            box: GhostboxManagerBox(manager),
            imageStoreReference: resolvedImageStoreReference,
            ownsImageStoreReference: imageStoreReference == nil,
            provenance: provenance
        )
        do {
            let reference = try session.register(
                kind: "manager",
                name: managerName,
                value: record,
                equivalent: { $0.provenance == $1.provenance && $0.imageStoreReference == $1.imageStoreReference },
                cleanupPriority: 70,
                cleanup: { await $0.box.cleanupAllocations() }
            )
            return .reference(reference)
        } catch {
            if imageStoreReference == nil {
                try? session.unregister(
                    resolvedImageStoreReference,
                    expectedKind: "image-store",
                    matching: manager.imageStore
                )
            }
            throw error
        }
    }

    private func createContainer(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        let baseAllowed: Set<String> = [
            "manager", "container", "networking", "process", "cpus", "memory", "hostname", "sysctl",
            "interfaces", "sockets", "mounts", "maskedPaths", "readonlyPaths", "dns", "hosts",
            "virtualization", "bootLog", "ociRuntimePath", "useInit", "cpuOverhead", "memoryOverhead",
        ]
        let methodAllowed: Set<String>
        switch method.rawValue {
        case "manager.createContainer":
            methodAllowed = ["reference", "rootfsSize", "writableLayerSize", "readOnly", "progress"]
        case "manager.createContainerFromImage":
            methodAllowed = ["image", "rootfsSize", "writableLayerSize", "readOnly", "progress"]
        default:
            methodAllowed = ["image", "rootfs", "writableLayer"]
        }
        let decoded = try GhostboxParameters(parameters, allowed: baseAllowed.union(methodAllowed))
        let managerReference = try decoded.requiredReference("manager", expectedKind: "manager")
        let manager: GhostboxManagerRecord = try session.value(for: managerReference, expectedKind: "manager")
        let name = try decoded.requiredString("container")
        _ = try GhostboxReference.canonical(kind: "container", name: name)
        let overrides = try GhostboxContainerOverrides(parameters: parameters, decoded: decoded, session: session)
        let networking = try decoded.optionalBool("networking") ?? true
        let reference: String

        switch method.rawValue {
        case "manager.createContainer":
            reference = try await manager.box.create(
                id: name,
                reference: decoded.requiredString("reference"),
                rootfsSize: try decoded.optionalUInt64("rootfsSize") ?? 8_589_934_592,
                writableLayerSize: try decoded.optionalUInt64("writableLayerSize"),
                readOnly: try decoded.optionalBool("readOnly") ?? false,
                networking: networking,
                progress: try ghostboxProgressHandler(
                    decoded.optionalReference("progress", expectedKind: "progress-handler"), session: session
                ),
                overrides: overrides,
                registration: { container, generation in
                    try ghostboxRegisterContainer(
                        container, name: name, managerReference: managerReference,
                        managerBox: manager.box, managerGeneration: generation,
                        rootfsReference: nil, writableLayerReference: nil,
                        session: session
                    )
                }
            )
        case "manager.createContainerFromImage":
            let imageReference = try decoded.requiredReference("image", expectedKind: "image")
            reference = try await manager.box.create(
                id: name,
                image: ghostboxImageValue(imageReference, session: session),
                rootfsSize: try decoded.optionalUInt64("rootfsSize") ?? 8_589_934_592,
                writableLayerSize: try decoded.optionalUInt64("writableLayerSize"),
                readOnly: try decoded.optionalBool("readOnly") ?? false,
                networking: networking,
                progress: try ghostboxProgressHandler(
                    decoded.optionalReference("progress", expectedKind: "progress-handler"), session: session
                ),
                overrides: overrides,
                registration: { container, generation in
                    try ghostboxRegisterContainer(
                        container, name: name, managerReference: managerReference,
                        managerBox: manager.box, managerGeneration: generation,
                        rootfsReference: nil, writableLayerReference: nil,
                        session: session
                    )
                }
            )
        default:
            let imageReference = try decoded.requiredReference("image", expectedKind: "image")
            let suppliedRootfsReference = try decoded.requiredReference("rootfs", expectedKind: "mount")
            let rootfs: Containerization.Mount = try session.value(for: suppliedRootfsReference, expectedKind: "mount")
            let writableLayerReference = try decoded.optionalReference("writableLayer", expectedKind: "mount")
            let writableLayer: Containerization.Mount? = try writableLayerReference.map {
                try session.value(for: $0, expectedKind: "mount")
            }
            reference = try await manager.box.create(
                id: name,
                image: ghostboxImageValue(imageReference, session: session),
                rootfs: rootfs,
                writableLayer: writableLayer,
                networking: networking,
                overrides: overrides,
                registration: { container, generation in
                    try ghostboxRegisterContainer(
                        container, name: name, managerReference: managerReference,
                        managerBox: manager.box, managerGeneration: generation,
                        rootfsReference: suppliedRootfsReference,
                        writableLayerReference: writableLayerReference, session: session
                    )
                }
            )
        }
        return .reference(reference)
    }

    private func manager(_ decoded: GhostboxParameters, session: GhostboxSession) throws -> GhostboxManagerRecord {
        let reference = try decoded.requiredReference("manager", expectedKind: "manager")
        return try session.value(for: reference, expectedKind: "manager")
    }
}

struct GhostboxLiveContainerCommands: GhostboxDomainHandler {
    let resource = "container"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        if ghostboxContainerStaticMethods.contains(method.rawValue) {
            return try await GhostboxContainerCommands().handle(method: method, parameters: parameters, session: session)
        }
        if method.rawValue == "container.list" {
            _ = try GhostboxParameters(parameters, allowed: [])
            let containers: [(reference: String, value: GhostboxContainerRecord)] = try session.valueSnapshots(
                ofKind: "container"
            )
            return .array(containers.map { reference, record in
                .object([
                    "reference": .reference(reference),
                    "id": .string(record.value.id),
                    "name": .string(ghostboxReferenceName(reference)),
                    "managerReference": record.managerReference.map(GhostboxDirectValue.reference) ?? .null,
                    "status": .string(record.lifecycleStatus.rawValue),
                    "cpuCount": .integer(Int64(record.value.cpus)),
                    "memoryBytes": .unsignedInteger(record.value.memoryInBytes),
                ])
            })
        }
        if method.rawValue == "container.createDirect" {
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["container", "rootfs", "writableLayer", "vmm", "configuration"]
            )
            let name = try decoded.requiredString("container")
            let rootfsReference = try decoded.requiredReference("rootfs", expectedKind: "mount")
            let rootfs: Containerization.Mount = try session.value(for: rootfsReference, expectedKind: "mount")
            let writableReference = try decoded.optionalReference("writableLayer", expectedKind: "mount")
            let writable: Containerization.Mount? = try writableReference.map {
                try session.value(for: $0, expectedKind: "mount")
            }
            let vmmReference = try decoded.requiredReference("vmm", expectedKind: "vmm")
            let vmm: GhostboxVMMRecord = try session.value(for: vmmReference, expectedKind: "vmm")
            let configReference = try decoded.requiredReference("configuration", expectedKind: "container-config")
            let config: LinuxContainer.Configuration = try session.value(
                for: configReference,
                expectedKind: "container-config"
            )
            let container = try LinuxContainer(
                name, rootfs: rootfs, writableLayer: writable, vmm: vmm.value, configuration: config
            )
            return .reference(try ghostboxRegisterContainer(
                container, name: name, managerReference: nil, managerBox: nil, managerGeneration: nil,
                rootfsReference: rootfsReference,
                writableLayerReference: writableReference, session: session
            ))
        }

        let allowed = ghostboxContainerAllowedParameters(method.rawValue)
        let decoded = try GhostboxParameters(parameters, allowed: allowed)
        let reference = try decoded.requiredReference("container", expectedKind: "container")
        let record: GhostboxContainerRecord = try session.value(for: reference, expectedKind: "container")
        let container = record.value
        switch method.rawValue {
        case "container.id": return .string(container.id)
        case "container.rootfs":
            if let existing = record.rootfsReference { return .reference(existing) }
            return .reference(try registerMount(container.rootfs, container: reference, suffix: "rootfs", session: session))
        case "container.writableLayer":
            guard let layer = container.writableLayer else { return .null }
            if let existing = record.writableLayerReference { return .reference(existing) }
            return .reference(try registerMount(layer, container: reference, suffix: "writable", session: session))
        case "container.config":
            let name = "\(ghostboxReferenceName(reference))-config"
            let configReference = try session.register(
                kind: "container-config", name: name, value: container.config,
                equivalent: ghostboxContainerConfigurationEqual
            )
            return .reference(configReference)
        case "container.cpus": return .integer(Int64(container.cpus))
        case "container.memory": return .unsignedInteger(container.memoryInBytes)
        case "container.interfaces":
            let references = try container.interfaces.enumerated().map { index, interface in
                try session.register(
                    kind: "interface", name: "\(ghostboxReferenceName(reference))-\(index)",
                    value: GhostboxInterfaceRecord(value: interface, provenance: nil),
                    equivalent: ghostboxInterfaceRecordsEqual
                )
            }
            return .references(references)
        case "container.create":
            try await container.create()
            record.setLifecycleStatus(.created)
            return .void
        case "container.start":
            try await container.start()
            record.setLifecycleStatus(.running)
            return .void
        case "container.stop":
            try await container.stop()
            record.setLifecycleStatus(.stopped)
            return .void
        case "container.kill":
            try await container.kill(Signal(decoded.requiredString("signal")))
            record.setLifecycleStatus(.stopping)
            return .void
        case "container.wait":
            let status = try await container.wait(timeoutInSeconds: decoded.optionalInt64("timeoutSeconds"))
            record.setLifecycleStatus(.exited)
            return ghostboxExitStatusValue(status)
        case "container.resize":
            try await container.resize(to: Terminal.Size(
                width: decoded.requiredInteger("width", as: UInt16.self),
                height: decoded.requiredInteger("height", as: UInt16.self)
            ))
            return .void
        case "container.exec":
            let configReference = try decoded.requiredReference("configuration", expectedKind: "process-config")
            let config = try ghostboxProcessConfiguration(configReference, session: session)
            let processName = try decoded.requiredString("process")
            let process = try await container.exec(processName, configuration: config)
            return .reference(try ghostboxRegisterProcess(process, name: "\(ghostboxReferenceName(reference))-\(processName)", session: session))
        case "container.dialVsock":
            let handle = try await container.dialVsock(port: decoded.requiredInteger("port", as: UInt32.self))
            return .reference(try ghostboxRegisterFileHandle(handle, session: session))
        case "container.closeStdin": try await container.closeStdin(); return .void
        case "container.statistics":
            return ghostboxStatisticsValue(try await container.statistics(categories: try ghostboxStatCategories(decoded.optionalStringArray("category"))))
        case "container.filesystemOperation":
            try await container.filesystemOperation(
                operation: try ghostboxFilesystemOperation(decoded.requiredString("operation")),
                path: decoded.requiredString("path")
            )
            return .void
        case "container.copyIn":
            try await container.copyIn(
                from: ghostboxHostURL(decoded.requiredString("source")),
                to: URL(filePath: decoded.requiredString("destination")),
                mode: try ghostboxFileMode(decoded.optionalString("mode") ?? "0644"),
                createParents: decoded.optionalBool("createParents") ?? true,
                chunkSize: decoded.optionalInt("chunkSize") ?? LinuxContainer.defaultCopyChunkSize
            )
            return .void
        case "container.copyOut":
            try await container.copyOut(
                from: URL(filePath: decoded.requiredString("source")),
                to: ghostboxHostURL(decoded.requiredString("destination")),
                createParents: decoded.optionalBool("createParents") ?? true,
                chunkSize: decoded.optionalInt("chunkSize") ?? LinuxContainer.defaultCopyChunkSize
            )
            return .void
        default: throw ghostboxUnsupported(method)
        }
    }

    private func registerMount(
        _ mount: Containerization.Mount,
        container: String,
        suffix: String,
        session: GhostboxSession
    ) throws -> String {
        try session.register(
            kind: "mount", name: "\(ghostboxReferenceName(container))-\(suffix)",
            value: mount, equivalent: ghostboxMountEqual
        )
    }
}

struct GhostboxProcessCommands: GhostboxDomainHandler {
    let resource = "process"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        let allowed: Set<String>
        switch method.rawValue {
        case "process.kill": allowed = ["process", "signal"]
        case "process.resize": allowed = ["process", "width", "height"]
        case "process.wait": allowed = ["process", "timeoutSeconds"]
        default: allowed = ["process"]
        }
        let decoded = try GhostboxParameters(parameters, allowed: allowed)
        let reference = try decoded.requiredReference("process", expectedKind: "process")
        let process: LinuxProcess = try session.value(for: reference, expectedKind: "process")
        switch method.rawValue {
        case "process.id": return .string(process.id)
        case "process.owningContainer": return process.owningContainer.map(GhostboxDirectValue.string) ?? .null
        case "process.pid": return .integer(Int64(process.pid))
        case "process.start": try await process.start(); return .void
        case "process.kill": try await process.kill(Signal(decoded.requiredString("signal"))); return .void
        case "process.resize":
            try await process.resize(to: Terminal.Size(
                width: decoded.requiredInteger("width", as: UInt16.self),
                height: decoded.requiredInteger("height", as: UInt16.self)
            ))
            return .void
        case "process.closeStdin": try await process.closeStdin(); return .void
        case "process.wait": return ghostboxExitStatusValue(try await process.wait(timeoutInSeconds: decoded.optionalInt64("timeoutSeconds")))
        case "process.delete":
            try await process.delete()
            try session.unregister(reference, expectedKind: "process", matching: process)
            return .void
        default: throw ghostboxUnsupported(method)
        }
    }
}

enum GhostboxLifecycleCommandHandlers {
    static let all: [any GhostboxDomainHandler] = [
        GhostboxManagerCommands(),
        GhostboxLiveContainerCommands(),
        GhostboxProcessCommands(),
    ]
}

struct GhostboxManagerRecord: Sendable {
    let box: GhostboxManagerBox
    let imageStoreReference: String
    let ownsImageStoreReference: Bool
    let provenance: String
}

actor GhostboxManagerBox {
    private var value: ContainerManager
    private var containerGenerations: [String: UUID] = [:]
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var retired = false

    init(_ value: ContainerManager) { self.value = value }

    func releaseNetwork(_ id: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try ensureActive()
        try value.releaseNetwork(id)
    }

    func delete(_ id: String, generation: UUID) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try ensureActive()
        guard containerGenerations[id] == generation else { return }
        var manager = value
        do {
            try manager.delete(id)
            value = manager
            containerGenerations.removeValue(forKey: id)
        } catch {
            value = manager
            throw error
        }
    }

    func create(
        id: String, reference: String, rootfsSize: UInt64, writableLayerSize: UInt64?, readOnly: Bool,
        networking: Bool, progress: ProgressHandler?, overrides: GhostboxContainerOverrides,
        registration: @Sendable (LinuxContainer, UUID) throws -> String
    ) async throws -> String {
        await acquireOperation()
        do {
            try ensureActive()
        } catch {
            releaseOperation()
            throw error
        }
        var manager = value
        var allocated: LinuxContainer?
        do {
            let container = try await manager.create(
                id, reference: reference, rootfsSizeInBytes: rootfsSize,
                writableLayerSizeInBytes: writableLayerSize, readOnly: readOnly,
                networking: networking, progress: progress
            ) { try overrides.apply(to: &$0) }
            allocated = container
            let generation = UUID()
            containerGenerations[id] = generation
            let reference = try registration(container, generation)
            value = manager
            releaseOperation()
            return reference
        } catch {
            if allocated != nil {
                do {
                    try manager.delete(id)
                    containerGenerations.removeValue(forKey: id)
                } catch {}
            }
            value = manager
            releaseOperation()
            throw error
        }
    }

    func create(
        id: String, image: Containerization.Image, rootfsSize: UInt64, writableLayerSize: UInt64?,
        readOnly: Bool, networking: Bool, progress: ProgressHandler?, overrides: GhostboxContainerOverrides,
        registration: @Sendable (LinuxContainer, UUID) throws -> String
    ) async throws -> String {
        await acquireOperation()
        do {
            try ensureActive()
        } catch {
            releaseOperation()
            throw error
        }
        var manager = value
        var allocated: LinuxContainer?
        do {
            let container = try await manager.create(
                id, image: image, rootfsSizeInBytes: rootfsSize,
                writableLayerSizeInBytes: writableLayerSize, readOnly: readOnly,
                networking: networking, progress: progress
            ) { try overrides.apply(to: &$0) }
            allocated = container
            let generation = UUID()
            containerGenerations[id] = generation
            let reference = try registration(container, generation)
            value = manager
            releaseOperation()
            return reference
        } catch {
            if allocated != nil {
                do {
                    try manager.delete(id)
                    containerGenerations.removeValue(forKey: id)
                } catch {}
            }
            value = manager
            releaseOperation()
            throw error
        }
    }

    func create(
        id: String, image: Containerization.Image, rootfs: Containerization.Mount,
        writableLayer: Containerization.Mount?, networking: Bool, overrides: GhostboxContainerOverrides,
        registration: @Sendable (LinuxContainer, UUID) throws -> String
    ) async throws -> String {
        await acquireOperation()
        do {
            try ensureActive()
        } catch {
            releaseOperation()
            throw error
        }
        var manager = value
        var allocated: LinuxContainer?
        do {
            let container = try await manager.create(
                id, image: image, rootfs: rootfs, writableLayer: writableLayer, networking: networking
            ) { try overrides.apply(to: &$0) }
            allocated = container
            let generation = UUID()
            containerGenerations[id] = generation
            let reference = try registration(container, generation)
            value = manager
            releaseOperation()
            return reference
        } catch {
            if allocated != nil {
                do {
                    try manager.delete(id)
                    containerGenerations.removeValue(forKey: id)
                } catch {}
            }
            value = manager
            releaseOperation()
            throw error
        }
    }

    func cleanup(_ container: LinuxContainer, generation: UUID) async {
        await acquireOperation()
        defer { releaseOperation() }

        try? await container.stop()
        guard containerGenerations[container.id] == generation else { return }
        var manager = value
        do {
            try manager.delete(container.id)
            containerGenerations.removeValue(forKey: container.id)
        } catch {}
        value = manager
    }

    func cleanupAllocations() async {
        await acquireOperation()
        defer { releaseOperation() }

        var manager = value
        for id in Array(containerGenerations.keys) {
            do {
                try manager.delete(id)
                containerGenerations.removeValue(forKey: id)
            } catch {}
        }
        value = manager
    }

    func retireIfUnused(reference: String) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        try ensureActive()
        guard containerGenerations.isEmpty else {
            throw DirectDispatchError(
                .failedPrecondition,
                "manager '\(reference)' still has managed containers"
            )
        }
        retired = true
    }

    private func ensureActive() throws {
        guard !retired else {
            throw DirectDispatchError(.failedPrecondition, "manager is closed")
        }
    }

    private func acquireOperation() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationInProgress = false
            return
        }
        operationWaiters.removeFirst().resume()
    }
}

enum GhostboxContainerLifecycleStatus: String, Sendable {
    case configured
    case created
    case running
    case stopping
    case stopped
    case exited
}

struct GhostboxContainerRecord: Sendable {
    let value: LinuxContainer
    let managerReference: String?
    let managerGeneration: UUID?
    let rootfsReference: String?
    let writableLayerReference: String?
    private let status: GhostboxMutableSlot<GhostboxContainerLifecycleStatus>

    init(
        value: LinuxContainer,
        managerReference: String?,
        managerGeneration: UUID?,
        rootfsReference: String?,
        writableLayerReference: String?,
        lifecycleStatus: GhostboxContainerLifecycleStatus = .configured
    ) {
        self.value = value
        self.managerReference = managerReference
        self.managerGeneration = managerGeneration
        self.rootfsReference = rootfsReference
        self.writableLayerReference = writableLayerReference
        status = GhostboxMutableSlot(lifecycleStatus)
    }

    var lifecycleStatus: GhostboxContainerLifecycleStatus { status.get() }

    func setLifecycleStatus(_ lifecycleStatus: GhostboxContainerLifecycleStatus) {
        status.set(lifecycleStatus)
    }
}

struct GhostboxContainerOverrides: Sendable {
    let process: LinuxProcessConfiguration?
    let cpus: Int?
    let memory: UInt64?
    let hostname: String?
    let hasHostname: Bool
    let sysctl: [String: String]?
    let interfaces: [any Interface]?
    let sockets: [UnixSocketConfiguration]?
    let mounts: [Containerization.Mount]?
    let maskedPaths: [String]?
    let readonlyPaths: [String]?
    let dns: DNS?
    let hosts: Hosts?
    let virtualization: Bool?
    let bootLog: BootLog?
    let ociRuntimePath: String?
    let hasOCIRuntimePath: Bool
    let useInit: Bool?
    let cpuOverhead: Int?
    let memoryOverhead: UInt64?

    init(parameters: [String: GhostboxJSONValue], decoded: GhostboxParameters, session: GhostboxSession) throws {
        process = try decoded.optionalReference("process", expectedKind: "process-config").map {
            try ghostboxProcessConfiguration($0, session: session)
        }
        cpus = try decoded.optionalInt("cpus")
        memory = try decoded.optionalUInt64("memory")
        hostname = try decoded.optionalString("hostname")
        hasHostname = parameters["hostname"] != nil
        sysctl = try decoded.optionalStringArray("sysctl").map(ghostboxParseAssignments)
        interfaces = try decoded.optionalReferences("interfaces", expectedKind: "interface").map { references in
            try references.map { try session.value(for: $0, expectedKind: "interface", as: (any Interface).self) }
        }
        sockets = try decoded.optionalReferences("sockets", expectedKind: "socket").map { references in
            try references.map { try session.value(for: $0, expectedKind: "socket") }
        }
        mounts = try decoded.optionalReferences("mounts", expectedKind: "mount").map { references in
            try references.map { try session.value(for: $0, expectedKind: "mount") }
        }
        maskedPaths = try decoded.optionalStringArray("maskedPaths")
        readonlyPaths = try decoded.optionalStringArray("readonlyPaths")
        dns = try decoded.optionalReference("dns", expectedKind: "dns").map {
            try session.value(for: $0, expectedKind: "dns")
        }
        hosts = try decoded.optionalReference("hosts", expectedKind: "hosts").map {
            let record: GhostboxHostsRecord = try session.value(for: $0, expectedKind: "hosts")
            return record.value
        }
        virtualization = try decoded.optionalBool("virtualization")
        bootLog = try decoded.optionalReference("bootLog", expectedKind: "boot-log").map {
            try session.value(for: $0, expectedKind: "boot-log")
        }
        ociRuntimePath = try decoded.optionalString("ociRuntimePath")
        hasOCIRuntimePath = parameters["ociRuntimePath"] != nil
        useInit = try decoded.optionalBool("useInit")
        cpuOverhead = try decoded.optionalInt("cpuOverhead")
        memoryOverhead = try decoded.optionalUInt64("memoryOverhead")
    }

    func apply(to config: inout LinuxContainer.Configuration) throws {
        if let process { config.process = process }
        if let cpus { config.cpus = cpus }
        if let memory { config.memoryInBytes = memory }
        if hasHostname { config.hostname = hostname }
        if let sysctl { config.sysctl = sysctl }
        if let interfaces { config.interfaces = interfaces }
        if let sockets { config.sockets = sockets }
        if let mounts { config.mounts = mounts }
        if let maskedPaths { config.maskedPaths = maskedPaths }
        if let readonlyPaths { config.readonlyPaths = readonlyPaths }
        if let dns { config.dns = dns }
        if let hosts { config.hosts = hosts }
        if let virtualization { config.virtualization = virtualization }
        if let bootLog { config.bootLog = bootLog }
        if hasOCIRuntimePath { config.ociRuntimePath = ociRuntimePath }
        if let useInit { config.useInit = useInit }
        if let overhead = GhostboxResourceOverheadPolicy.cpu(requested: cpus, explicit: cpuOverhead) {
            config.cpuOverhead = overhead
        }
        if let overhead = GhostboxResourceOverheadPolicy.memory(requested: memory, explicit: memoryOverhead) {
            config.memoryOverhead = overhead
        }
    }
}

private let ghostboxContainerStaticMethods: Set<String> = [
    "container.defaultMounts", "container.defaultOCIMounts", "container.defaultMaskedPaths",
    "container.defaultReadonlyPaths", "container.defaultCopyChunkSize", "container.maxIDLength",
]

private func ghostboxContainerAllowedParameters(_ method: String) -> Set<String> {
    switch method {
    case "container.kill": return ["container", "signal"]
    case "container.wait": return ["container", "timeoutSeconds"]
    case "container.resize": return ["container", "width", "height"]
    case "container.exec": return ["container", "process", "configuration"]
    case "container.dialVsock": return ["container", "port"]
    case "container.statistics": return ["container", "category"]
    case "container.filesystemOperation": return ["container", "operation", "path"]
    case "container.copyIn": return ["container", "source", "destination", "mode", "createParents", "chunkSize"]
    case "container.copyOut": return ["container", "source", "destination", "createParents", "chunkSize"]
    default: return ["container"]
    }
}

func ghostboxRegisterContainer(
    _ container: LinuxContainer,
    name: String,
    managerReference: String?,
    managerBox: GhostboxManagerBox?,
    managerGeneration: UUID?,
    rootfsReference: String?,
    writableLayerReference: String?,
    session: GhostboxSession
) throws -> String {
    let record = GhostboxContainerRecord(
        value: container, managerReference: managerReference,
        managerGeneration: managerGeneration,
        rootfsReference: rootfsReference, writableLayerReference: writableLayerReference
    )
    return try session.register(
        kind: "container", name: name, value: record,
        equivalent: { $0.value === $1.value },
        cleanupPriority: 80,
        cleanup: {
            if let managerBox, let managerGeneration {
                await managerBox.cleanup($0.value, generation: managerGeneration)
            } else {
                try? await $0.value.stop()
            }
        }
    )
}

func ghostboxRegisterProcess(_ process: LinuxProcess, name: String, session: GhostboxSession) throws -> String {
    try session.register(
        kind: "process", name: name, value: process, equivalent: { $0 === $1 },
        cleanupPriority: 90,
        cleanup: { try? await $0.delete() }
    )
}

func ghostboxRegisterFileHandle(_ handle: FileHandle, session: GhostboxSession) throws -> String {
    try session.register(
        kind: "file-handle", name: UUID().uuidString.lowercased(), value: handle,
        equivalent: { $0 === $1 },
        cleanupPriority: 100,
        cleanup: { try? $0.close() }
    )
}

func ghostboxExitStatusValue(_ status: ExitStatus) -> GhostboxDirectValue {
    .object([
        "exitCode": .integer(Int64(status.exitCode)),
        "exitedAt": .string(ISO8601DateFormatter().string(from: status.exitedAt)),
    ])
}

func ghostboxStatCategories(_ names: [String]?) throws -> StatCategory {
    guard let names, !names.isEmpty else { return .all }
    var result: StatCategory = []
    for name in names {
        switch name {
        case "all": result.formUnion(.all)
        case "process": result.insert(.process)
        case "memory": result.insert(.memory)
        case "cpu": result.insert(.cpu)
        case "block-io": result.insert(.blockIO)
        case "network": result.insert(.network)
        case "memory-events": result.insert(.memoryEvents)
        default: throw DirectDispatchError(.invalidArgument, "unknown statistics category '\(name)'")
        }
    }
    return result
}

func ghostboxStatisticsValue(_ statistics: ContainerStatistics) -> GhostboxDirectValue {
    var result: [String: GhostboxDirectValue] = ["id": .string(statistics.id)]
    if let process = statistics.process {
        result["process"] = .object(["current": .unsignedInteger(process.current), "limit": .unsignedInteger(process.limit)])
    }
    if let memory = statistics.memory {
        result["memory"] = .object([
            "usageBytes": .unsignedInteger(memory.usageBytes), "limitBytes": .unsignedInteger(memory.limitBytes),
            "swapUsageBytes": .unsignedInteger(memory.swapUsageBytes), "swapLimitBytes": .unsignedInteger(memory.swapLimitBytes),
            "cacheBytes": .unsignedInteger(memory.cacheBytes), "kernelStackBytes": .unsignedInteger(memory.kernelStackBytes),
            "slabBytes": .unsignedInteger(memory.slabBytes), "pageFaults": .unsignedInteger(memory.pageFaults),
            "majorPageFaults": .unsignedInteger(memory.majorPageFaults), "inactiveFile": .unsignedInteger(memory.inactiveFile),
            "anon": .unsignedInteger(memory.anon), "workingsetRefaultAnon": .unsignedInteger(memory.workingsetRefaultAnon),
            "workingsetRefaultFile": .unsignedInteger(memory.workingsetRefaultFile),
            "pgstealKswapd": .unsignedInteger(memory.pgstealKswapd), "pgstealDirect": .unsignedInteger(memory.pgstealDirect),
            "pgstealKhugepaged": .unsignedInteger(memory.pgstealKhugepaged),
        ])
    }
    if let cpu = statistics.cpu {
        result["cpu"] = .object([
            "usageUsec": .unsignedInteger(cpu.usageUsec), "userUsec": .unsignedInteger(cpu.userUsec),
            "systemUsec": .unsignedInteger(cpu.systemUsec), "throttlingPeriods": .unsignedInteger(cpu.throttlingPeriods),
            "throttledPeriods": .unsignedInteger(cpu.throttledPeriods), "throttledTimeUsec": .unsignedInteger(cpu.throttledTimeUsec),
        ])
    }
    if let blockIO = statistics.blockIO {
        result["blockIO"] = .array(blockIO.devices.map { device in
            .object([
                "major": .unsignedInteger(device.major), "minor": .unsignedInteger(device.minor),
                "readBytes": .unsignedInteger(device.readBytes), "writeBytes": .unsignedInteger(device.writeBytes),
                "readOperations": .unsignedInteger(device.readOperations), "writeOperations": .unsignedInteger(device.writeOperations),
            ])
        })
    }
    if let networks = statistics.networks {
        result["networks"] = .array(networks.map { network in
            .object([
                "interface": .string(network.interface), "receivedPackets": .unsignedInteger(network.receivedPackets),
                "transmittedPackets": .unsignedInteger(network.transmittedPackets), "receivedBytes": .unsignedInteger(network.receivedBytes),
                "transmittedBytes": .unsignedInteger(network.transmittedBytes), "receivedErrors": .unsignedInteger(network.receivedErrors),
                "transmittedErrors": .unsignedInteger(network.transmittedErrors),
            ])
        })
    }
    if let events = statistics.memoryEvents {
        result["memoryEvents"] = .object([
            "low": .unsignedInteger(events.low), "high": .unsignedInteger(events.high), "max": .unsignedInteger(events.max),
            "oom": .unsignedInteger(events.oom), "oomKill": .unsignedInteger(events.oomKill),
        ])
    }
    return .object(result)
}

func ghostboxFilesystemOperation(_ raw: String) throws -> FilesystemOperation {
    switch raw {
    case "freeze": return .freeze
    case "thaw": return .thaw
    case "trim": return .trim
    default: throw DirectDispatchError(.invalidArgument, "unknown filesystem operation '\(raw)'")
    }
}

func ghostboxHostURL(_ raw: String) -> URL {
    if let url = URL(string: raw), url.scheme != nil { return url }
    return URL(filePath: raw)
}

private func ghostboxManagerNetwork(_ decoded: GhostboxParameters, session: GhostboxSession) throws -> (any Network)? {
    guard let reference = try decoded.optionalReference("network", expectedKind: "network") else {
        return session.contextValue(ghostboxSharedNetworkContextKey, as: GhostboxNetwork.self)
    }
    return try ghostboxNetwork(reference, session: session)
}

private func ghostboxInitBlock(reference: String, imageStore: ImageStore) async throws -> Containerization.Mount {
    let directory = imageStore.path.appendingPathComponent("ghostbox/initfs", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(String(reference.stableHash, radix: 16) + ".ext4")
    let image = try await imageStore.getInitImage(reference: reference)
    do {
        return try await image.initBlock(at: path, for: .linuxArm)
    } catch let error as ContainerizationError {
        guard error.code == .exists else { throw error }
        return .block(format: "ext4", source: path.absolutePath(), destination: "/", options: ["ro"])
    }
}

private func ghostboxParseAssignments(_ assignments: [String]) throws -> [String: String] {
    var result: [String: String] = [:]
    for assignment in assignments {
        guard let separator = assignment.firstIndex(of: "="), separator != assignment.startIndex else {
            throw DirectDispatchError(.invalidArgument, "value '\(assignment)' must use KEY=VALUE syntax")
        }
        let key = String(assignment[..<separator])
        guard result[key] == nil else { throw DirectDispatchError(.invalidArgument, "duplicate key '\(key)'") }
        result[key] = String(assignment[assignment.index(after: separator)...])
    }
    return result
}

private func ghostboxFileMode(_ raw: String) throws -> UInt32 {
    let digits = raw.hasPrefix("0o") ? String(raw.dropFirst(2)) : raw
    guard let value = UInt32(digits, radix: 8), value <= 0o7777 else {
        throw DirectDispatchError(.invalidArgument, "file mode must be an octal value")
    }
    return value
}
