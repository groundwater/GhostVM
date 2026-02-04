import Foundation

/// Service for managing port forward requests from URL handler
/// When a localhost URL is opened, the URL handler requests immediate forwarding
/// so the host can set up the tunnel before opening the URL
final class PortForwardRequestService: @unchecked Sendable {
    static let shared = PortForwardRequestService()

    private var requestedPorts: Set<UInt16> = []
    private let lock = NSLock()

    private init() {}

    /// Request a port to be forwarded immediately
    /// Called when a localhost URL is intercepted
    func requestForward(_ port: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        requestedPorts.insert(port)
        print("[PortForwardRequest] Requested forward for port \(port)")
    }

    /// Pop all requested ports (returns and clears the queue)
    /// Called by the host when polling for port forward requests
    func popRequests() -> [UInt16] {
        lock.lock()
        defer { lock.unlock() }
        let ports = Array(requestedPorts).sorted()
        requestedPorts.removeAll()
        if !ports.isEmpty {
            print("[PortForwardRequest] Returning \(ports.count) requested port(s): \(ports)")
        }
        return ports
    }

    /// Check if any ports are requested (without clearing)
    func hasRequests() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !requestedPorts.isEmpty
    }
}

// MARK: - Response Types

/// Response for GET /api/v1/port-forwards endpoint
struct PortForwardResponse: Codable {
    let ports: [UInt16]
}
