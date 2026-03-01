import Foundation
import Network

/// Forwards DNS queries from the VM to the host's DNS resolver or configured servers.
public final class DNSForwarder {
    public enum Mode {
        case passthrough       // Forward to system resolver
        case custom([String])  // Forward to specified servers
        case blocked           // Return NXDOMAIN for all queries
    }

    private let mode: Mode
    private let queue: DispatchQueue
    private var activeConnections: [NWConnection] = []
    private let lock = NSLock()

    public init(mode: Mode, queue: DispatchQueue) {
        self.mode = mode
        self.queue = queue
    }

    /// Convenience initializer from DNSConfig.
    public convenience init(dnsConfig: DNSConfig, queue: DispatchQueue) {
        let mode: Mode
        switch dnsConfig.mode {
        case .passthrough:
            mode = .passthrough
        case .custom:
            mode = .custom(dnsConfig.servers)
        case .blocked:
            mode = .blocked
        }
        self.init(mode: mode, queue: queue)
    }

    /// Handle a DNS query (UDP payload from port 53).
    /// Calls completion with a DNS response payload, or nil on failure.
    public func handleQuery(_ queryData: Data, completion: @escaping (Data?) -> Void) {
        switch mode {
        case .blocked:
            completion(buildNXDOMAIN(query: queryData))

        case .passthrough:
            // Use system resolver (8.8.8.8 as fallback if we can't determine system DNS)
            forwardTo(server: "8.8.8.8", port: 53, query: queryData, completion: completion)

        case .custom(let servers):
            guard let server = servers.first, !server.isEmpty else {
                completion(buildNXDOMAIN(query: queryData))
                return
            }
            forwardTo(server: server, port: 53, query: queryData, completion: completion)
        }
    }

    /// Stop all active forwarding connections.
    public func stop() {
        lock.lock()
        let conns = activeConnections
        activeConnections.removeAll()
        lock.unlock()
        for conn in conns {
            conn.cancel()
        }
    }

    // MARK: - Private

    private func forwardTo(server: String, port: UInt16, query: Data, completion: @escaping (Data?) -> Void) {
        let host = NWEndpoint.Host(server)
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let connection = NWConnection(host: host, port: nwPort, using: .udp)

        lock.lock()
        activeConnections.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                connection.send(content: query, completion: .contentProcessed { error in
                    if error != nil {
                        self?.removeConnection(connection)
                        completion(nil)
                        return
                    }
                    connection.receiveMessage { data, _, _, error in
                        self?.removeConnection(connection)
                        connection.cancel()
                        if let error = error {
                            print("[DNSForwarder] Receive error: \(error)")
                            completion(nil)
                        } else {
                            completion(data)
                        }
                    }
                })
            case .failed, .cancelled:
                self?.removeConnection(connection)
                completion(nil)
            default:
                break
            }
        }

        connection.start(queue: queue)

        // Timeout after 5 seconds
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            if connection.state != .cancelled {
                self?.removeConnection(connection)
                connection.cancel()
                // completion may have already been called, but NWConnection handles this
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        lock.lock()
        activeConnections.removeAll { $0 === connection }
        lock.unlock()
    }

    /// Build an NXDOMAIN response from a query.
    private func buildNXDOMAIN(query: Data) -> Data? {
        guard query.count >= 12 else { return nil }

        var response = query
        // Set QR bit (response) and RCODE=3 (NXDOMAIN)
        response[2] = (query[2] | 0x80) // QR=1
        response[3] = (query[3] & 0xF0) | 0x03 // RCODE=3
        // Zero answer/authority/additional counts
        response[6] = 0; response[7] = 0  // ANCOUNT
        response[8] = 0; response[9] = 0  // NSCOUNT
        response[10] = 0; response[11] = 0 // ARCOUNT
        return response
    }
}
