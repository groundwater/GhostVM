import Foundation
import GhostVMKit
import XPC

/// One application-scoped connection from GhostVMHelper to the runtime process
/// that hosts all container VMs for this helper instance.
final class ContainerRuntimeXPCClient: @unchecked Sendable {
    private final class InvokeReplyState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var timer: DispatchSourceTimer?

        init(_ continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func install(timer: DispatchSourceTimer) {
            lock.lock()
            if continuation == nil {
                lock.unlock()
                timer.cancel()
                return
            }
            self.timer = timer
            lock.unlock()
        }

        func complete(_ result: Result<Data, Error>) {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                return
            }
            self.continuation = nil
            let timer = self.timer
            self.timer = nil
            lock.unlock()
            timer?.cancel()
            continuation.resume(with: result)
        }
    }

    enum ClientError: Error, LocalizedError {
        case unavailable(String)
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return "Container runtime XPC service is unavailable: \(detail)"
            case .encodingFailed(let detail):
                return "Failed to encode container runtime request: \(detail)"
            }
        }
    }

    private struct PendingRun {
        let onReady: () -> Void
        let onExit: (Int32) -> Void
    }

    private let connection: xpc_connection_t
    private let sharedNetwork: SharedVmnetNetwork
    private let volumeRootURL: URL
    private let imageRootURL: URL
    private let lock = NSLock()
    private var pendingRuns: [String: PendingRun] = [:]
    private var invalidated = false

    static func ping() throws {
        let connection = xpc_connection_create(ContainerRuntimeXPCProtocol.serviceName, nil)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }

        let request = xpc_dictionary_create_empty()
        xpc_dictionary_set_uint64(request, ContainerRuntimeXPCProtocol.Key.version, ContainerRuntimeXPCProtocol.version)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.operation, ContainerRuntimeXPCProtocol.Operation.ping)
        let reply = xpc_connection_send_message_with_reply_sync(connection, request)
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let detail = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                .map { String(cString: $0) } ?? "unknown XPC error"
            throw ClientError.unavailable(detail)
        }
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_bool(reply, ContainerRuntimeXPCProtocol.Key.ok) else {
            throw ClientError.unavailable("invalid ping response")
        }
    }

    init(sharedNetwork: SharedVmnetNetwork, volumeRootURL: URL, imageRootURL: URL) {
        self.sharedNetwork = sharedNetwork
        self.volumeRootURL = volumeRootURL.standardizedFileURL
        self.imageRootURL = imageRootURL.standardizedFileURL
        connection = xpc_connection_create(ContainerRuntimeXPCProtocol.serviceName, nil)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            self?.handle(event)
        }
        xpc_connection_activate(connection)
    }

    deinit {
        invalidate()
    }

    func startBuild(
        runIdentifier: String,
        arguments: [String],
        network: SharedVmnetEndpointLease,
        stdoutFD: Int32,
        stderrFD: Int32,
        onReady: @escaping () -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        let encodedArguments: Data
        do {
            encodedArguments = try JSONEncoder().encode(arguments)
        } catch {
            throw ClientError.encodingFailed(error.localizedDescription)
        }

        lock.lock()
        guard !invalidated else {
            lock.unlock()
            throw ClientError.unavailable("connection is invalidated")
        }
        pendingRuns[runIdentifier] = PendingRun(onReady: onReady, onExit: onExit)
        lock.unlock()

        let request = xpc_dictionary_create_empty()
        xpc_dictionary_set_uint64(request, ContainerRuntimeXPCProtocol.Key.version, ContainerRuntimeXPCProtocol.version)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.operation, ContainerRuntimeXPCProtocol.Operation.build)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.runIdentifier, runIdentifier)
        encodedArguments.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(
                request,
                ContainerRuntimeXPCProtocol.Key.arguments,
                bytes.baseAddress,
                bytes.count
            )
        }
        xpc_dictionary_set_value(request, ContainerRuntimeXPCProtocol.Key.networkSerialization, network.serialization)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.ipv4Address, network.ipv4Address)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.ipv4Gateway, network.ipv4Gateway)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.macAddress, network.macAddress)
        xpc_dictionary_set_uint64(request, ContainerRuntimeXPCProtocol.Key.mtu, UInt64(network.mtu))
        xpc_dictionary_set_fd(request, ContainerRuntimeXPCProtocol.Key.stdout, stdoutFD)
        xpc_dictionary_set_fd(request, ContainerRuntimeXPCProtocol.Key.stderr, stderrFD)
        xpc_connection_send_message(connection, request)
    }

    func invoke(payload: Data, timeoutSeconds: TimeInterval? = nil) async throws -> Data {
        lock.lock()
        let isInvalidated = invalidated
        lock.unlock()
        guard !isInvalidated else {
            throw ClientError.unavailable("connection is invalidated")
        }

        let request = request(operation: ContainerRuntimeXPCProtocol.Operation.invoke)
        addSharedNetwork(to: request)
        payload.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(
                request,
                ContainerRuntimeXPCProtocol.Key.payload,
                bytes.baseAddress,
                bytes.count
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            let state = InvokeReplyState(continuation)
            if let timeoutSeconds {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
                timer.schedule(deadline: .now() + timeoutSeconds)
                timer.setEventHandler {
                    state.complete(.failure(ClientError.unavailable("invoke timed out")))
                }
                timer.resume()
                state.install(timer: timer)
            }
            xpc_connection_send_message_with_reply(
                connection,
                request,
                .global(qos: .userInitiated)
            ) { reply in
                state.complete(Self.decodeInvokeReply(reply))
            }
        }
    }

    func attach(payload: Data, descriptor: Int32) async throws {
        lock.lock()
        let isInvalidated = invalidated
        lock.unlock()
        guard !isInvalidated else {
            throw ClientError.unavailable("connection is invalidated")
        }

        let request = request(operation: ContainerRuntimeXPCProtocol.Operation.attach)
        addSharedNetwork(to: request)
        payload.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(
                request,
                ContainerRuntimeXPCProtocol.Key.payload,
                bytes.baseAddress,
                bytes.count
            )
        }
        xpc_dictionary_set_fd(request, ContainerRuntimeXPCProtocol.Key.descriptor, descriptor)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            xpc_connection_send_message_with_reply(
                connection,
                request,
                .global(qos: .userInitiated)
            ) { reply in
                if xpc_get_type(reply) == XPC_TYPE_ERROR {
                    let detail = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                        .map { String(cString: $0) } ?? "unknown XPC error"
                    continuation.resume(throwing: ClientError.unavailable(detail))
                } else if let error = xpc_dictionary_get_string(reply, ContainerRuntimeXPCProtocol.Key.error) {
                    continuation.resume(throwing: ClientError.unavailable(String(cString: error)))
                } else if xpc_dictionary_get_bool(reply, ContainerRuntimeXPCProtocol.Key.ok) {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ClientError.unavailable("invalid attachment response"))
                }
            }
        }
    }

    private static func decodeInvokeReply(_ reply: xpc_object_t) -> Result<Data, Error> {
        if xpc_get_type(reply) == XPC_TYPE_ERROR {
            let detail = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                .map { String(cString: $0) } ?? "unknown XPC error"
            return .failure(ClientError.unavailable(detail))
        }
        if let error = xpc_dictionary_get_string(reply, ContainerRuntimeXPCProtocol.Key.error) {
            return .failure(ClientError.unavailable(String(cString: error)))
        }
        guard let value = xpc_dictionary_get_value(reply, ContainerRuntimeXPCProtocol.Key.payload),
              xpc_get_type(value) == XPC_TYPE_DATA,
              let bytes = xpc_data_get_bytes_ptr(value)
        else {
            return .failure(ClientError.unavailable("invalid invoke response"))
        }
        return .success(Data(bytes: bytes, count: xpc_data_get_length(value)))
    }

    private func addSharedNetwork(to request: xpc_object_t) {
        xpc_dictionary_set_value(
            request,
            ContainerRuntimeXPCProtocol.Key.networkSerialization,
            sharedNetwork.serialization
        )
        xpc_dictionary_set_string(
            request,
            ContainerRuntimeXPCProtocol.Key.ipv4Subnet,
            sharedNetwork.ipv4Subnet
        )
        xpc_dictionary_set_string(
            request,
            ContainerRuntimeXPCProtocol.Key.volumeRoot,
            volumeRootURL.path
        )
        xpc_dictionary_set_string(
            request,
            ContainerRuntimeXPCProtocol.Key.imageRoot,
            imageRootURL.path
        )
    }

    func cancel(runIdentifier: String) {
        let request = request(operation: ContainerRuntimeXPCProtocol.Operation.cancel)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.runIdentifier, runIdentifier)
        xpc_connection_send_message(connection, request)
    }

    func resize(runIdentifier: String, columns: UInt16, rows: UInt16) {
        let request = request(operation: ContainerRuntimeXPCProtocol.Operation.resize)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.runIdentifier, runIdentifier)
        xpc_dictionary_set_uint64(request, ContainerRuntimeXPCProtocol.Key.columns, UInt64(columns))
        xpc_dictionary_set_uint64(request, ContainerRuntimeXPCProtocol.Key.rows, UInt64(rows))
        xpc_connection_send_message(connection, request)
    }

    func invalidate() {
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        let runs = Array(pendingRuns.values)
        pendingRuns.removeAll()
        lock.unlock()

        let request = request(operation: ContainerRuntimeXPCProtocol.Operation.shutdown)
        xpc_connection_send_message(connection, request)
        xpc_connection_cancel(connection)
        for run in runs {
            run.onExit(143)
        }
    }

    private func handle(_ event: xpc_object_t) {
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            let detail = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION)
                .map { String(cString: $0) } ?? "unknown XPC error"
            NSLog("ContainerRuntimeXPC: connection event: %@", detail)
            failPendingRuns(
                status: 125,
                invalidating: xpc_equal(event, XPC_ERROR_CONNECTION_INVALID)
            )
            return
        }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
              let operationValue = xpc_dictionary_get_string(event, ContainerRuntimeXPCProtocol.Key.operation),
              let runValue = xpc_dictionary_get_string(event, ContainerRuntimeXPCProtocol.Key.runIdentifier)
        else {
            return
        }

        let operation = String(cString: operationValue)
        let runIdentifier = String(cString: runValue)
        switch operation {
        case ContainerRuntimeXPCProtocol.Operation.ready:
            lock.lock()
            let callback = pendingRuns[runIdentifier]?.onReady
            lock.unlock()
            callback?()
        case ContainerRuntimeXPCProtocol.Operation.exit:
            lock.lock()
            let pending = pendingRuns.removeValue(forKey: runIdentifier)
            lock.unlock()
            pending?.onExit(Int32(xpc_dictionary_get_int64(event, ContainerRuntimeXPCProtocol.Key.exitCode)))
        default:
            break
        }
    }

    private func failPendingRuns(status: Int32, invalidating: Bool = false) {
        lock.lock()
        if invalidating {
            invalidated = true
        }
        let runs = Array(pendingRuns.values)
        pendingRuns.removeAll()
        lock.unlock()
        for run in runs {
            run.onExit(status)
        }
    }

    private func request(operation: String) -> xpc_object_t {
        let request = xpc_dictionary_create_empty()
        xpc_dictionary_set_uint64(request, ContainerRuntimeXPCProtocol.Key.version, ContainerRuntimeXPCProtocol.version)
        xpc_dictionary_set_string(request, ContainerRuntimeXPCProtocol.Key.operation, operation)
        return request
    }
}
