import Foundation
import GhostFileKit
import Virtualization
import GhostVMKit

/// Host-side listener for guest-initiated container control connections.
///
/// Registered on the VM's VZVirtioSocketDevice. When a guest process connects to
/// ContainerBridgeConstants.port, the service accepts the connection, reads one
/// direct API request, submits it to the runtime XPC service, and returns one
/// direct API response. One request is accepted per connection.
final class ContainerBridgeService: @unchecked Sendable {
    static let maxConcurrentConnections = 32

    /// SO_RCVTIMEO/SO_SNDTIMEO applied to accepted sockets: bounds slowloris
    /// request reads and frame writes blocked on a stalled guest. This is not
    /// a cap on total container runtime.
    private static let socketIOTimeoutSeconds = 15

    private let vm: VZVirtualMachine
    private let vmQueue: DispatchQueue
    private let vmHash: String
    private let port: UInt32
    private let fileSystemBridge: GuestFileSystemBridgeService?
    private let sharedNetwork: SharedVmnetNetwork
    private let runtimeClient: ContainerRuntimeXPCClient

    private struct PreparedGuestMount: Sendable {
        let volume: GuestVolumeMount
        let guestPath: String
    }

    private let mountLock = NSLock()
    private var guestMounts = GuestMountRegistry<PreparedGuestMount>()

    private let stateLock = NSLock()
    private var listener: VZVirtioSocketListener?
    private var listenerDelegate: BridgeListenerDelegate?
    private var isRunning = false
    private var activeCount = 0
    private var connections: [UUID: VZVirtioSocketConnection] = [:]
    private var writers: [UUID: VSockFrameWriter] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - vm: The running virtual machine (accessed only on `vmQueue`).
    ///   - vmQueue: The serial queue the VZVirtualMachine was created with.
    ///   - vmHash: Stable per-VM identifier used in generated container names.
    ///   - volumeRootURL: Trusted per-VM storage for persistent container volumes.
    ///   - port: Vsock port to listen on.
    init(
        vm: VZVirtualMachine,
        vmQueue: DispatchQueue,
        vmHash: String,
        sharedNetwork: SharedVmnetNetwork,
        volumeRootURL: URL,
        imageRootURL: URL,
        fileSystemBridge: GuestFileSystemBridgeService? = nil,
        port: UInt32 = ContainerBridgeConstants.port
    ) {
        self.vm = vm
        self.vmQueue = vmQueue
        self.vmHash = vmHash
        self.port = port
        self.fileSystemBridge = fileSystemBridge
        self.sharedNetwork = sharedNetwork
        self.runtimeClient = ContainerRuntimeXPCClient(
            sharedNetwork: sharedNetwork,
            volumeRootURL: volumeRootURL,
            imageRootURL: imageRootURL
        )
    }

    /// Registers the vsock listener on vmQueue. Safe to call once per VM run.
    public func start() {
        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = true
        let delegate = BridgeListenerDelegate { [weak self] connection in
            self?.accept(connection) ?? false
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = delegate
        // VZ does not retain the listener and its delegate property is weak,
        // so the service must retain both for the listener to keep firing.
        self.listener = listener
        self.listenerDelegate = delegate
        stateLock.unlock()

        vmQueue.async {
            guard let socketDevice = self.vm.socketDevices.first as? VZVirtioSocketDevice else {
                NSLog("ContainerBridge: no VZVirtioSocketDevice on this VM; listener not registered")
                return
            }
            socketDevice.setSocketListener(listener, forPort: self.port)
            NSLog("ContainerBridge: listening for guest container requests on vsock port %u (vm=%@)", self.port, self.vmHash)
        }
    }

    /// Idempotent: atomically flips to not-running and snapshots all
    /// per-connection state under one lock, then unwinds in order — cancel
    /// tasks, shut down frame writers (wakes blocked reads/writes), request
    /// runner termination. Each connection task closes its VZ connection only
    /// after its blocking input relay has observed shutdown and returned.
    public func stop() {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = false
        let registeredListener = self.listener
        let registeredDelegate = self.listenerDelegate
        self.listener = nil
        self.listenerDelegate = nil
        let openTasks = Array(tasks.values)
        let openWriters = Array(writers.values)
        let openConnections = connections
        stateLock.unlock()

        vmQueue.async {
            if let socketDevice = self.vm.socketDevices.first as? VZVirtioSocketDevice {
                socketDevice.removeSocketListener(forPort: self.port)
            }
            // VZ does not retain the listener and its delegate is weak. Keep both
            // alive until deregistration has completed on the VM queue.
            withExtendedLifetime((registeredListener, registeredDelegate)) {}
        }
        for task in openTasks {
            task.cancel()
        }
        for writer in openWriters {
            writer.shutdown()
        }
        runtimeClient.invalidate()
        let mounted = mountLock.withLock {
            guestMounts.removeAll()
        }
        for record in mounted.reversed() {
            record.volume.unmount()
        }
        if let fileSystemBridge, !mounted.isEmpty {
            Task { @MainActor in
                for record in mounted {
                    fileSystemBridge.unregisterExport(id: record.volume.exportID)
                }
            }
        }
        NSLog("ContainerBridge: stopped (cancelled %d task(s), signalled %d connection(s))", openTasks.count, openConnections.count)
    }

    /// Closes the connection exactly once: the `connections` dictionary entry
    /// is the ownership token — whichever path (stop or per-connection
    /// cleanup) removes it under the lock performs the close.
    private func closeConnectionOnce(id: UUID, connection: VZVirtioSocketConnection) {
        stateLock.lock()
        let owned = connections.removeValue(forKey: id) != nil
        stateLock.unlock()
        if owned {
            connection.close()
        }
    }

    // MARK: - Accept (called on vmQueue by VZ; must never block)

    private func accept(_ connection: VZVirtioSocketConnection) -> Bool {
        Self.applySocketTimeouts(fd: connection.fileDescriptor)
        let writer = VSockFrameWriter(fd: connection.fileDescriptor)

        stateLock.lock()
        guard isRunning, activeCount < Self.maxConcurrentConnections else {
            let running = isRunning
            let count = activeCount
            stateLock.unlock()
            NSLog("ContainerBridge: rejecting connection (isRunning=%d, active=%d/%d)", running ? 1 : 0, count, Self.maxConcurrentConnections)
            return false
        }
        activeCount += 1
        let id = UUID()
        connections[id] = connection
        writers[id] = writer
        // The task handle is registered before the lock is released and
        // per-connection cleanup also takes stateLock, so an early-finishing
        // task can never leave a stale entry behind.
        let task = Task.detached { [self] in
            await handleConnection(id: id, connection: connection, writer: writer)
        }
        tasks[id] = task
        stateLock.unlock()

        // The task retains `connection` for its whole IO lifetime; dropping it
        // would close the fd (VZ owns the descriptor).
        return true
    }

    /// Bounds request reads and blocked frame writes without capping total
    /// container runtime. Failure to set an option is logged, never fatal.
    private static func applySocketTimeouts(fd: Int32) {
        var timeout = timeval(tv_sec: socketIOTimeoutSeconds, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length) != 0 {
            NSLog("ContainerBridge: setsockopt(SO_RCVTIMEO) failed (errno=%d); continuing without a receive timeout", errno)
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length) != 0 {
            NSLog("ContainerBridge: setsockopt(SO_SNDTIMEO) failed (errno=%d); continuing without a send timeout", errno)
        }
    }

    // MARK: - Connection handling

    private func handleConnection(id: UUID, connection: VZVirtioSocketConnection, writer: VSockFrameWriter) async {
        // ownsFD: false — the VZ connection is the sole fd owner, so the
        // channel is never closed (that would double-close the descriptor).
        let channel = BlockingVSockChannel(fd: connection.fileDescriptor, ownsFD: false)
        defer {
            // Shut down raw writers BEFORE VZ closes the fd, so a stale write
            // can never land on a reused descriptor.
            writer.shutdown()
            closeConnectionOnce(id: id, connection: connection)
            stateLock.lock()
            writers[id] = nil
            tasks[id] = nil
            activeCount -= 1
            stateLock.unlock()
        }

        var requestID = "unknown"
        do {
            let line = try await readRequestLine(channel: channel)
            requestID = (try? JSONDecoder().decode(GhostboxDirectRequestEnvelope.self, from: line).id) ?? requestID
            let request = try GhostboxDirectRequest.decode(line: line)
            requestID = request.id
            guard request.version == ContainerBridgeConstants.protocolVersion,
                  request.operation == "direct",
                  !request.id.isEmpty else {
                throw ContainerProtocolError.malformedRequest(
                    "direct operations require protocol version \(ContainerBridgeConstants.protocolVersion) and a nonempty ID"
                )
            }
            guard GuestMountAccessPolicy.allowsGuestInvocation(request.method.rawValue) else {
                throw ContainerProtocolError.malformedRequest(
                    "method '\(request.method.rawValue)' cannot access outer-host paths; use mount guest-share"
                )
            }

            if Self.isAttachmentMethod(request.method) {
                Self.clearSocketTimeouts(fd: connection.fileDescriptor)
                try await runtimeClient.attach(payload: line, descriptor: connection.fileDescriptor)
                writer.shutdown()
                return
            }

            let response: GhostboxDirectResponse
            if request.method == .mountGuestShare {
                response = try await createGuestMount(request)
            } else if request.method == .mountDelete {
                response = try await invokeRuntime(request)
                if response.error == nil {
                    try await releaseGuestMount(parameters: request.parameters)
                }
            } else if request.method.rawValue == "mount.source",
                      let source = guestMountSource(parameters: request.parameters) {
                response = .success(id: request.id, value: .string(source))
            } else {
                response = try await invokeRuntime(request, payload: line)
            }
            guard response.version == request.version, response.id == request.id else {
                throw ContainerProtocolError.malformedRequest("runtime returned a mismatched direct response")
            }
            try writer.writeFrameOrThrow(response.encodeLine())
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if let frame = try? GhostboxDirectResponse.failure(
                id: requestID,
                code: .invalidArgument,
                message: message
            ).encodeLine() {
                _ = writer.writeFrame(frame)
            }
            NSLog("ContainerBridge: direct request failed: %@", message)
        }
        writer.shutdown()
    }

    // MARK: - Guest volume bridge

    /// Adapts the proven `-V` pipeline to a persistent Ghostbox mount object:
    /// guest path -> private GhostFile share -> outer-host FSKit mount -> Mount.share.
    private func createGuestMount(_ request: GhostboxDirectRequest) async throws -> GhostboxDirectResponse {
        let allowed: Set<String> = [
            "mount", "source", "destination", "readOnly", "cacheTTL", "option", "runtimeOption",
        ]
        guard request.parameters.keys.allSatisfy(allowed.contains) else {
            throw ContainerProtocolError.malformedRequest("mount.guestShare contains an unknown parameter")
        }
        let name = try Self.stringParameter("mount", in: request.parameters)
        guard Self.isReferenceComponent(name) else {
            throw ContainerProtocolError.malformedRequest("mount name is invalid")
        }
        let reference = "@mount/\(name)"
        let guestPath = try Self.stringParameter("source", in: request.parameters)
        guard guestPath.hasPrefix("/"), !guestPath.contains("\0"), guestPath.utf8.count <= 4096 else {
            throw ContainerProtocolError.malformedRequest("guest mount source must be an absolute path of at most 4096 bytes")
        }
        let destination = try Self.stringParameter("destination", in: request.parameters)
        guard Self.isContainerMountPath(destination), destination.utf8.count <= 4096 else {
            throw ContainerProtocolError.malformedRequest("guest mount destination must be an absolute non-root container path")
        }
        let readOnly = try Self.boolParameter("readOnly", in: request.parameters) ?? false
        let cacheTTL = try Self.unsignedIntegerParameter("cacheTTL", in: request.parameters)
            ?? GhostFileProtocol.defaultCacheTTLSeconds
        guard cacheTTL <= GhostFileProtocol.maximumCacheTTLSeconds else {
            throw ContainerProtocolError.malformedRequest(
                "guest mount cache TTL must be at most \(GhostFileProtocol.maximumCacheTTLSeconds) seconds"
            )
        }
        var options = try Self.stringArrayParameter("option", in: request.parameters) ?? []
        let runtimeOptions = try Self.stringArrayParameter("runtimeOption", in: request.parameters) ?? []
        if readOnly, !options.contains("ro") { options.append("ro") }
        guard let fileSystemBridge else { throw GuestVolumeMount.MountError.bridgeUnavailable }

        let reserved = mountLock.withLock { guestMounts.reserve(reference) }
        guard reserved else {
            throw ContainerProtocolError.malformedRequest("object '\(reference)' already exists")
        }
        defer {
            mountLock.withLock { guestMounts.abandon(reference) }
        }

        let registered = try await fileSystemBridge.registerExport(
            guestPath: guestPath,
            readOnly: readOnly,
            cacheTTLSeconds: cacheTTL
        )
        let volume: GuestVolumeMount
        do {
            volume = try GuestVolumeMount.mount(
                registeredExport: registered,
                destination: destination,
                readOnly: readOnly
            )
        } catch {
            await fileSystemBridge.unregisterExport(id: registered.id)
            throw error
        }

        let runtimeRequest = GhostboxDirectRequest(
            id: request.id,
            method: GhostboxDirectMethod(rawValue: "mount.share"),
            parameters: [
                "mount": .string(name),
                "source": .string(volume.mountPoint.path),
                "destination": .string(destination),
                "option": .array(options.map(GhostboxJSONValue.string)),
                "runtimeOption": .array(runtimeOptions.map(GhostboxJSONValue.string)),
            ]
        )
        let response: GhostboxDirectResponse
        do {
            response = try await invokeRuntime(runtimeRequest)
        } catch {
            volume.unmount()
            await fileSystemBridge.unregisterExport(id: registered.id)
            throw error
        }
        guard response.error == nil else {
            volume.unmount()
            await fileSystemBridge.unregisterExport(id: registered.id)
            return response
        }

        switch registerPreparedGuestMount(
            PreparedGuestMount(volume: volume, guestPath: guestPath),
            reference: reference
        ) {
        case .registered:
            return response
        case .deleted:
            volume.unmount()
            await fileSystemBridge.unregisterExport(id: registered.id)
            return .failure(
                id: request.id,
                code: .cancelled,
                message: "mount '\(reference)' was deleted while creation was in progress"
            )
        case .stopped:
            volume.unmount()
            await fileSystemBridge.unregisterExport(id: registered.id)
            throw ContainerProtocolError.connectionClosed
        }
    }

    private enum GuestMountRegistration {
        case registered
        case deleted
        case stopped
    }

    private func registerPreparedGuestMount(
        _ mount: PreparedGuestMount,
        reference: String
    ) -> GuestMountRegistration {
        stateLock.withLock {
            guard isRunning else { return .stopped }
            return mountLock.withLock {
                switch guestMounts.complete(reference, value: mount) {
                case .registered: return .registered
                case .deleted: return .deleted
                }
            }
        }
    }

    private func releaseGuestMount(parameters: [String: GhostboxJSONValue]) async throws {
        let reference = try Self.stringParameter("mount", in: parameters)
        guard reference.hasPrefix("@mount/") else {
            throw ContainerProtocolError.malformedRequest("mount.delete requires an @mount/NAME reference")
        }
        let record = mountLock.withLock { guestMounts.release(reference) }
        guard let record else { return }
        record.volume.unmount()
        if let fileSystemBridge {
            await fileSystemBridge.unregisterExport(id: record.volume.exportID)
        }
    }

    private func guestMountSource(parameters: [String: GhostboxJSONValue]) -> String? {
        guard case .string(let reference) = parameters["mount"] else { return nil }
        return mountLock.withLock { guestMounts[reference]?.guestPath }
    }

    func invokeRuntime(
        _ request: GhostboxDirectRequest,
        payload: Data? = nil
    ) async throws -> GhostboxDirectResponse {
        let encoded: Data
        if let payload {
            encoded = payload
        } else {
            encoded = try JSONEncoder().encode(request)
        }
        let responsePayload = try await runtimeClient.invoke(payload: encoded)
        return try JSONDecoder().decode(GhostboxDirectResponse.self, from: responsePayload)
    }

    private static func stringParameter(
        _ name: String,
        in parameters: [String: GhostboxJSONValue]
    ) throws -> String {
        guard case .string(let value) = parameters[name] else {
            throw ContainerProtocolError.malformedRequest("missing or invalid string parameter '\(name)'")
        }
        return value
    }

    private static func boolParameter(
        _ name: String,
        in parameters: [String: GhostboxJSONValue]
    ) throws -> Bool? {
        guard let raw = parameters[name] else { return nil }
        guard case .boolean(let value) = raw else {
            throw ContainerProtocolError.malformedRequest("parameter '\(name)' must be a boolean")
        }
        return value
    }

    private static func unsignedIntegerParameter(
        _ name: String,
        in parameters: [String: GhostboxJSONValue]
    ) throws -> UInt64? {
        guard let raw = parameters[name] else { return nil }
        guard case .unsignedInteger(let value) = raw else {
            throw ContainerProtocolError.malformedRequest("parameter '\(name)' must be an unsigned integer")
        }
        return value
    }

    private static func stringArrayParameter(
        _ name: String,
        in parameters: [String: GhostboxJSONValue]
    ) throws -> [String]? {
        guard let raw = parameters[name] else { return nil }
        guard case .array(let values) = raw else {
            throw ContainerProtocolError.malformedRequest("parameter '\(name)' must be an array")
        }
        return try values.map {
            guard case .string(let value) = $0 else {
                throw ContainerProtocolError.malformedRequest("parameter '\(name)' must contain strings")
            }
            return value
        }
    }

    private static func isReferenceComponent(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isContainerMountPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return path.hasPrefix("/") && path != "/" && !path.contains("\0")
            && !components.contains(where: { $0 == "." || $0 == ".." })
    }

    /// Reads a single NDJSON request line, enforcing the size cap.
    private func readRequestLine(channel: BlockingVSockChannel) async throws -> Data {
        var buffer = Data()
        while true {
            guard let chunk = try await channel.read(maxBytes: 4096) else {
                throw ContainerProtocolError.emptyRequest
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 0x0A) {
                // The cap applies even when the newline arrives beyond the limit.
                guard newline - buffer.startIndex <= ContainerBridgeConstants.maxRequestLineBytes else {
                    throw ContainerProtocolError.requestTooLarge(limit: ContainerBridgeConstants.maxRequestLineBytes)
                }
                return Data(buffer[buffer.startIndex..<newline])
            }
            if buffer.count > ContainerBridgeConstants.maxRequestLineBytes {
                throw ContainerProtocolError.requestTooLarge(limit: ContainerBridgeConstants.maxRequestLineBytes)
            }
        }
    }

    private static func isAttachmentMethod(_ method: GhostboxDirectMethod) -> Bool {
        [
            GhostboxDirectMethod.readerStreamAttachProxy,
            GhostboxDirectMethod.writerAttachProxy,
            GhostboxDirectMethod.terminalAttachProxy,
        ].contains(method)
    }

    private static func clearSocketTimeouts(fd: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length)
    }

}

// MARK: - VZ listener delegate adapter

/// VZVirtioSocketListener.delegate is weak and its callback arrives on the VM's
/// serial queue, so this adapter stays a small non-isolated forwarder.
private final class BridgeListenerDelegate: NSObject, VZVirtioSocketListenerDelegate {
    private let onConnection: (VZVirtioSocketConnection) -> Bool

    init(onConnection: @escaping (VZVirtioSocketConnection) -> Bool) {
        self.onConnection = onConnection
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        onConnection(connection)
    }
}

// MARK: - Frame writer

/// Serializes NDJSON frame writes from concurrent stdout/stderr/exit producers
/// onto one dedicated queue using a blocking Darwin write loop, so frames can
/// never interleave. Callers are private runner/connection threads — never
/// vmQueue or the main thread.
private final class VSockFrameWriter: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "org.ghostvm.containerbridge.writer")
    private let closedLock = NSLock()
    private var isClosed = false // closedLock-confined

    init(fd: Int32) {
        self.fd = fd
    }

    /// Writes one complete frame atomically. Returns false if the fd is dead
    /// (EPIPE/EBADF etc. — SIGPIPE is ignored by the host apps).
    @discardableResult
    func writeFrame(_ data: Data) -> Bool {
        queue.sync {
            closedLock.lock()
            let closed = isClosed
            closedLock.unlock()
            if closed { return false }

            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { ptr in
                    Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                closedLock.lock()
                isClosed = true
                closedLock.unlock()
                return false
            }
            return true
        }
    }

    func writeFrameOrThrow(_ data: Data) throws {
        guard writeFrame(data) else {
            throw ContainerProtocolError.connectionClosed
        }
    }

    /// Marks the writer closed and shuts the socket down both ways, waking any
    /// thread blocked in read/write so cleanup can proceed. Never closes the
    /// fd (VZ owns it) and never touches `queue`, so it cannot deadlock behind
    /// a blocked write. Safe to call multiple times.
    func shutdown() {
        closedLock.lock()
        isClosed = true
        closedLock.unlock()
        // shutdown(2) is idempotent enough for cleanup and must run even if a
        // prior write marked the writer closed, because the read side may still
        // be blocked on the same socket.
        Darwin.shutdown(fd, SHUT_RDWR)
    }
}
