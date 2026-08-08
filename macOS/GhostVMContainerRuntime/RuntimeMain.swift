import Containerization
import ContainerizationError
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

final class FileWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func close() throws {}
}

/// Hosts all container VMs for the containing GhostVMHelper as an application-scoped
/// XPC service. Tracks backend operations and direct object sessions.
private final class RuntimeBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var builds: [String: BuildContext] = [:]
    private var connectionRuns: [ObjectIdentifier: Set<String>] = [:]
    private var directSessions: [ObjectIdentifier: GhostboxSession] = [:]
    private let directDispatcher = GhostboxDispatcher.standard

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
        case Operation.build:
            handleBuild(connection: connection, request: request)
        case Operation.cancel:
            handleCancel(connection: connection, request: request)
        case Operation.invoke:
            handleInvoke(connection: connection, request: request)
        case Operation.attach:
            handleAttach(connection: connection, request: request)
        case Operation.shutdown:
            handleShutdown(connection: connection, request: request)
        default:
            sendReply(connection: connection, request: request, error: "unsupported operation '\(operation)'")
        }
    }

    /// Connection invalidated (client gone). Cancel every operation owned by it.
    func disconnect(connection: xpc_connection_t) {
        let count = cancelAll(for: connection)
        clearDirectSession(for: connection)
        if count > 0 {
            log("runtime[\(getpid())]: connection invalidated, cancelling \(count) operation(s)")
        }
    }

    private func remove(_ context: BuildContext) {
        let identifier = context.runIdentifier
        let connectionID = ObjectIdentifier(context.connection)
        lock.lock()
        if builds[identifier] === context { builds.removeValue(forKey: identifier) }
        if var set = connectionRuns[connectionID] {
            set.remove(identifier)
            connectionRuns[connectionID] = set.isEmpty ? nil : set
        }
        lock.unlock()
    }

    private func handleBuild(connection: xpc_connection_t, request: xpc_object_t) {
        guard let identifier = Self.string(request, Key.runIdentifier), !identifier.isEmpty else {
            sendReply(connection: connection, request: request, error: "missing build identifier")
            return
        }
        let stdoutFD = xpc_dictionary_dup_fd(request, Key.stdout)
        let stderrFD = xpc_dictionary_dup_fd(request, Key.stderr)
        guard stdoutFD >= 0, stderrFD >= 0 else {
            if stdoutFD >= 0 { close(stdoutFD) }
            if stderrFD >= 0 { close(stderrFD) }
            sendExit(connection: connection, runIdentifier: identifier, exitCode: 125, message: "missing build output file descriptors")
            return
        }
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: false)
        let stderrHandle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: false)

        let options: RuntimeBuildOptions
        do {
            options = try RuntimeBuildOptions.parse(Self.decodeArguments(request))
        } catch {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            sendExit(connection: connection, runIdentifier: identifier, exitCode: 125, message: "invalid build payload: \(error.localizedDescription)")
            return
        }
        guard let serialization = xpc_dictionary_get_value(request, Key.networkSerialization) else {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            sendExit(connection: connection, runIdentifier: identifier, exitCode: 125, message: "missing network serialization")
            return
        }
        var vmnetStatus: vmnet_return_t = .VMNET_FAILURE
        guard let networkReference = vmnet_network_create_with_serialization(serialization, &vmnetStatus),
              vmnetStatus == .VMNET_SUCCESS else {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            sendExit(connection: connection, runIdentifier: identifier, exitCode: 125, message: "failed to reconstruct vmnet network (status \(vmnetStatus.rawValue))")
            return
        }
        guard let ipv4Address = Self.string(request, Key.ipv4Address),
              let ipv4Gateway = Self.string(request, Key.ipv4Gateway),
              let macAddress = Self.string(request, Key.macAddress) else {
            SharedVmnetNetwork.releaseVmnetReference(networkReference)
            try? stdoutHandle.close()
            try? stderrHandle.close()
            sendExit(connection: connection, runIdentifier: identifier, exitCode: 125, message: "missing network endpoint fields")
            return
        }

        let context = BuildContext(
            connection: connection,
            runIdentifier: identifier,
            options: options,
            networkReference: networkReference,
            ipv4Address: ipv4Address,
            ipv4Gateway: ipv4Gateway,
            macAddress: macAddress,
            mtu: UInt32(xpc_dictionary_get_uint64(request, Key.mtu)),
            stdoutHandle: stdoutHandle,
            stderrHandle: stderrHandle,
            onComplete: { [weak self] context in self?.remove(context) }
        )
        lock.lock()
        let duplicate = builds[identifier] != nil
        if !duplicate {
            builds[identifier] = context
            connectionRuns[ObjectIdentifier(connection), default: []].insert(identifier)
        }
        lock.unlock()
        guard !duplicate else {
            sendExit(connection: connection, runIdentifier: identifier, exitCode: 125, message: "duplicate operation identifier '\(identifier)'")
            return
        }
        xpc_transaction_begin()
        context.start()
    }

    private func handleCancel(connection: xpc_connection_t, request: xpc_object_t) {
        let connectionID = ObjectIdentifier(connection)
        let runIdentifier = Self.string(request, Key.runIdentifier) ?? ""
        lock.lock()
        let belongs = connectionRuns[connectionID]?.contains(runIdentifier) ?? false
        let build = belongs ? builds[runIdentifier] : nil
        lock.unlock()
        build?.cancelTask()
        sendReply(connection: connection, request: request, ok: true, runIdentifier: runIdentifier)
    }

    private func handleShutdown(connection: xpc_connection_t, request: xpc_object_t) {
        sendReply(connection: connection, request: request, ok: true)
        let count = cancelAll(for: connection)
        clearDirectSession(for: connection)
        log("runtime[\(getpid())]: shutdown requested, cancelling \(count) operation(s) for this connection")
    }

    private func handleInvoke(connection: xpc_connection_t, request: xpc_object_t) {
        guard let payload = Self.data(request, Key.payload) else {
            sendReply(connection: connection, request: request, error: "missing invoke payload")
            return
        }

        let directRequest: GhostboxDirectRequest
        do {
            directRequest = try JSONDecoder().decode(GhostboxDirectRequest.self, from: payload)
        } catch {
            sendReply(connection: connection, request: request, error: "invalid invoke payload: \(error)")
            return
        }

        let session: GhostboxSession
        do {
            session = try directSession(for: connection, request: request)
        } catch {
            sendReply(connection: connection, request: request, error: error.localizedDescription)
            return
        }
        do {
            try session.beginInvocation()
        } catch {
            sendReply(connection: connection, request: request, error: error.localizedDescription)
            return
        }
        let connectionBox = ConnectionBox(value: connection)
        let requestBox = ConnectionBox(value: request)
        xpc_transaction_begin()
        Task { [self, directRequest, session, connectionBox, requestBox] in
            defer {
                session.endInvocation()
                xpc_transaction_end()
            }

            let response: GhostboxDirectResponse
            do {
                try directRequest.validate()
                let result = try await directDispatcher.dispatch(
                    method: directRequest.method,
                    parameters: directRequest.parameters,
                    session: session
                )
                response = .success(id: directRequest.id, value: result)
            } catch let error as DirectDispatchError {
                response = .failure(id: directRequest.id, code: error.code, message: error.message)
            } catch let error as ContainerizationError {
                response = .failure(
                    id: directRequest.id,
                    code: Self.directErrorCode(error.code),
                    message: error.localizedDescription
                )
            } catch let error as ContainerProtocolError {
                response = .failure(
                    id: directRequest.id,
                    code: .invalidArgument,
                    message: error.localizedDescription
                )
            } catch {
                response = .failure(
                    id: directRequest.id,
                    code: .internalError,
                    message: error.localizedDescription
                )
            }

            do {
                sendPayload(
                    connection: connectionBox.value,
                    request: requestBox.value,
                    payload: try JSONEncoder().encode(response)
                )
            } catch {
                sendReply(
                    connection: connectionBox.value,
                    request: requestBox.value,
                    error: "failed to encode invoke response: \(error)"
                )
            }
        }
    }

    private func handleAttach(connection: xpc_connection_t, request: xpc_object_t) {
        guard let payload = Self.data(request, Key.payload) else {
            sendReply(connection: connection, request: request, error: "missing attachment payload")
            return
        }
        let descriptor = xpc_dictionary_dup_fd(request, Key.descriptor)
        guard descriptor >= 0 else {
            sendReply(connection: connection, request: request, error: "missing attachment descriptor")
            return
        }

        let connectionBox = ConnectionBox(value: connection)
        let requestBox = ConnectionBox(value: request)
        let session: GhostboxSession
        do {
            session = try directSession(for: connection, request: request)
        } catch {
            Darwin.close(descriptor)
            sendReply(connection: connection, request: request, error: error.localizedDescription)
            return
        }
        do {
            try session.beginInvocation()
        } catch {
            Darwin.close(descriptor)
            sendReply(connection: connection, request: request, error: error.localizedDescription)
            return
        }
        xpc_transaction_begin()
        Task.detached { [self, connectionBox, requestBox, payload, session, descriptor] in
            defer {
                Darwin.close(descriptor)
                session.endInvocation()
                xpc_transaction_end()
            }

            var requestID = "unknown"
            var sentResponse = false
            do {
                let directRequest = try JSONDecoder().decode(GhostboxDirectRequest.self, from: payload)
                try directRequest.validate()
                requestID = directRequest.id
                let attachment = try ghostboxIOAttachment(
                    method: directRequest.method,
                    parameters: directRequest.parameters,
                    session: session
                )
                let response = GhostboxDirectResponse.success(
                    id: directRequest.id,
                    value: .string(attachment.attachmentStream.rawValue)
                )
                guard ghostboxWriteAll(fd: descriptor, try response.encodeLine()) else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE)
                }
                sentResponse = true
                try attachment.attach(fd: descriptor)
            } catch let error as DirectDispatchError {
                let frame: Data?
                if sentResponse {
                    frame = try? GhostboxIOFrame.error(error.message).encodeLine()
                } else {
                    frame = try? GhostboxDirectResponse.failure(
                        id: requestID,
                        code: error.code,
                        message: error.message
                    ).encodeLine()
                }
                if let frame { _ = ghostboxWriteAll(fd: descriptor, frame) }
            } catch let error as ContainerProtocolError {
                let frame: Data?
                if sentResponse {
                    frame = try? GhostboxIOFrame.error(error.localizedDescription).encodeLine()
                } else {
                    frame = try? GhostboxDirectResponse.failure(
                        id: requestID,
                        code: .invalidArgument,
                        message: error.localizedDescription
                    ).encodeLine()
                }
                if let frame { _ = ghostboxWriteAll(fd: descriptor, frame) }
            } catch {
                let message = error.localizedDescription
                let frame: Data?
                if sentResponse {
                    frame = try? GhostboxIOFrame.error(message).encodeLine()
                } else {
                    frame = try? GhostboxDirectResponse.failure(
                        id: requestID,
                        code: .internalError,
                        message: message
                    ).encodeLine()
                }
                if let frame { _ = ghostboxWriteAll(fd: descriptor, frame) }
            }
            sendReply(connection: connectionBox.value, request: requestBox.value, ok: true)
        }
    }

    private static func directErrorCode(_ code: ContainerizationError.Code) -> ContainerRuntimeErrorCode {
        switch code {
        case .invalidArgument: return .invalidArgument
        case .exists: return .alreadyExists
        case .notFound: return .notFound
        case .cancelled, .interrupted: return .cancelled
        case .invalidState, .empty: return .failedPrecondition
        case .timeout: return .timeout
        case .unsupported: return .unsupported
        case .internalError, .unknown: return .internalError
        default: return .internalError
        }
    }

    private func directSession(for connection: xpc_connection_t, request: xpc_object_t) throws -> GhostboxSession {
        let connectionID = ObjectIdentifier(connection)
        lock.lock()
        if let session = directSessions[connectionID] {
            lock.unlock()
            return session
        }
        guard let serialization = xpc_dictionary_get_value(request, Key.networkSerialization),
              let subnetString = Self.string(request, Key.ipv4Subnet),
              let volumeRoot = Self.string(request, Key.volumeRoot),
              volumeRoot.hasPrefix("/"),
              let imageRoot = Self.string(request, Key.imageRoot),
              imageRoot.hasPrefix("/") else {
            lock.unlock()
            throw ContainerizationError(.invalidArgument, message: "missing shared GhostVM runtime metadata")
        }
        var status: vmnet_return_t = .VMNET_FAILURE
        guard let reference = vmnet_network_create_with_serialization(serialization, &status),
              status == .VMNET_SUCCESS else {
            lock.unlock()
            throw ContainerizationError(
                .internalError,
                message: "failed to reconstruct shared GhostVM network (status \(status.rawValue))"
            )
        }
        let network: GhostboxNetwork
        do {
            network = GhostboxNetwork(sharedReference: reference, subnet: try CIDRv4(subnetString))
        } catch {
            SharedVmnetNetwork.releaseVmnetReference(reference)
            lock.unlock()
            throw error
        }
        let session: GhostboxSession
        do {
            session = GhostboxSession(context: [
                ghostboxSharedNetworkContextKey: network,
                ghostboxVolumeStoreContextKey: GhostboxVolumeStore(rootURL: URL(fileURLWithPath: volumeRoot)),
                ghostboxImageStoreContextKey: try ImageStore(path: URL(fileURLWithPath: imageRoot)),
            ])
        } catch {
            SharedVmnetNetwork.releaseVmnetReference(reference)
            lock.unlock()
            throw error
        }
        directSessions[connectionID] = session
        lock.unlock()
        xpc_transaction_begin()
        return session
    }

    private func clearDirectSession(for connection: xpc_connection_t) {
        lock.lock()
        let session = directSessions.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
        if let session {
            Task {
                await session.close()
                xpc_transaction_end()
            }
        }
    }

    private func sendPayload(
        connection: xpc_connection_t,
        request: xpc_object_t,
        payload: Data
    ) {
        let reply = xpc_dictionary_create_reply(request) ?? xpc_dictionary_create_empty()
        payload.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(reply, Key.payload, bytes.baseAddress, bytes.count)
        }
        xpc_connection_send_message(connection, reply)
    }

    private func cancelAll(for connection: xpc_connection_t) -> Int {
        let connectionID = ObjectIdentifier(connection)
        lock.lock()
        let runIdentifiers = connectionRuns[connectionID] ?? []
        let buildContexts = runIdentifiers.compactMap { builds[$0] }
        lock.unlock()
        for context in buildContexts {
            context.cancelTask()
        }
        return buildContexts.count
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

    private static func data(_ dictionary: xpc_object_t, _ key: String) -> Data? {
        guard let value = xpc_dictionary_get_value(dictionary, key),
              xpc_get_type(value) == XPC_TYPE_DATA,
              let bytes = xpc_data_get_bytes_ptr(value) else {
            return nil
        }
        return Data(bytes: bytes, count: xpc_data_get_length(value))
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
        signal(SIGPIPE, SIG_IGN)
        log("runtime[\(getpid())]: container runtime service starting")
        xpc_main(acceptConnection)
    }
}
