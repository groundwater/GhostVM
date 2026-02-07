import Foundation

/// Errors that can occur when communicating with the guest
public enum GhostClientError: Error, LocalizedError {
    case notConnected
    case noContent
    case invalidResponse(Int)
    case encodingError
    case decodingError
    case connectionFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to guest"
        case .noContent:
            return "No content available"
        case .invalidResponse(let code):
            return "Invalid response from guest (status \(code))"
        case .encodingError:
            return "Failed to encode request"
        case .decodingError:
            return "Failed to decode response"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .timeout:
            return "Connection timed out"
        }
    }
}

/// Response from GET /clipboard endpoint
public struct ClipboardGetResponse: Codable {
    public let content: String?
    public let type: String?
    public let changeCount: Int?

    public init(content: String?, type: String? = nil, changeCount: Int? = nil) {
        self.content = content
        self.type = type
        self.changeCount = changeCount
    }
}

/// Response from POST /files/receive endpoint
public struct FileReceiveResponse: Codable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

/// Response from GET /files endpoint
public struct FileListResponse: Codable {
    public let files: [String]

    public init(files: [String]) {
        self.files = files
    }
}

/// Response from GET /urls endpoint
public struct URLListResponse: Codable {
    public let urls: [String]

    public init(urls: [String]) {
        self.urls = urls
    }
}

/// Response from GET /logs endpoint
public struct LogListResponse: Codable {
    public let logs: [String]

    public init(logs: [String]) {
        self.logs = logs
    }
}

/// Request body for POST /clipboard endpoint
public struct ClipboardPostRequest: Codable {
    public let content: String
    public let type: String

    public init(content: String, type: String = "public.utf8-plain-text") {
        self.content = content
        self.type = type
    }
}
