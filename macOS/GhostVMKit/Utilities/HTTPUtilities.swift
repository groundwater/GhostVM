import Foundation

/// Shared HTTP utilities for host-side code.
///
/// `GhostHTTP` owns transport and framing. This helper remains only for
/// query parsing and legacy status-code mapping used by app-level code.
public enum HTTPUtilities {

    // MARK: - Query Parsing

    /// Parse a single query parameter from a URL path
    /// - Parameters:
    ///   - path: URL path with query string (e.g., "/api/foo?key=value")
    ///   - key: Parameter name to extract
    /// - Returns: Decoded parameter value, or nil if not found
    public static func parseQuery(_ path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        for pair in query.components(separatedBy: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 && parts[0] == key {
                return parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return nil
    }

    /// Parse a boolean query parameter with flexible value handling
    /// - Parameters:
    ///   - path: URL path with query string
    ///   - key: Parameter name to extract
    /// - Returns: Boolean value if found and valid, nil otherwise
    public static func parseBoolQuery(_ path: String, key: String) -> Bool? {
        guard let value = parseQuery(path, key: key)?.lowercased() else { return nil }
        if value == "1" || value == "true" || value == "yes" { return true }
        if value == "0" || value == "false" || value == "no" { return false }
        return nil
    }

    // MARK: - Status Codes

    /// HTTP status code with reason phrase
    public enum HTTPStatus: Int {
        case ok = 200
        case created = 201
        case noContent = 204
        case badRequest = 400
        case unauthorized = 401
        case forbidden = 403
        case notFound = 404
        case methodNotAllowed = 405
        case requestTimeout = 408
        case internalServerError = 500

        /// Standard reason phrase for this status code
        public var reasonPhrase: String {
            switch self {
            case .ok: return "OK"
            case .created: return "Created"
            case .noContent: return "No Content"
            case .badRequest: return "Bad Request"
            case .unauthorized: return "Unauthorized"
            case .forbidden: return "Forbidden"
            case .notFound: return "Not Found"
            case .methodNotAllowed: return "Method Not Allowed"
            case .requestTimeout: return "Request Timeout"
            case .internalServerError: return "Internal Server Error"
            }
        }

        /// Get status for any code (with fallback for unknown codes)
        public static func from(code: Int) -> HTTPStatus {
            HTTPStatus(rawValue: code) ?? .internalServerError
        }
    }

}
