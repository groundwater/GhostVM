import Foundation
import Virtualization

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
}

/// Response from POST /files/receive endpoint
public struct FileReceiveResponse: Codable {
    public let path: String
}

/// Response from GET /files endpoint
public struct FileListResponse: Codable {
    public let files: [String]
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

/// HTTP client for communicating with GhostTools running in the guest VM
/// Supports both vsock (production) and TCP (development) connections
@MainActor
public final class GhostClient {
    private let virtualMachine: VZVirtualMachine?
    private let vsockPort: UInt32 = 5000
    private let authToken: String?

    // For development/testing without vsock
    private let tcpHost: String?
    private let tcpPort: Int?

    private var urlSession: URLSession?

    /// Initialize client for vsock communication with a running VM
    public init(virtualMachine: VZVirtualMachine, authToken: String? = nil) {
        self.virtualMachine = virtualMachine
        self.authToken = authToken
        self.tcpHost = nil
        self.tcpPort = nil
    }

    /// Initialize client for TCP communication (development/testing)
    public init(host: String, port: Int, authToken: String? = nil) {
        self.virtualMachine = nil
        self.authToken = authToken
        self.tcpHost = host
        self.tcpPort = port

        // Create URL session for TCP connections
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.urlSession = URLSession(configuration: config)
    }

    /// Get current guest clipboard contents
    public func getClipboard() async throws -> ClipboardGetResponse {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await getClipboardViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return try await getClipboardViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    /// Set guest clipboard contents
    public func setClipboard(content: String, type: String = "public.utf8-plain-text") async throws {
        let request = ClipboardPostRequest(content: content, type: type)

        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            try await setClipboardViaTCP(host: tcpHost, port: tcpPort, request: request)
        } else if let vm = virtualMachine {
            try await setClipboardViaVsock(vm: vm, request: request)
        } else {
            throw GhostClientError.notConnected
        }
    }

    // MARK: - File Transfer

    /// Send a file to the guest VM
    /// - Parameters:
    ///   - data: The file data to send
    ///   - filename: The filename for the file in the guest
    ///   - progressHandler: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: The path where the file was saved in the guest
    public func sendFile(data: Data, filename: String, progressHandler: ((Double) -> Void)? = nil) async throws -> String {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await sendFileViaTCP(host: tcpHost, port: tcpPort, data: data, filename: filename, progressHandler: progressHandler)
        } else if let vm = virtualMachine {
            return try await sendFileViaVsock(vm: vm, data: data, filename: filename, progressHandler: progressHandler)
        } else {
            throw GhostClientError.notConnected
        }
    }

    /// Fetch a file from the guest VM
    /// - Parameter path: The file path in the guest to fetch
    /// - Returns: The file data and filename
    public func fetchFile(at path: String) async throws -> (data: Data, filename: String) {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await fetchFileViaTCP(host: tcpHost, port: tcpPort, path: path)
        } else if let vm = virtualMachine {
            return try await fetchFileViaVsock(vm: vm, path: path)
        } else {
            throw GhostClientError.notConnected
        }
    }

    /// List files available from the guest
    public func listFiles() async throws -> [String] {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await listFilesViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return try await listFilesViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    // MARK: - Health Check

    /// Check if GhostTools is running and reachable in the guest
    /// - Returns: true if the guest tools are responding, false otherwise
    public func checkHealth() async -> Bool {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return await checkHealthViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return await checkHealthViaVsock(vm: vm)
        } else {
            return false
        }
    }

    private func checkHealthViaTCP(host: String, port: Int) async -> Bool {
        guard let session = urlSession else { return false }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/health")!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 2

        do {
            let (_, response) = try await session.data(for: urlRequest)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    private func checkHealthViaVsock(vm: VZVirtualMachine) async -> Bool {
        // TODO: VZVirtioSocketDevice has threading requirements that cause crashes
        // Disable health check for now - clipboard sync will still work
        return false
    }

    // MARK: - TCP Implementation (Development)

    private func getClipboardViaTCP(host: String, port: Int) async throws -> ClipboardGetResponse {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/clipboard")!)
        urlRequest.httpMethod = "GET"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        if httpResponse.statusCode == 204 {
            throw GhostClientError.noContent
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ClipboardGetResponse.self, from: data)
        } catch {
            throw GhostClientError.decodingError
        }
    }

    private func setClipboardViaTCP(host: String, port: Int, request: ClipboardPostRequest) async throws {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/clipboard")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(request) else {
            throw GhostClientError.encodingError
        }
        urlRequest.httpBody = body

        let (_, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }
    }

    private func sendFileViaTCP(host: String, port: Int, data: Data, filename: String, progressHandler: ((Double) -> Void)?) async throws -> String {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files/receive")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        // Encode file as base64 JSON (matching existing GhostTools endpoint)
        let requestBody: [String: String] = [
            "filename": filename,
            "content": data.base64EncodedString()
        ]

        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(requestBody) else {
            throw GhostClientError.encodingError
        }
        urlRequest.httpBody = body

        // For TCP we don't have streaming progress, so report 0.5 when starting
        progressHandler?(0.5)

        let (responseData, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        progressHandler?(1.0)

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileReceiveResponse.self, from: responseData)
        return fileResponse.path
    }

    private func fetchFileViaTCP(host: String, port: Int, path: String) async throws -> (data: Data, filename: String) {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        // URL encode the path
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files/\(encodedPath)")!)
        urlRequest.httpMethod = "GET"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        // Extract filename from Content-Disposition header or use path
        var filename = URL(fileURLWithPath: path).lastPathComponent
        if let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
           let filenameMatch = contentDisposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression),
           let match = contentDisposition[filenameMatch].split(separator: "\"").dropFirst().first {
            filename = String(match)
        }

        return (data, filename)
    }

    private func listFilesViaTCP(host: String, port: Int) async throws -> [String] {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files")!)
        urlRequest.httpMethod = "GET"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileListResponse.self, from: data)
        return fileResponse.files
    }

    // MARK: - Vsock Implementation (Production)

    private func getClipboardViaVsock(vm: VZVirtualMachine) async throws -> ClipboardGetResponse {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/clipboard",
            body: nil
        )

        // Parse HTTP response
        let (statusCode, body) = try parseHTTPResponse(responseData)

        if statusCode == 204 {
            throw GhostClientError.noContent
        }

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            throw GhostClientError.noContent
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ClipboardGetResponse.self, from: body)
        } catch {
            throw GhostClientError.decodingError
        }
    }

    private func setClipboardViaVsock(vm: VZVirtualMachine, request: ClipboardPostRequest) async throws {
        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(request) else {
            throw GhostClientError.encodingError
        }

        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "POST",
            path: "/api/v1/clipboard",
            body: body,
            contentType: "application/json"
        )

        let (statusCode, _) = try parseHTTPResponse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }
    }

    private func sendFileViaVsock(vm: VZVirtualMachine, data: Data, filename: String, progressHandler: ((Double) -> Void)?) async throws -> String {
        // Encode file as base64 JSON (matching GhostTools endpoint)
        let requestBody: [String: String] = [
            "filename": filename,
            "content": data.base64EncodedString()
        ]

        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(requestBody) else {
            throw GhostClientError.encodingError
        }

        progressHandler?(0.3)

        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "POST",
            path: "/api/v1/files/receive",
            body: body,
            contentType: "application/json"
        )

        progressHandler?(0.9)

        let (statusCode, responseBody) = try parseHTTPResponse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let responseBody = responseBody else {
            throw GhostClientError.noContent
        }

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileReceiveResponse.self, from: responseBody)

        progressHandler?(1.0)

        return fileResponse.path
    }

    private func fetchFileViaVsock(vm: VZVirtualMachine, path: String) async throws -> (data: Data, filename: String) {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path

        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/files/\(encodedPath)",
            body: nil
        )

        let (statusCode, body) = try parseHTTPResponseBinary(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            throw GhostClientError.noContent
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        return (body, filename)
    }

    private func listFilesViaVsock(vm: VZVirtualMachine) async throws -> [String] {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/files",
            body: nil
        )

        let (statusCode, body) = try parseHTTPResponse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            throw GhostClientError.noContent
        }

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileListResponse.self, from: body)
        return fileResponse.files
    }

    private func sendHTTPRequest(
        vm: VZVirtualMachine,
        method: String,
        path: String,
        body: Data?,
        contentType: String? = nil
    ) async throws -> Data {
        // Get the socket device from the VM
        guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw GhostClientError.connectionFailed("No socket device available")
        }

        // Connect to the guest on the vsock port
        let connection: VZVirtioSocketConnection
        do {
            connection = try await socketDevice.connect(toPort: vsockPort)
        } catch {
            throw GhostClientError.connectionFailed(error.localizedDescription)
        }

        // Build HTTP request
        var httpRequest = "\(method) \(path) HTTP/1.1\r\n"
        httpRequest += "Host: localhost\r\n"
        httpRequest += "Connection: close\r\n"

        if let token = authToken {
            httpRequest += "Authorization: Bearer \(token)\r\n"
        }

        if let contentType = contentType {
            httpRequest += "Content-Type: \(contentType)\r\n"
        }

        if let body = body {
            httpRequest += "Content-Length: \(body.count)\r\n"
        }

        httpRequest += "\r\n"

        // Convert to data and append body if present
        var requestData = Data(httpRequest.utf8)
        if let body = body {
            requestData.append(body)
        }

        // Get file descriptor and create FileHandle for reading/writing
        let fd = connection.fileDescriptor
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)

        // Send request
        do {
            try fileHandle.write(contentsOf: requestData)
        } catch {
            connection.close()
            throw GhostClientError.connectionFailed("Failed to send request: \(error.localizedDescription)")
        }

        // Shutdown write side to signal end of request
        Darwin.shutdown(fd, SHUT_WR)

        // Read response with timeout
        let responseData: Data
        do {
            responseData = try await withTimeout(seconds: 5) {
                self.readAllData(from: fileHandle)
            }
        } catch {
            connection.close()
            throw GhostClientError.timeout
        }

        connection.close()
        return responseData
    }

    private nonisolated func readAllData(from handle: FileHandle) -> Data {
        var result = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private func parseHTTPResponse(_ data: Data) throws -> (statusCode: Int, body: Data?) {
        guard let responseString = String(data: data, encoding: .utf8) else {
            throw GhostClientError.decodingError
        }

        // Split headers and body
        let parts = responseString.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else {
            throw GhostClientError.decodingError
        }

        let headerSection = parts[0]
        let bodyString = parts.count > 1 ? parts[1] : nil

        // Parse status line
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw GhostClientError.decodingError
        }

        // Parse status code from "HTTP/1.1 200 OK"
        let statusParts = statusLine.components(separatedBy: " ")
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw GhostClientError.decodingError
        }

        let body = bodyString?.data(using: .utf8)

        return (statusCode, body)
    }

    /// Parse HTTP response preserving binary body data
    private func parseHTTPResponseBinary(_ data: Data) throws -> (statusCode: Int, body: Data?) {
        // Find the header/body separator (CRLFCRLF)
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let separatorRange = data.range(of: separator) else {
            // No body, try parsing header only
            guard let responseString = String(data: data, encoding: .utf8) else {
                throw GhostClientError.decodingError
            }

            let headerLines = responseString.components(separatedBy: "\r\n")
            guard let statusLine = headerLines.first else {
                throw GhostClientError.decodingError
            }

            let statusParts = statusLine.components(separatedBy: " ")
            guard statusParts.count >= 2,
                  let statusCode = Int(statusParts[1]) else {
                throw GhostClientError.decodingError
            }

            return (statusCode, nil)
        }

        // Parse header section
        let headerData = data[..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw GhostClientError.decodingError
        }

        let headerLines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw GhostClientError.decodingError
        }

        let statusParts = statusLine.components(separatedBy: " ")
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw GhostClientError.decodingError
        }

        // Extract binary body
        let bodyData = data[separatorRange.upperBound...]
        return (statusCode, bodyData.isEmpty ? nil : Data(bodyData))
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw GhostClientError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
