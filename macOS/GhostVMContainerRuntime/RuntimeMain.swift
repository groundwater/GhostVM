import Containerization
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import GhostVMKit
import XPC
import vmnet

// The shared protocol constants live as nested types on ContainerRuntimeXPCProtocol;
// pull them into file-local aliases (shadowing Foundation.Operation) for readability.
private typealias Key = ContainerRuntimeXPCProtocol.Key
private typealias Operation = ContainerRuntimeXPCProtocol.Operation

private struct RuntimeOptions {
    struct Mount {
        let source: String
        let destination: String
        let readOnly: Bool
    }

    let root: URL
    let kernel: URL
    let id: String
    let image: String
    let networkIdentifier: String?
    let interactive: Bool
    let tty: Bool
    let terminalColumns: UInt16
    let terminalRows: UInt16
    let mounts: [Mount]
    let environment: [String]
    let workingDirectory: String?
    let user: String?
    let cpus: Int
    let memoryBytes: UInt64
    let command: [String]

    static func parse(_ arguments: [String]) throws -> RuntimeOptions {
        guard arguments.first == "run" else {
            throw RuntimeError.usage
        }

        var root: String?
        var kernel: String?
        var id: String?
        var image: String?
        var networkIdentifier: String?
        var interactive = false
        var tty = false
        var terminalColumns: UInt16 = 80
        var terminalRows: UInt16 = 24
        var mounts: [Mount] = []
        var environment: [String] = []
        var workingDirectory: String?
        var user: String?
        var cpus = 2
        var memoryBytes: UInt64 = 1024 * 1024 * 1024
        var command: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                command = Array(arguments.dropFirst(index + 1))
                break
            }
            switch argument {
            case "-i", "--interactive":
                interactive = true
                index += 1
                continue
            case "-t", "--tty":
                tty = true
                index += 1
                continue
            case "-it", "-ti":
                interactive = true
                tty = true
                index += 1
                continue
            case "--tty-size":
                guard index + 2 < arguments.count,
                      let columns = UInt16(arguments[index + 1]), columns > 0,
                      let rows = UInt16(arguments[index + 2]), rows > 0 else {
                    throw RuntimeError.usage
                }
                terminalColumns = columns
                terminalRows = rows
                index += 3
                continue
            case "--mount":
                guard index + 3 < arguments.count else {
                    throw RuntimeError.usage
                }
                let source = arguments[index + 1]
                let destination = arguments[index + 2]
                let mode = arguments[index + 3]
                let destinationParts = destination.split(separator: "/", omittingEmptySubsequences: true)
                guard
                    source.hasPrefix("/"),
                    destination.hasPrefix("/"),
                    destination != "/",
                    !source.contains("\0"),
                    !destination.contains("\0"),
                    !destinationParts.contains(where: { $0 == "." || $0 == ".." }),
                    mode == "ro" || mode == "rw",
                    mounts.count < 32,
                    !mounts.contains(where: { $0.destination == destination })
                else {
                    throw RuntimeError.invalidMount(source: source, destination: destination, mode: mode)
                }
                mounts.append(Mount(source: source, destination: destination, readOnly: mode == "ro"))
                index += 4
                continue
            default:
                break
            }
            guard index + 1 < arguments.count else {
                throw RuntimeError.usage
            }
            let value = arguments[index + 1]
            switch argument {
            case "--root": root = value
            case "--kernel": kernel = value
            case "--id": id = value
            case "--image": image = value
            case "--network-id": networkIdentifier = value
            case "--env": environment.append(value)
            case "--workdir": workingDirectory = value
            case "--user": user = value
            case "--cpus":
                guard let parsed = Int(value), parsed > 0 else { throw RuntimeError.usage }
                cpus = parsed
            case "--memory-bytes":
                guard let parsed = UInt64(value), parsed > 0 else { throw RuntimeError.usage }
                memoryBytes = parsed
            default: throw RuntimeError.usage
            }
            index += 2
        }

        guard let root, let kernel, let id, let image else {
            throw RuntimeError.usage
        }
        return RuntimeOptions(
            root: URL(fileURLWithPath: root, isDirectory: true),
            kernel: URL(fileURLWithPath: kernel),
            id: id,
            image: image,
            networkIdentifier: networkIdentifier,
            interactive: interactive,
            tty: tty,
            terminalColumns: terminalColumns,
            terminalRows: terminalRows,
            mounts: mounts,
            environment: environment,
            workingDirectory: workingDirectory,
            user: user,
            cpus: cpus,
            memoryBytes: memoryBytes,
            command: command
        )
    }
}

private enum RuntimeError: Error, LocalizedError {
    case usage
    case kernelNotFound(String)
    case invalidMount(source: String, destination: String, mode: String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: ghostvm-container-runtime run [-i|--interactive] [-t|--tty] [--tty-size COLUMNS ROWS] [--env NAME=VALUE] [--workdir PATH] [--user USER] [--cpus COUNT] [--memory-bytes BYTES] --root PATH --kernel PATH --id ID --image IMAGE [--network-id ID] [--mount HOST_PATH CONTAINER_PATH ro|rw] [-- COMMAND...]"
        case .kernelNotFound(let path):
            return "container kernel not found at \(path); the image fetch helper must prepare runtime assets first"
        case .invalidMount(let source, let destination, let mode):
            return "invalid mount: source='\(source)' destination='\(destination)' mode='\(mode)'"
        }
    }
}

private final class FileWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func close() throws {}
}

private final class FileHandleReaderStream: ReaderStream, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func stream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { [handle] _ in
                handle.readabilityHandler = nil
            }
        }
    }
}

/// A single registered container run. Owns the reconstructed vmnet reference and
/// the duplicated stdio file descriptors for its lifetime, guarantees exactly-once
/// completion, and balances the XPC transaction that keeps the service alive.
private final class RunContext: @unchecked Sendable {
    private weak var broker: RuntimeBroker?
    let connection: xpc_connection_t
    let runIdentifier: String
    private let options: RuntimeOptions
    private let networkReference: vmnet_network_ref
    private let ipv4Address: String
    private let ipv4Gateway: String
    private let macAddress: String
    private let mtu: UInt32
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle

    private let stateLock = NSLock()
    private var registered = false
    private var cancelled = false
    private var completed = false
    private var networkReleased = false
    private var task: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var activeContainer: LinuxContainer?
    private var pendingTerminalSize: (columns: UInt16, rows: UInt16)?

    init(
        broker: RuntimeBroker,
        connection: xpc_connection_t,
        runIdentifier: String,
        options: RuntimeOptions,
        networkReference: vmnet_network_ref,
        ipv4Address: String,
        ipv4Gateway: String,
        macAddress: String,
        mtu: UInt32,
        stdinHandle: FileHandle,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle
    ) {
        self.broker = broker
        self.connection = connection
        self.runIdentifier = runIdentifier
        self.options = options
        self.networkReference = networkReference
        self.ipv4Address = ipv4Address
        self.ipv4Gateway = ipv4Gateway
        self.macAddress = macAddress
        self.mtu = mtu
        self.stdinHandle = stdinHandle
        self.stdoutHandle = stdoutHandle
        self.stderrHandle = stderrHandle
    }

    func markRegistered() {
        stateLock.lock()
        registered = true
        stateLock.unlock()
    }

    func sendReady() {
        let event = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(event, Key.operation, Operation.ready)
        xpc_dictionary_set_string(event, Key.runIdentifier, runIdentifier)
        xpc_connection_send_message(connection, event)
        log("runtime[\(getpid())]: run '\(runIdentifier)' ready (container '\(options.id)')")
    }

    func setTask(_ task: Task<Void, Never>) {
        stateLock.lock()
        let alreadyCompleted = completed
        if !alreadyCompleted {
            self.task = task
        }
        let shouldCancel = cancelled || alreadyCompleted
        stateLock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func cancelTask() {
        stateLock.lock()
        cancelled = true
        let current = task
        stateLock.unlock()
        current?.cancel()
        log("runtime[\(getpid())]: run '\(runIdentifier)' cancel requested")
    }

    func resize(columns: UInt16, rows: UInt16) {
        stateLock.lock()
        pendingTerminalSize = (columns, rows)
        let container = activeContainer
        let shouldResize = options.tty && !completed
        let previousResize = resizeTask
        let nextResize: Task<Void, Never>?
        if shouldResize, let container {
            nextResize = Task {
                await previousResize?.value
                try? await container.resize(to: Terminal.Size(width: columns, height: rows))
            }
            resizeTask = nextResize
        } else {
            nextResize = nil
        }
        stateLock.unlock()
        _ = nextResize
    }

    /// Runs the create/start/wait/stop/delete flow and returns the exit code plus an
    /// optional localized failure message to emit on the supplied stderr. Cancellation
    /// is reported as 143 with no message; other failures as 125 with the message.
    func runContainer() async -> (exitCode: Int32, message: String?) {
        do {
            guard FileManager.default.isReadableFile(atPath: options.kernel.path) else {
                throw RuntimeError.kernelNotFound(options.kernel.path)
            }

            let reference = try Reference.parse(options.image)
            reference.normalize()
            let normalizedImage = reference.description
            let imageStore = try ImageStore(path: options.root)

            // The short-lived fetch helper is the only image-store writer.
            let image = try await imageStore.get(reference: normalizedImage, pull: false)
            let kernel = Kernel(path: options.kernel, platform: .linuxArm)
            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: "ghcr.io/apple/containerization/vminit:0.40.1",
                imageStore: imageStore,
                network: nil
            )

            var container: LinuxContainer?
            do {
                let created = try await manager.create(
                    options.id,
                    image: image,
                    rootfsSizeInBytes: 2 * 1024 * 1024 * 1024,
                    networking: false
                ) { configuration in
                    try self.configureContainer(&configuration)
                }
                container = created
                try await created.create()
                try await created.start()
                let terminalSize = stateLock.withLock {
                    activeContainer = created
                    return pendingTerminalSize ?? (options.terminalColumns, options.terminalRows)
                }
                if options.tty {
                    try await created.resize(to: Terminal.Size(width: terminalSize.0, height: terminalSize.1))
                }
                sendReady()
                let status = try await withTaskCancellationHandler {
                    try await created.wait()
                } onCancel: {
                    Task { try? await created.stop() }
                }
                if Task.isCancelled {
                    try? await created.stop()
                    try? manager.delete(options.id)
                    return (143, nil)
                }
                try await created.stop()
                try manager.delete(options.id)
                return (status.exitCode, nil)
            } catch {
                if let container { try? await container.stop() }
                try? manager.delete(options.id)
                throw error
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                return (143, nil)
            }
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return (125, message)
        }
    }

    private func configureContainer(_ configuration: inout LinuxContainer.Configuration) throws {
        configuration.cpus = options.cpus
        configuration.memoryInBytes = options.memoryBytes
        configuration.interfaces = [
            VmnetNetwork.Interface(
                reference: networkReference,
                ipv4Address: try CIDRv4(ipv4Address),
                ipv4Gateway: try IPv4Address(ipv4Gateway),
                macAddress: try MACAddress(macAddress),
                mtu: mtu
            )
        ]
        configuration.dns = DNS(nameservers: [ipv4Gateway])
        if !options.command.isEmpty {
            configuration.process.arguments = options.command
        }
        if let workingDirectory = options.workingDirectory {
            configuration.process.workingDirectory = workingDirectory
        }
        if let user = options.user {
            configuration.process.user = ContainerizationOCI.User(username: user)
        }
        for mount in options.mounts {
            configuration.mounts.append(
                Containerization.Mount.share(
                    source: mount.source,
                    destination: mount.destination,
                    options: mount.readOnly ? ["ro"] : []
                )
            )
        }
        if options.interactive {
            configuration.process.stdin = FileHandleReaderStream(stdinHandle)
        }
        configuration.process.terminal = options.tty
        if options.tty {
            configuration.process.environmentVariables.removeAll { $0.hasPrefix("TERM=") }
            configuration.process.environmentVariables.append("TERM=xterm-256color")
        }
        for assignment in options.environment {
            let separator = assignment.firstIndex(of: "=")!
            let prefix = assignment[...separator]
            configuration.process.environmentVariables.removeAll { $0.hasPrefix(prefix) }
            configuration.process.environmentVariables.append(assignment)
        }
        configuration.process.stdout = FileWriter(stdoutHandle)
        configuration.process.stderr = options.tty ? nil : FileWriter(stderrHandle)
    }

    /// Exactly-once completion: writes any failure message to the supplied stderr,
    /// releases the vmnet reference, closes the owned stdio handles, then sends the
    /// asynchronous exit event. Transaction/broker cleanup runs only for runs that
    /// were actually registered with a balanced `xpc_transaction_begin`.
    func complete(exitCode: Int32, message: String?) {
        stateLock.lock()
        guard !completed else {
            stateLock.unlock()
            return
        }
        completed = true
        task = nil
        let resizeTask = self.resizeTask
        self.resizeTask = nil
        activeContainer = nil
        let wasRegistered = registered
        stateLock.unlock()
        resizeTask?.cancel()

        if let message {
            let line = "ghostvm-container-runtime: \(message)\n"
            try? stderrHandle.write(contentsOf: Data(line.utf8))
        }
        releaseNetworkReference()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        try? stdinHandle.close()

        let event = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(event, Key.operation, Operation.exit)
        xpc_dictionary_set_string(event, Key.runIdentifier, runIdentifier)
        xpc_dictionary_set_int64(event, Key.exitCode, Int64(exitCode))
        if let message {
            xpc_dictionary_set_string(event, Key.error, message)
        }
        xpc_connection_send_message(connection, event)

        if wasRegistered {
            broker?.remove(self)
            xpc_transaction_end()
        }
        log("runtime[\(getpid())]: run '\(runIdentifier)' completed with exit code \(exitCode)")
    }

    private func releaseNetworkReference() {
        stateLock.lock()
        guard !networkReleased else {
            stateLock.unlock()
            return
        }
        networkReleased = true
        stateLock.unlock()
        SharedVmnetNetwork.releaseVmnetReference(networkReference)
    }

    deinit {
        releaseNetworkReference()
        try? stdinHandle.close()
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }
}

/// Hosts all container VMs for the containing GhostVMHelper as an application-scoped
/// XPC service. Tracks runs by identifier and per-connection so that `cancel`,
/// `shutdown`, and connection invalidation can cancel the right tasks.
private final class RuntimeBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [String: RunContext] = [:]
    private var connectionRuns: [ObjectIdentifier: Set<String>] = [:]

    func handle(connection: xpc_connection_t, request: xpc_object_t) {
        let version = xpc_dictionary_get_uint64(request, Key.version)
        guard let operation = Self.string(request, Key.operation) else {
            sendReply(connection: connection, request: request, error: "missing operation")
            return
        }
        guard version == ContainerRuntimeXPCProtocol.version else {
            sendReply(connection: connection, request: request, error: "unsupported protocol version \(version)")
            return
        }

        switch operation {
        case Operation.ping:
            sendReply(connection: connection, request: request, ok: true)
        case Operation.run:
            handleRun(connection: connection, request: request)
        case Operation.cancel:
            handleCancel(connection: connection, request: request)
        case Operation.resize:
            handleResize(connection: connection, request: request)
        case Operation.shutdown:
            handleShutdown(connection: connection, request: request)
        default:
            sendReply(connection: connection, request: request, error: "unsupported operation '\(operation)'")
        }
    }

    /// Connection invalidated (client gone). Cancel every run owned by it.
    func disconnect(connection: xpc_connection_t) {
        let contexts = cancelAll(for: connection)
        if !contexts.isEmpty {
            log("runtime[\(getpid())]: connection invalidated, cancelling \(contexts.count) run(s)")
        }
    }

    func register(_ context: RunContext, connection: xpc_connection_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard runs[context.runIdentifier] == nil else { return false }
        runs[context.runIdentifier] = context
        connectionRuns[ObjectIdentifier(connection), default: []].insert(context.runIdentifier)
        return true
    }

    func remove(_ context: RunContext) {
        let runIdentifier = context.runIdentifier
        let connectionID = ObjectIdentifier(context.connection)
        lock.lock()
        if runs[runIdentifier] === context {
            runs.removeValue(forKey: runIdentifier)
        }
        if var set = connectionRuns[connectionID] {
            set.remove(runIdentifier)
            connectionRuns[connectionID] = set.isEmpty ? nil : set
        }
        lock.unlock()
    }

    private func handleRun(connection: xpc_connection_t, request: xpc_object_t) {
        guard let runIdentifier = Self.string(request, Key.runIdentifier), !runIdentifier.isEmpty else {
            sendReply(connection: connection, request: request, error: "missing run identifier")
            return
        }

        let stdinFD = xpc_dictionary_dup_fd(request, Key.stdin)
        let stdoutFD = xpc_dictionary_dup_fd(request, Key.stdout)
        let stderrFD = xpc_dictionary_dup_fd(request, Key.stderr)
        guard stdinFD >= 0, stdoutFD >= 0, stderrFD >= 0 else {
            if stdinFD >= 0 { close(stdinFD) }
            if stdoutFD >= 0 { close(stdoutFD) }
            if stderrFD >= 0 { close(stderrFD) }
            sendExit(connection: connection, runIdentifier: runIdentifier, exitCode: 125, message: "missing stdio file descriptors")
            return
        }
        let stdinHandle = FileHandle(fileDescriptor: stdinFD, closeOnDealloc: false)
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: false)
        let stderrHandle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: false)

        let arguments: [String]
        do {
            arguments = try Self.decodeArguments(request)
        } catch {
            failRun(
                connection: connection, runIdentifier: runIdentifier,
                stdinHandle: stdinHandle, stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                message: "invalid arguments payload: \(error)"
            )
            return
        }

        let options: RuntimeOptions
        do {
            options = try RuntimeOptions.parse(arguments)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            failRun(
                connection: connection, runIdentifier: runIdentifier,
                stdinHandle: stdinHandle, stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                message: message
            )
            return
        }

        guard let serialization = xpc_dictionary_get_value(request, Key.networkSerialization) else {
            failRun(
                connection: connection, runIdentifier: runIdentifier,
                stdinHandle: stdinHandle, stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                message: "missing network serialization"
            )
            return
        }

        // Reconstruct the vmnet reference directly from the helper-provided
        // serialization. Fail closed: never fall back to an isolated NAT network.
        var vmnetStatus: vmnet_return_t = .VMNET_FAILURE
        guard let networkReference = vmnet_network_create_with_serialization(serialization, &vmnetStatus),
              vmnetStatus == .VMNET_SUCCESS
        else {
            failRun(
                connection: connection, runIdentifier: runIdentifier,
                stdinHandle: stdinHandle, stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                message: "failed to reconstruct vmnet network (status \(vmnetStatus.rawValue))"
            )
            return
        }

        guard let ipv4Address = Self.string(request, Key.ipv4Address),
              let ipv4Gateway = Self.string(request, Key.ipv4Gateway),
              let macAddress = Self.string(request, Key.macAddress)
        else {
            SharedVmnetNetwork.releaseVmnetReference(networkReference)
            failRun(
                connection: connection, runIdentifier: runIdentifier,
                stdinHandle: stdinHandle, stdoutHandle: stdoutHandle, stderrHandle: stderrHandle,
                message: "missing network endpoint fields"
            )
            return
        }
        let mtu = UInt32(xpc_dictionary_get_uint64(request, Key.mtu))

        let context = RunContext(
            broker: self,
            connection: connection,
            runIdentifier: runIdentifier,
            options: options,
            networkReference: networkReference,
            ipv4Address: ipv4Address,
            ipv4Gateway: ipv4Gateway,
            macAddress: macAddress,
            mtu: mtu,
            stdinHandle: stdinHandle,
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle
        )

        guard register(context, connection: connection) else {
            // A run with this identifier is already active; fail the duplicate immediately.
            context.complete(exitCode: 125, message: "duplicate run identifier '\(runIdentifier)'")
            return
        }
        xpc_transaction_begin()
        context.markRegistered()

        let task = Task { [context] in
            let (exitCode, message) = await context.runContainer()
            context.complete(exitCode: exitCode, message: message)
        }
        context.setTask(task)
    }

    private func handleCancel(connection: xpc_connection_t, request: xpc_object_t) {
        let connectionID = ObjectIdentifier(connection)
        let runIdentifier = Self.string(request, Key.runIdentifier) ?? ""
        lock.lock()
        let belongs = connectionRuns[connectionID]?.contains(runIdentifier) ?? false
        let context = belongs ? runs[runIdentifier] : nil
        lock.unlock()
        context?.cancelTask()
        sendReply(connection: connection, request: request, ok: true, runIdentifier: runIdentifier)
    }

    private func handleResize(connection: xpc_connection_t, request: xpc_object_t) {
        let connectionID = ObjectIdentifier(connection)
        let runIdentifier = Self.string(request, Key.runIdentifier) ?? ""
        let rawColumns = xpc_dictionary_get_uint64(request, Key.columns)
        let rawRows = xpc_dictionary_get_uint64(request, Key.rows)
        guard rawColumns > 0, rawColumns <= UInt16.max,
              rawRows > 0, rawRows <= UInt16.max else {
            sendReply(connection: connection, request: request, error: "invalid terminal size", runIdentifier: runIdentifier)
            return
        }
        lock.lock()
        let belongs = connectionRuns[connectionID]?.contains(runIdentifier) ?? false
        let context = belongs ? runs[runIdentifier] : nil
        lock.unlock()
        context?.resize(columns: UInt16(rawColumns), rows: UInt16(rawRows))
        sendReply(connection: connection, request: request, ok: context != nil, runIdentifier: runIdentifier)
    }

    private func handleShutdown(connection: xpc_connection_t, request: xpc_object_t) {
        sendReply(connection: connection, request: request, ok: true)
        let contexts = cancelAll(for: connection)
        log("runtime[\(getpid())]: shutdown requested, cancelling \(contexts.count) run(s) for this connection")
    }

    private func cancelAll(for connection: xpc_connection_t) -> [RunContext] {
        let connectionID = ObjectIdentifier(connection)
        lock.lock()
        let runIdentifiers = connectionRuns[connectionID] ?? []
        let contexts = runIdentifiers.compactMap { runs[$0] }
        lock.unlock()
        for context in contexts {
            context.cancelTask()
        }
        return contexts
    }

    /// Closes the duplicated stdio handles, writes the failure to the supplied stderr,
    /// and sends an exit event. Used for setup failures that occur before a run is
    /// registered (no transaction to balance).
    private func failRun(
        connection: xpc_connection_t,
        runIdentifier: String,
        stdinHandle: FileHandle,
        stdoutHandle: FileHandle,
        stderrHandle: FileHandle,
        message: String
    ) {
        let line = "ghostvm-container-runtime: \(message)\n"
        try? stderrHandle.write(contentsOf: Data(line.utf8))
        try? stdoutHandle.close()
        try? stderrHandle.close()
        try? stdinHandle.close()
        sendExit(connection: connection, runIdentifier: runIdentifier, exitCode: 125, message: message)
        log("runtime[\(getpid())]: run '\(runIdentifier)' rejected during setup: \(message)")
    }

    private func sendReply(
        connection: xpc_connection_t,
        request: xpc_object_t,
        ok: Bool = false,
        error: String? = nil,
        runIdentifier: String? = nil
    ) {
        let reply = xpc_dictionary_create_reply(request) ?? xpc_dictionary_create_empty()
        if ok {
            xpc_dictionary_set_bool(reply, Key.ok, true)
        }
        if let error {
            xpc_dictionary_set_string(reply, Key.error, error)
        }
        if let runIdentifier {
            xpc_dictionary_set_string(reply, Key.runIdentifier, runIdentifier)
        }
        xpc_connection_send_message(connection, reply)
    }

    private func sendExit(
        connection: xpc_connection_t,
        runIdentifier: String,
        exitCode: Int32,
        message: String?
    ) {
        let event = xpc_dictionary_create_empty()
        xpc_dictionary_set_string(event, Key.operation, Operation.exit)
        xpc_dictionary_set_string(event, Key.runIdentifier, runIdentifier)
        xpc_dictionary_set_int64(event, Key.exitCode, Int64(exitCode))
        if let message {
            xpc_dictionary_set_string(event, Key.error, message)
        }
        xpc_connection_send_message(connection, event)
    }

    private static func string(_ dictionary: xpc_object_t, _ key: String) -> String? {
        guard let value = xpc_dictionary_get_string(dictionary, key) else { return nil }
        return String(cString: value)
    }

    private static func decodeArguments(_ request: xpc_object_t) throws -> [String] {
        guard let value = xpc_dictionary_get_value(request, Key.arguments) else {
            return []
        }
        let length = xpc_data_get_length(value)
        guard length > 0, let bytes = xpc_data_get_bytes_ptr(value) else {
            return []
        }
        let data = Data(bytes: bytes, count: length)
        return try JSONDecoder().decode([String].self, from: data)
    }
}

nonisolated(unsafe) private let broker = RuntimeBroker()

nonisolated private func log(_ message: String) {
    NSLog("%@", message)
}

/// `xpc_connection_t` is not Sendable in the XPC overlay, but each connection is
/// retained by the runtime for the lifetime of its event handler and serviced
/// serially on its target queue. This box lets the handler capture one safely.
private struct ConnectionBox: @unchecked Sendable {
    let value: xpc_connection_t
}

nonisolated private func acceptConnection(_ connection: xpc_connection_t) {
    let connectionBox = ConnectionBox(value: connection)
    xpc_connection_set_event_handler(connection) { event in
        if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
            broker.handle(connection: connectionBox.value, request: event)
        } else {
            broker.disconnect(connection: connectionBox.value)
        }
    }
    xpc_connection_activate(connection)
}

@main
private struct GhostVMContainerRuntime {
    nonisolated static func main() {
        log("runtime[\(getpid())]: container runtime service starting")
        xpc_main(acceptConnection)
    }
}
