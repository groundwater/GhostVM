import Foundation
import Network

/// Manages NWListeners for port forwarding rules, accepting external connections
/// and injecting packets into the custom network.
public final class PortForwarder {
    private let rules: [PortForwardRule]
    private let queue: DispatchQueue
    private var listeners: [UInt16: NWListener] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var writeToVM: ((Data) -> Void)?

    public init(rules: [PortForwardRule], queue: DispatchQueue) {
        self.rules = rules
        self.queue = queue
    }

    /// Start listeners for all enabled rules.
    /// The writeHandler is called with Ethernet frames to inject into the VM network.
    public func start(writeHandler: @escaping (Data) -> Void) {
        self.writeToVM = writeHandler

        for rule in rules {
            guard rule.enabled else { continue }
            startListener(for: rule)
        }
    }

    /// Stop all listeners and connections.
    public func stop() {
        for (_, listener) in listeners {
            listener.cancel()
        }
        listeners.removeAll()

        for (_, conn) in connections {
            conn.cancel()
        }
        connections.removeAll()

        writeToVM = nil
    }

    // MARK: - Private

    private func startListener(for rule: PortForwardRule) {
        let params: NWParameters
        switch rule.proto {
        case .tcp:
            params = .tcp
        case .udp:
            params = .udp
        default:
            print("[PortForwarder] Unsupported protocol: \(rule.proto)")
            return
        }

        guard let port = NWEndpoint.Port(rawValue: rule.externalPort) else {
            print("[PortForwarder] Invalid port: \(rule.externalPort)")
            return
        }

        do {
            let listener = try NWListener(using: params, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection, rule: rule)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[PortForwarder] Listening on port \(rule.externalPort) → \(rule.internalIP):\(rule.internalPort)")
                case .failed(let error):
                    print("[PortForwarder] Listener failed on port \(rule.externalPort): \(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            listeners[rule.externalPort] = listener
        } catch {
            print("[PortForwarder] Failed to create listener on port \(rule.externalPort): \(error)")
        }
    }

    private func handleNewConnection(_ connection: NWConnection, rule: PortForwardRule) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        // Forward to internal VM IP:port
        guard let internalIP = IPv4Address(string: rule.internalIP) else {
            connection.cancel()
            connections.removeValue(forKey: id)
            return
        }

        let internalPort = rule.internalPort

        // Create outbound connection to internal VM
        let host = NWEndpoint.Host(internalIP.description)
        guard let port = NWEndpoint.Port(rawValue: internalPort) else {
            connection.cancel()
            connections.removeValue(forKey: id)
            return
        }

        let internalParams: NWParameters
        switch rule.proto {
        case .tcp: internalParams = .tcp
        case .udp: internalParams = .udp
        default:
            connection.cancel()
            connections.removeValue(forKey: id)
            return
        }

        let internalConn = NWConnection(host: host, port: port, using: internalParams)
        let internalID = ObjectIdentifier(internalConn)
        connections[internalID] = internalConn

        // Bridge the two connections
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cleanupPair(id, internalID) }
            if case .cancelled = state { self?.cleanupPair(id, internalID) }
        }

        internalConn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.bridgeConnections(external: connection, internal: internalConn,
                                        externalID: id, internalID: internalID)
            case .failed, .cancelled:
                self?.cleanupPair(id, internalID)
            default:
                break
            }
        }

        connection.start(queue: queue)
        internalConn.start(queue: queue)
    }

    private func bridgeConnections(external: NWConnection, internal internalConn: NWConnection,
                                   externalID: ObjectIdentifier, internalID: ObjectIdentifier) {
        // External → Internal
        pipeData(from: external, to: internalConn, fromID: externalID, toID: internalID)
        // Internal → External
        pipeData(from: internalConn, to: external, fromID: internalID, toID: externalID)
    }

    private func pipeData(from: NWConnection, to: NWConnection,
                          fromID: ObjectIdentifier, toID: ObjectIdentifier) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65535) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                self?.cleanupPair(fromID, toID)
                return
            }
            self?.pipeData(from: from, to: to, fromID: fromID, toID: toID)
        }
    }

    private func cleanupPair(_ id1: ObjectIdentifier, _ id2: ObjectIdentifier) {
        if let conn = connections.removeValue(forKey: id1) { conn.cancel() }
        if let conn = connections.removeValue(forKey: id2) { conn.cancel() }
    }
}
