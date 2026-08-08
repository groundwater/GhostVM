import Containerization
import ContainerizationArchive
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import GhostVMKit
import NIOPosix
import XPC
import vmnet

struct RuntimeBuildOptions: Sendable {
    let root: URL
    let kernel: URL
    let id: String
    let contextArchive: URL
    let dockerfile: Data
    let tags: [String]
    let buildArguments: [String]
    let target: String
    let noCache: Bool
    let pull: Bool

    static func parse(_ arguments: [String]) throws -> Self {
        guard arguments.first == "build" else { throw RuntimeBuildError.usage }
        var root: String?
        var kernel: String?
        var id: String?
        var context: String?
        var dockerfile: Data?
        var tags: [String] = []
        var buildArguments: [String] = []
        var target = ""
        var noCache = false
        var pull = false
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--no-cache" { noCache = true; index += 1; continue }
            if flag == "--pull" { pull = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw RuntimeBuildError.usage }
            let value = arguments[index + 1]
            switch flag {
            case "--root": root = value
            case "--kernel": kernel = value
            case "--id": id = value
            case "--context": context = value
            case "--dockerfile": dockerfile = Data(base64Encoded: value)
            case "--tag": tags.append(value)
            case "--build-arg": buildArguments.append(value)
            case "--target": target = value
            default: throw RuntimeBuildError.usage
            }
            index += 2
        }
        guard let root, let kernel, let id, let context, let dockerfile, !dockerfile.isEmpty else {
            throw RuntimeBuildError.usage
        }
        return Self(
            root: URL(fileURLWithPath: root, isDirectory: true),
            kernel: URL(fileURLWithPath: kernel),
            id: id,
            contextArchive: URL(fileURLWithPath: context),
            dockerfile: dockerfile,
            tags: tags,
            buildArguments: buildArguments,
            target: target,
            noCache: noCache,
            pull: pull
        )
    }
}

enum RuntimeBuildError: Error, LocalizedError {
    case usage
    case kernelNotFound(String)
    case rejectedArchive(String)
    case builderUnavailable
    case missingExport(String)
    case emptyExport

    var errorDescription: String? {
        switch self {
        case .usage:
            return "invalid container build request"
        case .kernelNotFound(let path):
            return "container kernel not found at \(path)"
        case .rejectedArchive(let paths):
            return "archive contains unsafe members: \(paths)"
        case .builderUnavailable:
            return "BuildKit did not open its vsock service"
        case .missingExport(let path):
            return "BuildKit did not create its OCI export at \(path)"
        case .emptyExport:
            return "BuildKit produced an empty OCI image export"
        }
    }
}

/// Owns one builder VM, the reconstructed vmnet reference, and the output
/// descriptors until the OCI export has been imported and tagged.
final class BuildContext: @unchecked Sendable {
    let connection: xpc_connection_t
    let runIdentifier: String
    private let options: RuntimeBuildOptions
    private let networkReference: vmnet_network_ref
    private let ipv4Address: String
    private let ipv4Gateway: String
    private let macAddress: String
    private let mtu: UInt32
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let onComplete: @Sendable (BuildContext) -> Void

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var activeContainer: LinuxContainer?
    private var cancelled = false
    private var completed = false
    private var networkReleased = false

    init(
        connection: xpc_connection_t,
        runIdentifier: String,
        options: RuntimeBuildOptions,
        networkReference: vmnet_network_ref,
        ipv4Address: String,
        ipv4Gateway: String,
        macAddress: String,
        mtu: UInt32,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        onComplete: @escaping @Sendable (BuildContext) -> Void
    ) {
        self.connection = connection
        self.runIdentifier = runIdentifier
        self.options = options
        self.networkReference = networkReference
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
        self.onComplete = onComplete
    }

    func start() {
        let task = Task { [self] in
            let result = await runBuild()
            complete(exitCode: result.exitCode, message: result.message)
        }
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancelTask() {
        let (task, container) = lock.withLock { () -> (Task<Void, Never>?, LinuxContainer?) in
            cancelled = true
            return (self.task, activeContainer)
        }
        task?.cancel()
        if let container { Task { try? await container.stop() } }
    }

    private func runBuild() async -> (exitCode: Int32, message: String?) {
        do {
            guard FileManager.default.isReadableFile(atPath: options.kernel.path) else {
                throw RuntimeBuildError.kernelNotFound(options.kernel.path)
            }
            let work = options.root.appendingPathComponent("build-runtime/\(options.id)", isDirectory: true)
            let context = work.appendingPathComponent("context", isDirectory: true)
            let exports = work.appendingPathComponent("exports", isDirectory: true)
            let ociLayout = work.appendingPathComponent("oci", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            let rejectedContext = try ArchiveReader(file: options.contextArchive).extractContents(to: context)
            guard rejectedContext.isEmpty else {
                throw RuntimeBuildError.rejectedArchive(rejectedContext.prefix(8).joined(separator: ", "))
            }

            let contentStore = try LocalContentStore(path: options.root.appendingPathComponent("content", isDirectory: true))
            let imageStore = try ImageStore(path: options.root, contentStore: contentStore)
            let builderReference = ContainerRuntimeXPCProtocol.builderImage
            let builderImage = try await imageStore.get(reference: builderReference, pull: false)
            let kernel = Kernel(path: options.kernel, platform: .linuxArm)
            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: "ghcr.io/apple/containerization/vminit@sha256:a69ff331d77997042afc3c7389969be176dfb657ec9ed46366c0e057ec40a297",
                imageStore: imageStore,
                network: nil
            )
            let builderID = "buildkit-\(options.id.lowercased())"
            var container: LinuxContainer?
            do {
                let created = try await manager.create(
                    builderID,
                    image: builderImage,
                    rootfsSizeInBytes: 16 * 1024 * 1024 * 1024,
                    networking: false
                ) { configuration in
                    configuration.cpus = 2
                    configuration.memoryInBytes = 2 * 1024 * 1024 * 1024
                    configuration.hostname = "buildkit"
                    configuration.interfaces = [
                        VmnetNetwork.Interface(
                            reference: self.networkReference,
                            ipv4Address: try CIDRv4(self.ipv4Address),
                            ipv4Gateway: try IPv4Address(self.ipv4Gateway),
                            macAddress: try MACAddress(self.macAddress),
                            mtu: self.mtu
                        )
                    ]
                    configuration.dns = DNS(nameservers: [self.ipv4Gateway])
                    configuration.process.arguments = [
                        "/usr/local/bin/container-builder-shim", "--debug", "--vsock", "--enable-qemu",
                    ]
                    configuration.process.capabilities = .allCapabilities
                    configuration.process.stdout = FileWriter(self.stderrHandle)
                    configuration.process.stderr = FileWriter(self.stderrHandle)
                    configuration.maskedPaths = []
                    configuration.readonlyPaths = []
                    configuration.mounts.append(.any(type: "tmpfs", source: "tmpfs", destination: "/run"))
                    configuration.mounts.append(.share(
                        source: exports.path,
                        destination: "/var/lib/container-builder-shim/exports"
                    ))
                }
                container = created
                try await created.create()
                try await created.start()
                lock.withLock { activeContainer = created }

                let client = try await connectBuilder(created)
                sendReady()
                let ignore = try? Data(contentsOf: context.appendingPathComponent(".dockerignore"))
                do {
                    try await client.build(GhostBuildKitConfiguration(
                        buildID: options.id,
                        imageStore: imageStore,
                        contentStore: contentStore,
                        contextDirectory: context,
                        dockerfile: options.dockerfile,
                        dockerignore: ignore,
                        buildArguments: options.buildArguments,
                        target: options.target,
                        tags: try options.tags.map(Self.normalizedReference),
                        noCache: options.noCache,
                        pull: options.pull,
                        output: stderrHandle
                    ))
                    await client.shutdown()
                } catch {
                    await client.shutdown()
                    throw error
                }

                try await created.stop()
                try manager.delete(builderID)
                container = nil
                lock.withLock { activeContainer = nil }

                let export = exports.appendingPathComponent("\(options.id)/out.tar")
                guard FileManager.default.fileExists(atPath: export.path) else {
                    throw RuntimeBuildError.missingExport(export.path)
                }
                try FileManager.default.createDirectory(at: ociLayout, withIntermediateDirectories: true)
                let rejectedExport = try ArchiveReader(file: export).extractContents(to: ociLayout)
                guard rejectedExport.isEmpty else {
                    throw RuntimeBuildError.rejectedArchive(rejectedExport.prefix(8).joined(separator: ", "))
                }
                let tags = try options.tags.map(Self.normalizedReference)
                // `ImageStore.load` creates the reference carried by the OCI
                // annotation and rejects an existing one. Docker tags are
                // replaceable, but retain their previous descriptions so a
                // malformed or failed import cannot destroy a runnable image.
                var previousImages: [Containerization.Image.Description] = []
                for tag in tags {
                    if let previous = try? await imageStore.get(reference: tag) {
                        previousImages.append(previous.description)
                    }
                    try? await imageStore.delete(reference: tag)
                }
                let image: Containerization.Image
                do {
                    let images = try await imageStore.load(from: ociLayout)
                    guard let loaded = images.first else { throw RuntimeBuildError.emptyExport }
                    let source = loaded.reference
                    for tag in tags where tag != source {
                        _ = try await imageStore.tag(existing: source, new: tag)
                    }
                    image = loaded
                } catch {
                    for tag in tags { try? await imageStore.delete(reference: tag) }
                    for description in previousImages {
                        _ = try? await imageStore.create(description: description)
                    }
                    throw error
                }
                let digest = image.descriptor.digest
                try stdoutHandle.write(contentsOf: Data("Successfully built \(digest)\n".utf8))
                for tag in tags {
                    try stdoutHandle.write(contentsOf: Data("Successfully tagged \(tag)\n".utf8))
                }
                return (0, nil)
            } catch {
                if let container { try? await container.stop() }
                try? manager.delete(builderID)
                throw error
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return (143, nil) }
            return (125, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    /// Cold builder startup can take well over 30 seconds while buildkitd
    /// initializes. Retry the complete dial + gRPC health probe for the same
    /// five-minute window used by Apple's `container build`, cleaning up every
    /// failed probe before trying again.
    private func connectBuilder(_ container: LinuxContainer) async throws -> GhostBuildKitClient {
        var lastError: Error?
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(300))
        while clock.now < deadline {
            try Task.checkCancellation()
            do {
                let socket = try await container.dialVsock(port: 8088)
                let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
                do {
                    let client = try await GhostBuildKitClient(socket: socket, group: group)
                    do {
                        try await client.info(timeout: .seconds(5))
                        return client
                    } catch {
                        lastError = error
                        await client.shutdown()
                    }
                } catch {
                    lastError = error
                    try? await group.shutdownGracefully()
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        if let lastError { throw lastError }
        throw RuntimeBuildError.builderUnavailable
    }

    private static func normalizedReference(_ raw: String) throws -> String {
        let reference = try Reference.parse(raw)
        reference.normalize()
        return reference.description
    }

    private func sendReady() {
        let event = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(event, ContainerRuntimeXPCProtocol.Key.operation, ContainerRuntimeXPCProtocol.Operation.ready)
        xpc_dictionary_set_string(event, ContainerRuntimeXPCProtocol.Key.runIdentifier, runIdentifier)
        xpc_connection_send_message(connection, event)
    }

    private func complete(exitCode: Int32, message: String?) {
        let shouldComplete = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            task = nil
            activeContainer = nil
            return true
        }
        guard shouldComplete else { return }
        if let message {
            try? stderrHandle.write(contentsOf: Data("ghostvm-container-runtime: \(message)\n".utf8))
        }
        releaseNetworkReference()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        let event = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(event, ContainerRuntimeXPCProtocol.Key.operation, ContainerRuntimeXPCProtocol.Operation.exit)
        xpc_dictionary_set_string(event, ContainerRuntimeXPCProtocol.Key.runIdentifier, runIdentifier)
        xpc_dictionary_set_int64(event, ContainerRuntimeXPCProtocol.Key.exitCode, Int64(exitCode))
        if let message { xpc_dictionary_set_string(event, ContainerRuntimeXPCProtocol.Key.error, message) }
        xpc_connection_send_message(connection, event)
        onComplete(self)
        xpc_transaction_end()
    }

    private func releaseNetworkReference() {
        let release = lock.withLock { () -> Bool in
            guard !networkReleased else { return false }
            networkReleased = true
            return true
        }
        if release { SharedVmnetNetwork.releaseVmnetReference(networkReference) }
    }

    deinit {
        releaseNetworkReference()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }
}
