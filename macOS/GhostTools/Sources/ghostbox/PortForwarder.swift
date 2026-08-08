import Darwin
import Foundation
import Network

private let forwardingDiagnosticsEnabled =
    ProcessInfo.processInfo.environment["GHOSTBOX_FORWARD_DIAGNOSTICS"] == "1"

private func forwardingDiagnostic(_ message: @autoclosure () -> String) {
    guard forwardingDiagnosticsEnabled else { return }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    writeStderr("ghostbox: forward-diagnostic timestamp=\(formatter.string(from: Date())) \(message())\n")
}

struct PublishedPort: Equatable, Sendable {
    let hostAddress: String
    let hostPort: UInt16
    let containerPort: UInt16
}

enum PortForwardError: Error, LocalizedError {
    case invalidAddress(String)
    case network(operation: String, description: String)
    case socket(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "invalid IPv4 address \(address)"
        case .network(let operation, let description):
            return "\(operation) failed: \(description)"
        case .socket(let operation, let code):
            return "\(operation) failed: errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}

func parsePublishedPort(_ specification: String) -> Result<PublishedPort, ParseError> {
    let protocolParts = specification.split(separator: "/", omittingEmptySubsequences: false)
    guard protocolParts.count <= 2 else {
        return .failure(.invalidDirect("invalid published port: invalid protocol suffix"))
    }
    if protocolParts.count == 2, protocolParts[1].lowercased() != "tcp" {
        return .failure(.invalidDirect("invalid published port: only TCP is supported"))
    }
    let fields = protocolParts[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 2 || fields.count == 3 else {
        return .failure(.invalidDirect("invalid published port: expected [HOST_IP:]HOST_PORT:CONTAINER_PORT[/tcp]"))
    }
    let hostAddress = fields.count == 3 ? fields[0] : "127.0.0.1"
    let hostPortText = fields.count == 3 ? fields[1] : fields[0]
    let containerPortText = fields.count == 3 ? fields[2] : fields[1]
    var address = in_addr()
    guard hostAddress.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
        return .failure(.invalidDirect("invalid published port: host address must be an IPv4 address"))
    }
    guard let hostPort = UInt16(hostPortText), hostPort > 0 else {
        return .failure(.invalidDirect("invalid published port: host port must be between 1 and 65535"))
    }
    guard let containerPort = UInt16(containerPortText), containerPort > 0 else {
        return .failure(.invalidDirect("invalid published port: container port must be between 1 and 65535"))
    }
    return .success(PublishedPort(hostAddress: hostAddress, hostPort: hostPort, containerPort: containerPort))
}

final class PublishedPortForwarder: @unchecked Sendable {
    private let publication: PublishedPort
    private let queue: DispatchQueue
    private let listener: NWListener
    private let listenerTermination = ListenerTermination()
    private let lock = NSLock()
    private var started = false
    private var stopped = false
    private var targetAddress: String?
    private var pendingConnections: [(id: UUID, connection: NWConnection)] = []
    private var relays: [UUID: NetworkRelay] = [:]
    private var onFailure: (@Sendable (Error) -> Void)?
    private var listenerFailure: Error?

    init(_ publication: PublishedPort) async throws {
        self.publication = publication
        queue = DispatchQueue(label: "org.ghostvm.ghostbox.publish.\(publication.hostPort)", qos: .userInitiated)
        guard let address = IPv4Address(publication.hostAddress),
              let port = NWEndpoint.Port(rawValue: publication.hostPort) else {
            throw PortForwardError.invalidAddress(publication.hostAddress)
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: port)
        do {
            listener = try NWListener(using: parameters)
        } catch let error as NWError {
            throw Self.forwardError(operation: "listen", error: error)
        }

        let startup = ListenerStartup()
        let listenerTermination = self.listenerTermination
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                startup.complete(.success(()))
            case .failed(let error):
                startup.complete(.failure(Self.forwardError(operation: "listen", error: error)))
                listenerTermination.complete()
                self?.listenerFailed(error)
            case .cancelled:
                startup.complete(.failure(PortForwardError.network(operation: "listen", description: "cancelled")))
                listenerTermination.complete()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            startup.complete(.failure(PortForwardError.network(operation: "listen", description: "timed out")))
        }

        switch await startup.wait() {
        case .success:
            break
        case .failure(let error):
            listener.cancel()
            await listenerTermination.wait()
            throw error
        }
    }

    func start(
        targetAddress: String,
        onFailure: @escaping @Sendable (Error) -> Void = { _ in }
    ) {
        let (pending, failure): ([(id: UUID, connection: NWConnection)], Error?) = lock.withLock {
            guard !started else { return ([], nil) }
            started = true
            guard !stopped else { return ([], listenerFailure) }
            self.targetAddress = targetAddress
            self.onFailure = onFailure
            defer { pendingConnections.removeAll() }
            return (pendingConnections, nil)
        }
        forwardingDiagnostic(
            "event=start connectionID=- targetAddress=\(targetAddress) pendingConnections.count=\(pending.count)"
        )
        if let failure {
            onFailure(failure)
            return
        }
        pending.forEach { forward($0.connection, connectionID: $0.id, targetAddress: targetAddress) }
    }

    func stop() async {
        let active = cancel()
        await listenerTermination.wait()
        for relay in active { await relay.waitUntilStopped() }
    }

    deinit { _ = cancel() }

    private func cancel() -> [NetworkRelay] {
        let (active, shouldCancel): ([NetworkRelay], Bool) = lock.withLock {
            let active = Array(relays.values)
            guard !stopped else { return (active, false) }
            stopped = true
            pendingConnections.forEach { $0.connection.cancel() }
            pendingConnections.removeAll()
            return (active, true)
        }
        if shouldCancel { listener.cancel() }
        active.forEach { $0.cancel() }
        return active
    }

    private func accept(_ connection: NWConnection) {
        let connectionID = UUID()
        let state = lock.withLock { () -> (target: String?, pendingCount: Int, stopped: Bool) in
            guard !stopped else { return (nil, pendingConnections.count, true) }
            guard let targetAddress else {
                pendingConnections.append((connectionID, connection))
                return (nil, pendingConnections.count, false)
            }
            return (targetAddress, pendingConnections.count, false)
        }
        forwardingDiagnostic(
            "event=accept connectionID=\(connectionID) targetAddress=\(state.target ?? "nil") "
                + "pendingConnections.count=\(state.pendingCount) stopped=\(state.stopped)"
        )
        if let target = state.target {
            forward(connection, connectionID: connectionID, targetAddress: target)
        } else if state.stopped {
            connection.cancel()
        }
    }

    private func forward(_ connection: NWConnection, connectionID: UUID, targetAddress: String) {
        forwardingDiagnostic(
            "event=forward connectionID=\(connectionID) targetAddress=\(targetAddress) "
                + "pendingConnections.count=\(lock.withLock { pendingConnections.count })"
        )
        guard let address = IPv4Address(targetAddress),
              let port = NWEndpoint.Port(rawValue: publication.containerPort) else {
            connection.cancel()
            writeStderr("ghostbox: port \(publication.hostPort) forwarding failed: invalid IPv4 address \(targetAddress)\n")
            return
        }
        let relay = NetworkRelay(
            connectionID: connectionID,
            targetAddress: targetAddress,
            client: connection,
            target: NWConnection(host: .ipv4(address), port: port, using: .tcp),
            queue: DispatchQueue(label: "org.ghostvm.ghostbox.relay.\(connectionID)", qos: .userInitiated),
            onTargetFailure: { [publication] error in
                writeStderr("ghostbox: port \(publication.hostPort) forwarding failed: \(error.localizedDescription)\n")
            },
            completion: { [weak self] in self?.removeRelay(connectionID) }
        )
        let shouldStart = lock.withLock {
            guard !stopped else { return false }
            relays[connectionID] = relay
            return true
        }
        guard shouldStart else {
            relay.cancelBeforeStart()
            return
        }
        relay.start()
    }

    private func removeRelay(_ id: UUID) {
        lock.withLock { _ = relays.removeValue(forKey: id) }
    }

    private func listenerFailed(_ error: NWError) {
        let failure = Self.forwardError(operation: "accept", error: error)
        let (active, callback): ([NetworkRelay], (@Sendable (Error) -> Void)?) = lock.withLock {
            guard !stopped else { return ([], nil) }
            stopped = true
            listenerFailure = failure
            let active = Array(relays.values)
            pendingConnections.forEach { $0.connection.cancel() }
            pendingConnections.removeAll()
            return (active, started ? onFailure : nil)
        }
        listener.cancel()
        active.forEach { $0.cancel() }
        callback?(failure)
    }

    fileprivate static func forwardError(operation: String, error: NWError) -> PortForwardError {
        if case .posix(let code) = error {
            return .socket(operation: operation, code: code.rawValue)
        }
        return .network(operation: operation, description: String(describing: error))
    }
}

private final class ListenerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Result<Void, Error>, Never>?

    func complete(_ result: Result<Void, Error>) {
        let continuation: CheckedContinuation<Result<Void, Error>, Never>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }

    func wait() async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            let result = lock.withLock { () -> Result<Void, Error>? in
                if let result = self.result { return result }
                self.continuation = continuation
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

private final class ListenerTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func complete() {
        let continuations: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard !completed else { return [] }
            completed = true
            defer { self.continuations.removeAll() }
            return self.continuations
        }
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let completed = lock.withLock {
                guard !self.completed else { return true }
                continuations.append(continuation)
                return false
            }
            if completed { continuation.resume() }
        }
    }
}

private final class NetworkRelay: @unchecked Sendable {
    private let connectionID: UUID
    private let targetAddress: String
    private let client: NWConnection
    private let target: NWConnection
    private let queue: DispatchQueue
    private let onTargetFailure: @Sendable (Error) -> Void
    private let completion: @Sendable () -> Void
    private let termination = ListenerTermination()
    private var clientReady = false
    private var targetReady = false
    private var pumpsStarted = false
    private var clientPumpFinished = false
    private var targetPumpFinished = false
    private var clientTerminalState = false
    private var targetTerminalState = false
    private var started = false
    private var closed = false
    private var reportedTargetFailure = false

    init(
        connectionID: UUID,
        targetAddress: String,
        client: NWConnection,
        target: NWConnection,
        queue: DispatchQueue,
        onTargetFailure: @escaping @Sendable (Error) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        self.connectionID = connectionID
        self.targetAddress = targetAddress
        self.client = client
        self.target = target
        self.queue = queue
        self.onTargetFailure = onTargetFailure
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            guard !started, !closed else { return }
            started = true
            client.stateUpdateHandler = { [weak self] state in self?.connectionStateChanged(state, isTarget: false) }
            target.stateUpdateHandler = { [weak self] state in self?.connectionStateChanged(state, isTarget: true) }
            client.start(queue: queue)
            target.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [self] in
            close()
        }
    }

    func cancelBeforeStart() {
        close()
    }

    func waitUntilStopped() async {
        await termination.wait()
    }

    private func connectionStateChanged(_ state: NWConnection.State, isTarget: Bool) {
        guard !closed else { return }
        let (stateName, errorDescription): (String, String) = switch state {
        case .setup: ("setup", "nil")
        case .preparing: ("preparing", "nil")
        case .ready: ("ready", "nil")
        case .waiting(let error): ("waiting", String(describing: error))
        case .failed(let error): ("failed", String(describing: error))
        case .cancelled: ("cancelled", "nil")
        @unknown default: (String(describing: state), "nil")
        }
        forwardingDiagnostic(
            "event=state connectionID=\(connectionID) targetAddress=\(targetAddress) isTarget=\(isTarget) "
                + "state=\(stateName) error=\(errorDescription)"
        )
        switch state {
        case .ready:
            if isTarget { targetReady = true } else { clientReady = true }
            startPumpsIfReady()
        case .waiting(let error), .failed(let error):
            if !pumpsStarted {
                if isTarget, !targetReady, !reportedTargetFailure {
                    reportedTargetFailure = true
                    onTargetFailure(PublishedPortForwarder.forwardError(operation: "connect", error: error))
                }
                close()
            } else if case .failed = state {
                terminalStateChanged(isTarget: isTarget)
            }
        case .cancelled:
            if !pumpsStarted {
                close()
            } else {
                terminalStateChanged(isTarget: isTarget)
            }
        default:
            break
        }
    }

    private func startPumpsIfReady() {
        forwardingDiagnostic(
            "event=pump-check connectionID=\(connectionID) targetAddress=\(targetAddress) isTarget=- "
                + "clientReady=\(clientReady) targetReady=\(targetReady) pumpsStarted=\(pumpsStarted)"
        )
        guard clientReady, targetReady, !pumpsStarted else { return }
        pumpsStarted = true
        forwardingDiagnostic(
            "event=pump-started connectionID=\(connectionID) targetAddress=\(targetAddress) isTarget=-"
        )
        receive(from: client, sendTo: target, inputIsTarget: false)
        receive(from: target, sendTo: client, inputIsTarget: true)
    }

    private func receive(from input: NWConnection, sendTo output: NWConnection, inputIsTarget: Bool) {
        input.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !closed else { return }
            if isComplete {
                output.send(
                    content: data,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        guard let self, !closed else { return }
                        if error == nil { finishPump(isTarget: inputIsTarget) } else { close() }
                    }
                )
            } else if error != nil {
                guard let data, !data.isEmpty else {
                    close()
                    return
                }
                output.send(content: data, completion: .contentProcessed { [weak self] _ in self?.close() })
            } else if let data, !data.isEmpty {
                output.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self, !closed else { return }
                    if error == nil {
                        receive(from: input, sendTo: output, inputIsTarget: inputIsTarget)
                    } else {
                        close()
                    }
                })
            } else {
                receive(from: input, sendTo: output, inputIsTarget: inputIsTarget)
            }
        }
    }

    private func terminalStateChanged(isTarget: Bool) {
        if isTarget {
            targetTerminalState = true
            if targetPumpFinished { close() }
        } else {
            clientTerminalState = true
            if clientPumpFinished { close() }
        }
    }

    private func finishPump(isTarget: Bool) {
        if isTarget {
            targetPumpFinished = true
            if targetTerminalState { close() }
        } else {
            clientPumpFinished = true
            if clientTerminalState { close() }
        }
        if clientPumpFinished, targetPumpFinished { close() }
    }

    private func close() {
        guard !closed else { return }
        closed = true
        client.stateUpdateHandler = nil
        target.stateUpdateHandler = nil
        client.cancel()
        target.cancel()
        completion()
        termination.complete()
    }
}
