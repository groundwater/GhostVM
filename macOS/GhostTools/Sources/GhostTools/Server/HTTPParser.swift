import Foundation

/// HTTP method enum
enum HTTPMethod: String {
    case GET
    case POST
    case PUT
    case DELETE
    case HEAD
    case OPTIONS
    case PATCH
}

/// HTTP status codes
enum HTTPStatus: Int {
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

    var reasonPhrase: String {
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
}

/// Parsed HTTP request
struct HTTPRequest {
    let method: HTTPMethod
    let path: String
    let headers: [String: String]
    let body: Data?

    /// Gets a header value (case-insensitive)
    func header(_ name: String) -> String? {
        let lowercased = name.lowercased()
        for (key, value) in headers {
            if key.lowercased() == lowercased {
                return value
            }
        }
        return nil
    }
}

/// HTTP response
struct HTTPResponse {
    var status: HTTPStatus
    var headers: [String: String]
    var body: Data?

    init(status: HTTPStatus, headers: [String: String] = [:], body: Data? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Creates a JSON response
    static func json(_ data: Data, status: HTTPStatus = .ok) -> HTTPResponse {
        var headers = ["Content-Type": "application/json"]
        headers["Content-Length"] = "\(data.count)"
        return HTTPResponse(status: status, headers: headers, body: data)
    }

    /// Creates an error response
    static func error(_ status: HTTPStatus, message: String) -> HTTPResponse {
        let payload: [String: String] = ["error": message]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data(#"{"error":"unknown"}"#.utf8)
        return json(body, status: status)
    }
}

/// Simple HTTP/1.1 parser
enum HTTPParser {
    /// Parses an HTTP request from raw data
    static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Split into lines
        let lines = string.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return nil
        }

        // Parse request line: METHOD PATH HTTP/VERSION
        let requestLineParts = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLineParts.count >= 2 else {
            return nil
        }

        guard let method = HTTPMethod(rawValue: String(requestLineParts[0])) else {
            return nil
        }

        let path = String(requestLineParts[1])

        // Parse headers
        var headers: [String: String] = [:]
        var bodyStartIndex = 1
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty {
                bodyStartIndex = i + 1
                break
            }

            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Parse body if present
        var body: Data? = nil
        if bodyStartIndex < lines.count {
            let bodyString = lines[bodyStartIndex...].joined(separator: "\r\n")
            if !bodyString.isEmpty {
                body = Data(bodyString.utf8)
            }
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    /// Formats an HTTP response to raw data
    static func formatResponse(_ response: HTTPResponse) -> Data {
        var result = "HTTP/1.1 \(response.status.rawValue) \(response.status.reasonPhrase)\r\n"

        // Add headers
        var headers = response.headers
        if let body = response.body {
            headers["Content-Length"] = "\(body.count)"
        } else {
            headers["Content-Length"] = "0"
        }
        headers["Connection"] = "close"

        for (key, value) in headers {
            result += "\(key): \(value)\r\n"
        }

        result += "\r\n"

        var data = Data(result.utf8)
        if let body = response.body {
            data.append(body)
        }

        return data
    }
}
