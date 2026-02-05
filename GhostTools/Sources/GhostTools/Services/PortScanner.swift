import Foundation

/// Response model for port list endpoint
struct PortListResponse: Codable {
    let ports: [Int]
}

/// Response model for port forward requests
struct PortForwardResponse: Codable {
    let ports: [Int]
}

/// Stub for port scanning - feature removed in port forwarding rewrite
/// Kept for API compatibility, returns empty results
final class PortScanner {
    static let shared = PortScanner()
    private init() {}

    func getListeningPorts() -> [Int] {
        // Port scanning removed - new port forwarding uses explicit config
        return []
    }
}

/// Stub for port forward request service - feature removed
/// Kept for API compatibility, returns empty results
final class PortForwardRequestService {
    static let shared = PortForwardRequestService()
    private init() {}

    func popRequests() -> [Int] {
        // Dynamic port forwarding removed - uses explicit config now
        return []
    }
}
