import Foundation
import GhostVMKit

/// Synchronous HTTP/1.1 client over a Unix domain socket.
/// Blocking I/O is fine for CLI usage.
struct UnixSocketClient {
    let socketPath: String

    struct HTTPResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let contentType: String

        var isSuccess: Bool { statusCode >= 200 && statusCode < 300 }

        var bodyJSON: [String: Any]? {
            try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }

        var bodyString: String? {
            String(data: body, encoding: .utf8)
        }

        /// Extract error message from JSON body, or fall back to status code.
        var errorMessage: String {
            if let json = bodyJSON, let msg = json["error"] as? String {
                return msg
            }
            if let text = bodyString, !text.isEmpty {
                return text
            }
            return "HTTP \(statusCode)"
        }
    }

    // MARK: - Core Request

    func request(method: String, path: String, body: Data? = nil, contentType: String? = nil) throws -> HTTPResponse {
        // Create socket
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VMError.message("Failed to create socket: errno \(errno)")
        }
        defer { Darwin.close(fd) }

        // Set timeouts (30s)
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw VMError.message("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw VMError.message("Failed to connect to socket at \(socketPath): errno \(errno)")
        }

        // Build HTTP request
        var requestStr = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body = body {
            requestStr += "Content-Length: \(body.count)\r\n"
            if let ct = contentType {
                requestStr += "Content-Type: \(ct)\r\n"
            }
        }
        requestStr += "\r\n"

        // Write request
        let headerData = Data(requestStr.utf8)
        try headerData.withUnsafeBytes { ptr in
            let written = Darwin.write(fd, ptr.baseAddress!, headerData.count)
            guard written == headerData.count else {
                throw VMError.message("Failed to write request headers")
            }
        }
        if let body = body, !body.isEmpty {
            try body.withUnsafeBytes { ptr in
                let written = Darwin.write(fd, ptr.baseAddress!, body.count)
                guard written == body.count else {
                    throw VMError.message("Failed to write request body")
                }
            }
        }

        // Signal we're done writing
        Darwin.shutdown(fd, SHUT_WR)

        // Read response until EOF
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            responseData.append(contentsOf: buffer[0..<n])
        }

        guard !responseData.isEmpty else {
            throw VMError.message("Empty response from server")
        }

        // Parse using GhostVMKit's HTTPResponseParser
        let (statusCode, headers, bodyData) = try HTTPResponseParser.parseBinaryWithHeaders(responseData)
        let ct = headers["Content-Type"] ?? "application/octet-stream"

        return HTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: bodyData ?? Data(),
            contentType: ct
        )
    }

    // MARK: - Convenience Methods

    func getJSON(_ path: String) throws -> [String: Any] {
        let resp = try request(method: "GET", path: path)
        guard resp.isSuccess else {
            throw VMError.message(resp.errorMessage)
        }
        guard let json = resp.bodyJSON else {
            throw VMError.message("Invalid JSON response")
        }
        return json
    }

    func postJSON(_ path: String, body: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let resp = try request(method: "POST", path: path, body: data, contentType: "application/json")
        guard resp.isSuccess else {
            throw VMError.message(resp.errorMessage)
        }
        guard let json = resp.bodyJSON else {
            throw VMError.message("Invalid JSON response")
        }
        return json
    }

    func getBinary(_ path: String) throws -> Data {
        let resp = try request(method: "GET", path: path)
        guard resp.isSuccess else {
            throw VMError.message(resp.errorMessage)
        }
        return resp.body
    }
}
