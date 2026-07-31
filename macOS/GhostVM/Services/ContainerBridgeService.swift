import Foundation
import Virtualization
import GhostVMKit

/// Host-side listener for guest-initiated container control connections.
///
/// Registered on the VM's VZVirtioSocketDevice. When a guest process connects to
/// ContainerBridgeConstants.port, the service accepts the connection, reads one
/// versioned NDJSON request, submits it to the runtime XPC service via
/// ContainerRunner, and streams NDJSON response frames back. One request per
/// connection; at most `maxConcurrentConnections` simultaneous connections.
final class ContainerBridgeService: @unchecked Sendable {
    /// MVP invariant: one fetch/run chain per VM keeps Containerization's
    /// process-local image-store locking from becoming a cross-process race.
    static let maxConcurrentConnections = 1

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

    private let stateLock = NSLock()
    private var listener: VZVirtioSocketListener?
    private var listenerDelegate: BridgeListenerDelegate?
    private var isRunning = false
    private var activeCount = 0
    private var connections: [UUID: VZVirtioSocketConnection] = [:]
    private var writers: [UUID: VSockFrameWriter] = [:]
    private var runners: [UUID: ContainerRunner] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - vm: The running virtual machine (accessed only on `vmQueue`).
    ///   - vmQueue: The serial queue the VZVirtualMachine was created with.
    ///   - vmHash: Stable per-VM identifier used in generated container names.
    ///   - port: Vsock port to listen on.
    init(
        vm: VZVirtualMachine,
        vmQueue: DispatchQueue,
        vmHash: String,
        sharedNetwork: SharedVmnetNetwork,
        fileSystemBridge: GuestFileSystemBridgeService? = nil,
        port: UInt32 = ContainerBridgeConstants.port
    ) {
        self.vm = vm
        self.vmQueue = vmQueue
        self.vmHash = vmHash
        self.port = port
        self.fileSystemBridge = fileSystemBridge
        self.sharedNetwork = sharedNetwork
        self.runtimeClient = ContainerRuntimeXPCClient()
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

        // Listen even without the CLI so guests get a structured error frame
        // (executableNotFound) instead of a dead port.
        if !ContainerRunner.isExecutableAvailable {
            NSLog("ContainerBridge: %@ is unavailable on this host; bridge will still listen and return structured errors to guest requests", ContainerRunner.executablePath)
        }

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
        let activeRunners = Array(runners.values)
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
        for runner in activeRunners {
            runner.terminate()
        }
        runtimeClient.invalidate()
        NSLog("ContainerBridge: stopped (cancelled %d task(s), terminated %d run(s), signalled %d connection(s))", openTasks.count, activeRunners.count, openConnections.count)
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
            runners[id] = nil
            tasks[id] = nil
            activeCount -= 1
            stateLock.unlock()
        }

        var mountedVolumes: [GuestVolumeMount] = []
        var responseVersion = ContainerBridgeConstants.protocolVersion
        let inputRelay = InputRelayTracker()
        do {
            let (line, initialInput) = try await readRequestLine(channel: channel)
            let request = try ContainerRunRequest.decode(line: line)
            if (ContainerBridgeConstants.minimumProtocolVersion...ContainerBridgeConstants.protocolVersion).contains(request.version) {
                responseVersion = request.version
            }
            let run = try ContainerRunPolicy.validate(request)

            mountedVolumes = try await prepareVolumes(run.volumes)
            var arguments = run.containerArguments(vmHash: vmHash, uniqueSuffix: Self.makeNameSuffix())
            if let separator = arguments.firstIndex(of: "--") {
                for mount in mountedVolumes {
                    arguments.insert(
                        contentsOf: ["--mount", mount.mountPoint.path, mount.destination, mount.readOnly ? "ro" : "rw"],
                        at: separator
                    )
                }
            }
            let runner = ContainerRunner(
                runtimeIdentifier: vmHash,
                image: run.image,
                arguments: arguments,
                runtimeClient: runtimeClient,
                sharedNetwork: sharedNetwork
            )

            // Re-check isRunning atomically with registration: stop()
            // snapshots runners, so a runner registered after stop() began
            // would never be terminated by it.
            stateLock.lock()
            let stillRunning = isRunning
            if stillRunning {
                runners[id] = runner
            }
            stateLock.unlock()
            guard stillRunning else {
                runner.terminate()
                throw ContainerProtocolError.connectionClosed
            }

            NSLog("ContainerBridge: starting XPC runtime run (image=%@, %d command arg(s)) for connection %@", run.image, run.command.count, id.uuidString)

            let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
                do {
                    try runner.start(
                        onReady: {
                            Self.clearSocketReceiveTimeout(fd: connection.fileDescriptor)
                            let task = Task.detached {
                                if run.protocolVersion >= 2 {
                                    await Self.relayFramedInput(
                                        channel: channel,
                                        initialInput: initialInput,
                                        run: run,
                                        runner: runner,
                                        writer: writer
                                    )
                                } else if run.attachStdin {
                                    if !initialInput.isEmpty, !runner.writeStdin(initialInput) {
                                        runner.closeStdin()
                                        return
                                    }
                                    do {
                                        while let chunk = try await channel.read(maxBytes: 32 * 1024) {
                                            guard runner.writeStdin(chunk) else { break }
                                        }
                                    } catch {
                                        // Closing the connection during normal teardown wakes this read.
                                    }
                                    runner.closeStdin()
                                } else {
                                    runner.closeStdin()
                                }
                            }
                            inputRelay.set(task)
                        },
                        onOutput: { stream, data in
                            let response = (stream == .stdout)
                                ? ContainerResponse.stdout(data, version: run.protocolVersion)
                                : ContainerResponse.stderr(data, version: run.protocolVersion)
                            guard let frame = try? response.encodeLine() else { return }
                            if !writer.writeFrame(frame) {
                                // Guest went away; don't leave a container running.
                                runner.terminate()
                            }
                        },
                        onExit: { code in
                            continuation.resume(returning: code)
                        }
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            // Emitted only after both pipes drained (see ContainerRunner), so
            // the exit frame is always the last frame on the connection.
            try writer.writeFrameOrThrow(ContainerResponse.exit(exitCode, version: run.protocolVersion).encodeLine())
            NSLog("ContainerBridge: run finished (exit=%d) for connection %@", exitCode, id.uuidString)
            await releaseVolumes(&mountedVolumes)
        } catch {
            await releaseVolumes(&mountedVolumes)
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if let frame = try? ContainerResponse.error(message, version: responseVersion).encodeLine() {
                writer.writeFrame(frame)
            }
            NSLog("ContainerBridge: request failed: %@", message)
        }
        writer.shutdown()
        if let task = inputRelay.take() {
            await task.value
        }
    }

    private static func relayFramedInput(
        channel: BlockingVSockChannel,
        initialInput: Data,
        run: ValidatedContainerRun,
        runner: ContainerRunner,
        writer: VSockFrameWriter
    ) async {
        var buffer = initialInput
        var stdinClosed = !run.attachStdin
        if stdinClosed {
            runner.closeStdin()
        }

        do {
            while true {
                while let newline = buffer.firstIndex(of: 0x0A) {
                    guard newline - buffer.startIndex <= ContainerBridgeConstants.maxRequestLineBytes else {
                        throw ContainerProtocolError.requestTooLarge(limit: ContainerBridgeConstants.maxRequestLineBytes)
                    }
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let frame = try ContainerInputFrame.decode(line: line)
                    guard frame.version == run.protocolVersion else {
                        throw ContainerProtocolError.malformedInputFrame("input frame version does not match request")
                    }
                    switch frame.type {
                    case .stdin:
                        guard run.attachStdin, !stdinClosed,
                              let encoded = frame.data,
                              let data = Data(base64Encoded: encoded) else {
                            throw ContainerProtocolError.malformedInputFrame("invalid stdin frame")
                        }
                        guard runner.writeStdin(data) else { return }
                    case .stdinClose:
                        if !stdinClosed {
                            stdinClosed = true
                            runner.closeStdin()
                        }
                    case .resize:
                        guard run.allocateTTY,
                              let columns = frame.columns, columns > 0,
                              let rows = frame.rows, rows > 0 else {
                            throw ContainerProtocolError.malformedInputFrame("invalid resize frame")
                        }
                        runner.resize(columns: columns, rows: rows)
                    }
                }
                guard buffer.count <= ContainerBridgeConstants.maxRequestLineBytes else {
                    throw ContainerProtocolError.requestTooLarge(limit: ContainerBridgeConstants.maxRequestLineBytes)
                }
                guard let chunk = try await channel.read(maxBytes: 32 * 1024) else {
                    guard buffer.isEmpty else {
                        throw ContainerProtocolError.malformedInputFrame("connection closed during input frame")
                    }
                    break
                }
                buffer.append(chunk)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            if let frame = try? ContainerResponse.error(message, version: run.protocolVersion).encodeLine() {
                writer.writeFrame(frame)
            }
            runner.terminate()
        }
        runner.closeStdin()
    }

    private func prepareVolumes(_ volumes: [ContainerRunVolume]) async throws -> [GuestVolumeMount] {
        guard !volumes.isEmpty else { return [] }
        guard let fileSystemBridge else { throw GuestVolumeMount.MountError.bridgeUnavailable }

        var mounted: [GuestVolumeMount] = []
        do {
            for volume in volumes {
                let registered = try await MainActor.run {
                    try fileSystemBridge.registerExport(guestPath: volume.guestPath, readOnly: volume.readOnly)
                }
                do {
                    mounted.append(try GuestVolumeMount.mount(
                        registeredExport: registered,
                        destination: volume.destination,
                        readOnly: volume.readOnly,
                        rootURL: ContainerRunner.runtimeRootURL
                            .appendingPathComponent(vmHash, isDirectory: true)
                            .appendingPathComponent("mounts", isDirectory: true)
                    ))
                } catch {
                    await MainActor.run { fileSystemBridge.unregisterExport(id: registered.id) }
                    throw error
                }
            }
            return mounted
        } catch {
            await releaseVolumes(&mounted)
            throw error
        }
    }

    private func releaseVolumes(_ volumes: inout [GuestVolumeMount]) async {
        guard !volumes.isEmpty else { return }
        let mounted = volumes
        volumes.removeAll()
        for mount in mounted.reversed() {
            mount.unmount()
        }
        if let fileSystemBridge {
            await MainActor.run {
                for mount in mounted {
                    fileSystemBridge.unregisterExport(id: mount.exportID)
                }
            }
        }
    }

    /// Reads a single NDJSON request line, enforcing the size cap.
    private func readRequestLine(channel: BlockingVSockChannel) async throws -> (line: Data, initialInput: Data) {
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
                let inputStart = buffer.index(after: newline)
                return (
                    Data(buffer[buffer.startIndex..<newline]),
                    Data(buffer[inputStart..<buffer.endIndex])
                )
            }
            if buffer.count > ContainerBridgeConstants.maxRequestLineBytes {
                throw ContainerProtocolError.requestTooLarge(limit: ContainerBridgeConstants.maxRequestLineBytes)
            }
        }
    }

    /// The request header has a short timeout; attached stdin may remain idle
    /// for the full lifetime of an interactive process.
    private static func clearSocketReceiveTimeout(fd: Int32) {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length) != 0 {
            NSLog("ContainerBridge: failed to clear stdin receive timeout (errno=%d)", errno)
        }
    }

    private static func makeNameSuffix() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

private final class InputRelayTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        lock.withLock { self.task = task }
    }

    func take() -> Task<Void, Never>? {
        lock.withLock {
            let task = self.task
            self.task = nil
            return task
        }
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
