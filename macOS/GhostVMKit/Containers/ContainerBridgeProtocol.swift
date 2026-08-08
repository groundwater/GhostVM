import Foundation

/// Constants for the guest-initiated direct Containerization API channel.
public enum ContainerBridgeConstants {
    public static let port: UInt32 = 5004
    public static let protocolVersion = 5
    public static let maxRequestLineBytes = 64 * 1024
}

public enum ContainerProtocolError: Error, LocalizedError, Equatable {
    case emptyRequest
    case requestTooLarge(limit: Int)
    case malformedRequest(String)
    case connectionClosed

    public var errorDescription: String? {
        switch self {
        case .emptyRequest:
            return "Empty direct API request."
        case .requestTooLarge(let limit):
            return "Request line exceeds the \(limit)-byte limit."
        case .malformedRequest(let detail):
            return "Malformed direct API request: \(detail)"
        case .connectionClosed:
            return "Connection closed by peer."
        }
    }
}
