import Foundation

/// Shared HTTP utilities for host-side code (GhostVM, GhostVMHelper, vmctl)
///
/// This module provides binary-safe HTTP request/response building and parsing
/// utilities to eliminate code duplication across the codebase.
///
/// **Design principles:**
/// - Binary-safe throughout (uses `Data`, not `String` for bodies)
/// - Stateless utilities (`public static` functions)
/// - Minimal dependencies (Foundation only)
/// - Compatible with both vsock and Unix socket usage
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
            let parts = pair.components(separatedBy: "=")
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

    // MARK: - HTTP Request Building

    /// Build a complete HTTP/1.1 request as Data (binary-safe)
    ///
    /// This method constructs a complete HTTP request including headers and body.
    /// The result is binary-safe and can contain arbitrary data in the body.
    ///
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - path: Request path (e.g., "/api/v1/foo")
    ///   - headers: Additional headers (Content-Type, Authorization, etc.)
    ///   - body: Optional request body (binary-safe)
    /// - Returns: Complete HTTP request ready to send over a socket
    public static func buildRequest(
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> Data {
        var httpRequest = "\(method) \(path) HTTP/1.1\r\n"
        httpRequest += "Host: localhost\r\n"
        httpRequest += "Connection: close\r\n"

        // Add all custom headers
        for (key, value) in headers {
            httpRequest += "\(key): \(value)\r\n"
        }

        // Add Content-Length if body present
        if let body = body {
            httpRequest += "Content-Length: \(body.count)\r\n"
        }

        httpRequest += "\r\n"

        // Convert to data and append body (binary-safe)
        var requestData = Data(httpRequest.utf8)
        if let body = body {
            requestData.append(body)
        }

        return requestData
    }

    // MARK: - HTTP Response Building

    /// Build a complete HTTP/1.1 response as Data (binary-safe)
    ///
    /// - Parameters:
    ///   - status: HTTP status (use HTTPStatus.ok, etc.)
    ///   - contentType: Content-Type header value
    ///   - body: Response body (binary-safe)
    /// - Returns: Complete HTTP response ready to send over a socket
    public static func buildResponse(
        status: HTTPStatus,
        contentType: String,
        body: Data
    ) -> Data {
        var httpResponse = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n"
        httpResponse += "Content-Type: \(contentType)\r\n"
        httpResponse += "Content-Length: \(body.count)\r\n"
        httpResponse += "Connection: close\r\n"
        httpResponse += "\r\n"

        var responseData = Data(httpResponse.utf8)
        responseData.append(body)

        return responseData
    }

    /// Build a JSON response
    /// - Parameters:
    ///   - jsonData: JSON-encoded data
    ///   - status: HTTP status code (default: 200 OK)
    /// - Returns: Complete HTTP response
    public static func buildJSONResponse(
        _ jsonData: Data,
        status: HTTPStatus = .ok
    ) -> Data {
        return buildResponse(
            status: status,
            contentType: "application/json",
            body: jsonData
        )
    }

    /// Build an error response
    /// - Parameters:
    ///   - status: HTTP status code
    ///   - message: Error message
    /// - Returns: Complete HTTP error response with JSON body
    public static func buildErrorResponse(
        status: HTTPStatus,
        message: String
    ) -> Data {
        let payload = ["error": message]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ??
                   Data(#"{"error":"unknown"}"#.utf8)
        return buildJSONResponse(body, status: status)
    }
}
