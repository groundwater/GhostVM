// Parts of this file follow Apple's ContainerBuild 1.2.0 protocol client.
// Copyright © 2025-2026 Apple Inc. and the container project authors.
// Licensed under the Apache License, Version 2.0.

import ContainerAPIClient
import ContainerBuild
import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import NIO
import NIOPosix

struct GhostBuildKitConfiguration: Sendable {
    let buildID: String
    let imageStore: ImageStore
    let contentStore: ContentStore
    let contextDirectory: URL
    let dockerfile: Data
    let dockerignore: Data?
    let buildArguments: [String]
    let target: String
    let tags: [String]
    let noCache: Bool
    let pull: Bool
    let output: FileHandle
}

/// A GhostVM-specific client for Apple's builder shim. ContainerBuild's stock
/// pipeline resolves images through Apple's container service; GhostVM instead
/// resolves them directly against the per-VM ImageStore.
final class GhostBuildKitClient: @unchecked Sendable {
    private let client: Com_Apple_Container_Build_V1_Builder.Client<HTTP2ClientTransport.WrappedChannel>
    private let grpcClient: GRPCClient<HTTP2ClientTransport.WrappedChannel>
    private let group: EventLoopGroup
    private let clientTask: Task<Void, any Swift.Error>
    // NIO is initialized from the descriptor, so retain its owning FileHandle
    // for the entire channel lifetime just as Apple's Builder does.
    private let builderSocket: FileHandle
    private let shutdownLock = NSLock()
    private var hasShutdown = false

    init(socket: FileHandle, group: EventLoopGroup) async throws {
        try socket.setGhostSocketOption(SO_SNDBUF, bytes: 4 << 20)
        try socket.setGhostSocketOption(SO_RCVBUF, bytes: 2 << 20)
        let transport = try await HTTP2ClientTransport.WrappedChannel.wrapping(
            config: .defaults,
            serviceConfig: .init()
        ) { configure in
            try await withCheckedThrowingContinuation { continuation in
                ClientBootstrap(group: group)
                    .channelInitializer { channel in
                        configure(channel).map { configured in
                            continuation.resume(returning: configured)
                        }
                    }
                    .withConnectedSocket(socket.fileDescriptor)
                    .whenFailure { error in continuation.resume(throwing: error) }
            }
        }
        let grpcClient = GRPCClient(transport: transport)
        self.grpcClient = grpcClient
        self.client = Com_Apple_Container_Build_V1_Builder.Client(wrapping: grpcClient)
        self.group = group
        self.builderSocket = socket
        self.clientTask = Task { try await grpcClient.runConnections() }
    }

    func info(timeout: Duration = .seconds(30)) async throws {
        var options = CallOptions.defaults
        options.timeout = timeout
        _ = try await client.info(InfoRequest(), options: options)
    }

    func build(_ configuration: GhostBuildKitConfiguration) async throws {
        var continuation: AsyncStream<ClientStream>.Continuation?
        let requests = AsyncStream<ClientStream> { continuation = $0 }
        guard let continuation else { throw GhostBuildKitError.invalidContinuation }
        defer { continuation.finish() }

        let pipeline = try await GhostBuildPipeline(configuration)
        do {
            try await client.performBuild(
                metadata: try Self.metadata(configuration),
                options: .defaults,
                requestProducer: { writer in
                    for await message in requests { try await writer.write(message) }
                },
                onResponse: { response in
                    try await pipeline.run(sender: continuation, receiver: response.messages)
                }
            )
        } catch { throw error }
    }

    /// Idempotently tears down the connection task and event-loop resources.
    /// This is deliberately separate from `build` so failed readiness probes
    /// receive the same cleanup as completed builds.
    func shutdown() async {
        let shouldShutdown = shutdownLock.withLock { () -> Bool in
            guard !hasShutdown else { return false }
            hasShutdown = true
            return true
        }
        guard shouldShutdown else { return }
        grpcClient.beginGracefulShutdown()
        clientTask.cancel()
        try? await group.shutdownGracefully()
        _ = builderSocket
    }

    private static func metadata(_ configuration: GhostBuildKitConfiguration) throws -> Metadata {
        var metadata = Metadata()
        metadata.addString(configuration.buildID, forKey: "build-id")
        metadata.addString(configuration.contextDirectory.path, forKey: "context")
        metadata.addString(configuration.dockerfile.base64EncodedString(), forKey: "dockerfile")
        metadata.addString("plain", forKey: "progress")
        metadata.addString(configuration.target, forKey: "target")
        metadata.addString("linux/arm64", forKey: "platforms")
        metadata.addString("type=oci", forKey: "outputs")
        if let dockerignore = configuration.dockerignore {
            metadata.addString(dockerignore.base64EncodedString(), forKey: "dockerignore")
        }
        for tag in configuration.tags { metadata.addString(tag, forKey: "tag") }
        for argument in configuration.buildArguments { metadata.addString(argument, forKey: "build-args") }
        if configuration.noCache { metadata.addString("", forKey: "no-cache") }
        return metadata
    }
}

private protocol GhostBuildPipelineHandler: Sendable {
    func accepts(_ packet: ServerStream) -> Bool
    func handle(_ sender: AsyncStream<ClientStream>.Continuation, packet: ServerStream) async throws
}

private actor GhostBuildPipeline {
    private let handlers: [any GhostBuildPipelineHandler]

    init(_ configuration: GhostBuildKitConfiguration) async throws {
        handlers = [
            try GhostBuildFSSync(configuration.contextDirectory),
            GhostBuildContentProxy(configuration.contentStore),
            GhostBuildImageResolver(
                imageStore: configuration.imageStore,
                contentStore: configuration.contentStore,
                pull: configuration.pull
            ),
            GhostBuildStdio(output: configuration.output),
        ]
    }

    func run<S: AsyncSequence & Sendable>(
        sender: AsyncStream<ClientStream>.Continuation,
        receiver: S
    ) async throws where S.Element == ServerStream {
        defer { sender.finish() }
        for try await packet in receiver {
            try Task.checkCancellation()
            if case .buildError(let error)? = packet.packetType {
                throw GhostBuildKitError.buildFailed(error.message)
            }
            if case .commandComplete? = packet.packetType { continue }
            for handler in handlers where handler.accepts(packet) {
                try await handler.handle(sender, packet: packet)
                break
            }
        }
    }
}

private actor GhostBuildFSSync: GhostBuildPipelineHandler {
    private let context: URL

    init(_ context: URL) throws {
        let resolved = context.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw GhostBuildKitError.invalidContext(resolved.path)
        }
        self.context = resolved
    }

    nonisolated func accepts(_ packet: ServerStream) -> Bool {
        packet.ghostBuildTransfer?.metadata["stage"] == "fssync"
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, packet: ServerStream) async throws {
        guard let transfer = packet.ghostBuildTransfer,
              let method = transfer.metadata["method"] else {
            throw GhostBuildKitError.protocolFailure("fssync request is missing metadata")
        }
        switch method {
        case "Read": try read(sender, request: transfer, buildID: packet.buildID)
        case "Info": try info(sender, request: transfer, buildID: packet.buildID)
        case "Walk": try await walk(sender, request: transfer, buildID: packet.buildID)
        default: throw GhostBuildKitError.protocolFailure("unknown fssync method \(method)")
        }
    }

    private func read(
        _ sender: AsyncStream<ClientStream>.Continuation,
        request: BuildTransfer,
        buildID: String
    ) throws {
        let path = try safePath(request.source)
        let offset = UInt64(request.metadata["offset"] ?? "0") ?? 0
        let length = Int(request.metadata["length"] ?? "0") ?? 0
        let content = try LocalContent(path: path)
        let data = try content.data(offset: offset, length: length) ?? Data()
        sender.yield(response(
            buildID: buildID,
            transfer: try makePathTransfer(path, id: request.id, complete: true, data: data)
        ))
    }

    private func info(
        _ sender: AsyncStream<ClientStream>.Continuation,
        request: BuildTransfer,
        buildID: String
    ) throws {
        let path = try safePath(request.source)
        sender.yield(response(
            buildID: buildID,
            transfer: try makePathTransfer(path, id: request.id, complete: true)
        ))
    }

    /// The guest already supplied a bounded tar context. The shim applies
    /// Dockerignore and COPY follow-path filtering after receiving this stream,
    /// so sending the complete context is correct (and trades bandwidth for a
    /// substantially smaller trusted host implementation).
    private func walk(
        _ sender: AsyncStream<ClientStream>.Continuation,
        request: BuildTransfer,
        buildID: String
    ) async throws {
        if request.metadata["mode"] != "tar" {
            let infos = try allContextURLs().map { try GhostFileInfo(url: $0, relativeTo: context) }
            let transfer = makeTransfer(
                id: request.id,
                source: request.source,
                complete: true,
                metadata: ["os": "linux", "stage": "fssync", "mode": "json"],
                data: try JSONEncoder().encode(infos)
            )
            sender.yield(response(buildID: buildID, transfer: transfer))
            return
        }

        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostvm-context-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        let digest = try Archiver.compress(
            source: context,
            destination: archive,
            writerConfiguration: ArchiveWriterConfiguration(format: .paxRestricted, filter: .none)
        ) { url in
            guard let relative = url.ghostRelativePath(to: context) else { return nil }
            return Archiver.ArchiveEntryInfo(
                pathOnHost: url,
                pathInArchive: URL(fileURLWithPath: relative)
            )
        }
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        sender.yield(response(buildID: buildID, transfer: makeTransfer(
            id: request.id,
            source: archive.path,
            complete: false,
            metadata: ["os": "linux", "stage": "fssync", "mode": "tar", "hash": hash]
        )))

        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            sender.yield(response(buildID: buildID, transfer: makeTransfer(
                id: request.id,
                source: archive.path,
                complete: false,
                metadata: ["os": "linux", "stage": "fssync", "mode": "tar"],
                data: data
            )))
        }
        sender.yield(response(buildID: buildID, transfer: makeTransfer(
            id: request.id,
            source: archive.path,
            complete: true,
            metadata: ["os": "linux", "stage": "fssync", "mode": "tar"],
            data: Data()
        )))
    }

    private func safePath(_ source: String) throws -> URL {
        let candidate = source.hasPrefix("/")
            ? URL(fileURLWithPath: source)
            : context.appendingPathComponent(source)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.ghostIsDescendant(of: context) else {
            throw GhostBuildKitError.protocolFailure("context path escapes build root")
        }
        return resolved
    }

    private func allContextURLs() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: context,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
    }

    private func makePathTransfer(_ path: URL, id: String, complete: Bool, data: Data = Data()) throws -> BuildTransfer {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        let relative = path.ghostRelativePath(to: context) ?? ""
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        let uid = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
        let gid = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? 0
        let date = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        return makeTransfer(
            id: id,
            source: relative,
            complete: complete,
            isDirectory: (attributes[.type] as? FileAttributeType) == .typeDirectory,
            metadata: [
                "os": "linux", "stage": "fssync", "mode": String(mode),
                "size": String(size), "modified_at": date.ghostRFC3339,
                "uid": String(uid), "gid": String(gid),
            ],
            data: data
        )
    }

    private func response(buildID: String, transfer: BuildTransfer) -> ClientStream {
        var response = ClientStream()
        response.buildID = buildID
        response.buildTransfer = transfer
        return response
    }
}

private struct GhostFileInfo: Codable {
    let name: String
    let modTime: String
    let mode: UInt32
    let size: UInt64
    let isDir: Bool
    let uid: UInt32
    let gid: UInt32
    let target: String

    init(url: URL, relativeTo context: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        name = url.ghostRelativePath(to: context) ?? ""
        modTime = ((attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)).ghostRFC3339
        mode = (attributes[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        isDir = (attributes[.type] as? FileAttributeType) == .typeDirectory
        uid = 0
        gid = 0
        target = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            ? try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            : ""
    }
}

private struct GhostBuildContentProxy: GhostBuildPipelineHandler {
    let contentStore: ContentStore

    init(_ contentStore: ContentStore) { self.contentStore = contentStore }

    func accepts(_ packet: ServerStream) -> Bool {
        packet.ghostImageTransfer?.metadata["stage"] == "content-store"
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, packet: ServerStream) async throws {
        guard let request = packet.ghostImageTransfer,
              let method = request.metadata["method"] else {
            throw GhostBuildKitError.protocolFailure("content-store request is missing metadata")
        }
        var transfer = ImageTransfer()
        transfer.id = request.id
        transfer.tag = request.tag
        transfer.direction = .into
        transfer.complete = true
        transfer.metadata = ["os": "linux", "stage": "content-store", "method": method]
        switch method {
        case "/containerd.services.content.v1.Content/Info":
            let content = try await contentStore.get(digest: request.tag)
            if let content { transfer.metadata["size"] = String(try content.size()) }
        case "/containerd.services.content.v1.Content/ReaderAt":
            guard let content = try await contentStore.get(digest: request.descriptor.digest) else {
                throw GhostBuildKitError.protocolFailure("requested image content is missing")
            }
            let offset = UInt64(request.metadata["offset"] ?? "0") ?? 0
            let length = Int(request.metadata["length"] ?? "0") ?? 0
            if offset == 0 && length == 0 {
                transfer.metadata["size"] = String(try content.size())
            } else {
                transfer.data = try content.data(offset: offset, length: length) ?? Data()
                transfer.metadata["size"] = String(transfer.data.count)
            }
        default:
            throw GhostBuildKitError.protocolFailure("unsupported content-store method \(method)")
        }
        var response = ClientStream()
        response.buildID = packet.buildID
        response.imageTransfer = transfer
        sender.yield(response)
    }
}

private struct GhostBuildImageResolver: GhostBuildPipelineHandler {
    let imageStore: ImageStore
    let contentStore: ContentStore
    let pull: Bool

    func accepts(_ packet: ServerStream) -> Bool {
        packet.ghostImageTransfer?.metadata["stage"] == "resolver"
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, packet: ServerStream) async throws {
        guard let request = packet.ghostImageTransfer,
              request.metadata["method"] == "/resolve",
              let rawReference = request.metadata["ref"],
              let rawPlatform = request.metadata["platform"] else {
            throw GhostBuildKitError.protocolFailure("resolver request is missing metadata")
        }
        let platform = try Platform(from: rawPlatform)
        var parsed = try Reference.parse(rawReference)
        if parsed.domain == nil {
            parsed = try Reference.parse("registry-1.docker.io/\(rawReference)")
        }
        parsed.normalize()
        let reference = parsed.description
        let image: Containerization.Image
        if pull {
            image = try await imageStore.pull(reference: reference, platform: platform)
        } else {
            do {
                image = try await imageStore.get(reference: reference)
            } catch {
                image = try await imageStore.pull(reference: reference, platform: platform)
            }
        }
        let manifest = try await image.manifest(for: platform)
        guard let config: ContainerizationOCI.Image = try await contentStore.get(digest: manifest.config.digest) else {
            throw GhostBuildKitError.protocolFailure("base image config is missing")
        }
        var transfer = ImageTransfer()
        transfer.id = request.id
        transfer.tag = image.descriptor.digest
        transfer.direction = .into
        transfer.complete = true
        transfer.data = try JSONEncoder().encode(config)
        transfer.metadata = [
            "os": "linux", "stage": "resolver", "method": "/resolve",
            "ref": rawReference, "platform": platform.description,
        ]
        var response = ClientStream()
        response.buildID = packet.buildID
        response.imageTransfer = transfer
        sender.yield(response)
    }
}

private struct GhostBuildStdio: GhostBuildPipelineHandler {
    let output: FileHandle

    func accepts(_ packet: ServerStream) -> Bool {
        if case .io? = packet.packetType { return true }
        return false
    }

    func handle(_ sender: AsyncStream<ClientStream>.Continuation, packet: ServerStream) async throws {
        guard case .io(let io)? = packet.packetType else { return }
        try output.write(contentsOf: io.data)
        var acknowledgement = ClientStream()
        acknowledgement.buildID = packet.buildID
        acknowledgement.command = .init()
        acknowledgement.command.id = packet.buildID
        acknowledgement.command.command = try GhostTerminalCommand().encoded()
        sender.yield(acknowledgement)
    }
}

private struct GhostTerminalCommand: Codable {
    let commandType = "terminal"
    let code = "ack"
    let rows: UInt16 = 0
    let cols: UInt16 = 0

    enum CodingKeys: String, CodingKey {
        case commandType = "command_type"
        case code, rows, cols
    }

    func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

private func makeTransfer(
    id: String,
    source: String,
    complete: Bool,
    isDirectory: Bool = false,
    metadata: [String: String],
    data: Data = Data()
) -> BuildTransfer {
    var transfer = BuildTransfer()
    transfer.id = id
    transfer.source = source
    transfer.direction = .outof
    transfer.complete = complete
    transfer.isDirectory = isDirectory
    transfer.metadata = metadata
    transfer.data = data
    return transfer
}

private extension ServerStream {
    var ghostBuildTransfer: BuildTransfer? {
        if case .buildTransfer(let transfer)? = packetType { return transfer }
        return nil
    }

    var ghostImageTransfer: ImageTransfer? {
        if case .imageTransfer(let transfer)? = packetType { return transfer }
        return nil
    }
}

private extension URL {
    func ghostIsDescendant(of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let ownComponents = standardizedFileURL.pathComponents
        return ownComponents.count >= rootComponents.count
            && zip(rootComponents, ownComponents).allSatisfy(==)
    }

    func ghostRelativePath(to root: URL) -> String? {
        guard ghostIsDescendant(of: root) else { return nil }
        return pathComponents.dropFirst(root.standardizedFileURL.pathComponents.count).joined(separator: "/")
    }
}

private extension Date {
    var ghostRFC3339: String {
        ISO8601DateFormatter().string(from: self)
    }
}

private extension FileHandle {
    func setGhostSocketOption(_ option: Int32, bytes: Int) throws {
        var value = Int32(bytes)
        guard setsockopt(fileDescriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

enum GhostBuildKitError: Error, LocalizedError {
    case invalidContinuation
    case invalidContext(String)
    case protocolFailure(String)
    case buildFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidContinuation: return "failed to initialize the BuildKit request stream"
        case .invalidContext(let path): return "invalid build context at \(path)"
        case .protocolFailure(let detail): return "BuildKit protocol error: \(detail)"
        case .buildFailed(let message): return message.isEmpty ? "BuildKit build failed" : message
        }
    }
}
