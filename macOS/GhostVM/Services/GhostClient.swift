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

/// Response from GET /urls endpoint
public struct URLListResponse: Codable {
    public let urls: [String]
}

/// Response from GET /logs endpoint
public struct LogListResponse: Codable {
    public let logs: [String]
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
    private nonisolated(unsafe) let virtualMachine: VZVirtualMachine?
    private nonisolated(unsafe) let vmQueue: DispatchQueue?
    private let vsockPort: UInt32 = 5000
    private nonisolated(unsafe) let authToken: String?

    // For development/testing without vsock
    private nonisolated(unsafe) let tcpHost: String?
    private nonisolated(unsafe) let tcpPort: Int?

    private nonisolated(unsafe) var urlSession: URLSession?

    /// Initialize client for vsock communication with a running VM
    /// - Parameters:
    ///   - virtualMachine: The VZVirtualMachine instance
    ///   - vmQueue: The dispatch queue used for VM operations (from WindowlessVMSession.vmQueue)
    ///   - authToken: Optional authentication token
    public init(virtualMachine: VZVirtualMachine, vmQueue: DispatchQueue, authToken: String? = nil) {
        self.virtualMachine = virtualMachine
        self.vmQueue = vmQueue
        self.authToken = authToken
        self.tcpHost = nil
        self.tcpPort = nil
    }

    /// Initialize client for TCP communication (development/testing)
    public init(host: String, port: Int, authToken: String? = nil) {
        self.virtualMachine = nil
        self.vmQueue = nil
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

    /// Send a file to the guest VM (streaming - supports large files)
    /// - Parameters:
    ///   - fileURL: URL of the file to send
    ///   - relativePath: Optional relative path to preserve folder structure (e.g., "folder/subfolder/file.txt")
    ///   - progressHandler: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: The path where the file was saved in the guest
    public nonisolated func sendFile(fileURL: URL, relativePath: String? = nil, progressHandler: ((Double) -> Void)? = nil) async throws -> String {
        let pathToSend = relativePath ?? fileURL.lastPathComponent
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await sendFileViaTCP(host: tcpHost, port: tcpPort, fileURL: fileURL, relativePath: pathToSend, progressHandler: progressHandler)
        } else if let vm = virtualMachine {
            return try await sendFileViaVsock(vm: vm, fileURL: fileURL, relativePath: pathToSend, progressHandler: progressHandler)
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

    /// Clear the file queue on the guest
    public func clearFileQueue() async throws {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            try await clearFileQueueViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            try await clearFileQueueViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    // MARK: - URL Forwarding

    /// Fetch and clear pending URLs from guest (URLs to open on host)
    public func fetchPendingURLs() async throws -> [String] {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await fetchURLsViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return try await fetchURLsViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    // MARK: - Log Streaming

    /// Fetch and clear buffered logs from guest
    public func fetchLogs() async throws -> [String] {
        guard let vm = virtualMachine else {
            throw GhostClientError.notConnected
        }
        return try await fetchLogsViaVsock(vm: vm)
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
        guard let queue = self.vmQueue else {
            return false
        }

        let port = self.vsockPort

        // ALL VZVirtualMachine access must happen on vmQueue per Apple's requirements
        let connection: VZVirtioSocketConnection
        do {
            connection = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                        continuation.resume(throwing: GhostClientError.connectionFailed("No socket device"))
                        return
                    }
                    socketDevice.connect(toPort: port) { result in
                        switch result {
                        case .success(let conn):
                            continuation.resume(returning: conn)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } catch {
            return false
        }

        // Do blocking I/O on background queue - NOT on main thread!
        let fd = connection.fileDescriptor
        let result: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Send HTTP health check
                let request = "GET /health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                request.withCString { ptr in
                    _ = Darwin.write(fd, ptr, strlen(ptr))
                }
                Darwin.shutdown(fd, SHUT_WR)

                // Read response
                var buffer = [CChar](repeating: 0, count: 1024)
                let bytesRead = Darwin.read(fd, &buffer, buffer.count - 1)
                connection.close()

                if bytesRead > 0 {
                    let response = String(cString: buffer)
                    continuation.resume(returning: response.contains("200"))
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        if result {
            return true
        }
        return false
    }

    // MARK: - Raw Vsock Connection

    /// Open a raw vsock connection to the guest on the specified port.
    /// Used by persistent services (HealthCheckService, EventStreamService).
    ///
    /// IMPORTANT: The caller must hold the returned connection object alive for the
    /// duration of I/O. Letting it deallocate closes the underlying file descriptor.
    ///
    /// - Parameter port: The vsock port to connect to
    /// - Returns: The connection (use `.fileDescriptor` for I/O)
    public func connectRaw(port: UInt32) async throws -> VZVirtioSocketConnection {
        guard let vm = virtualMachine, let queue = vmQueue else {
            throw GhostClientError.notConnected
        }

        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: GhostClientError.connectionFailed("No socket device available"))
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        continuation.resume(returning: conn)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        return connection
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

    private nonisolated func sendFileViaTCP(host: String, port: Int, fileURL: URL, relativePath: String, progressHandler: ((Double) -> Void)?) async throws -> String {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        let data = try Data(contentsOf: fileURL) // TCP version still loads to memory for simplicity

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files/receive")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(relativePath, forHTTPHeaderField: "X-Filename")
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = data

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

    private func clearFileQueueViaTCP(host: String, port: Int) async throws {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files")!)
        urlRequest.httpMethod = "DELETE"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }
    }

    private func fetchURLsViaTCP(host: String, port: Int) async throws -> [String] {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/urls")!)
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
        let urlResponse = try decoder.decode(URLListResponse.self, from: data)
        return urlResponse.urls
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

    private nonisolated func sendFileViaVsock(vm: VZVirtualMachine, fileURL: URL, relativePath: String, progressHandler: ((Double) -> Void)?) async throws -> String {
        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw GhostClientError.encodingError
        }

        // Open file for reading
        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw GhostClientError.connectionFailed("Cannot open file")
        }
        defer { try? fileHandle.close() }

        guard let queue = self.vmQueue else {
            throw GhostClientError.connectionFailed("VM queue not available")
        }

        // Connect - ALL VZVirtualMachine access must happen on vmQueue per Apple's requirements
        let port = self.vsockPort
        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: GhostClientError.connectionFailed("No socket device available"))
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        continuation.resume(returning: conn)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        let fd = connection.fileDescriptor

        // Build and send HTTP headers - use relativePath to preserve folder structure
        var httpHeaders = "POST /api/v1/files/receive HTTP/1.1\r\n"
        httpHeaders += "Host: localhost\r\n"
        httpHeaders += "Connection: close\r\n"
        httpHeaders += "Content-Type: application/octet-stream\r\n"
        httpHeaders += "X-Filename: \(relativePath)\r\n"
        httpHeaders += "Content-Length: \(fileSize)\r\n"
        httpHeaders += "\r\n"

        let headerData = Data(httpHeaders.utf8)
        let headerWritten = headerData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, headerData.count)
        }
        if headerWritten < 0 {
            connection.close()
            throw GhostClientError.connectionFailed("Failed to write headers")
        }

        // Stream file in chunks
        let chunkSize = 65536
        var bytesSent: Int64 = 0

        progressHandler?(0.0)

        while bytesSent < fileSize {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            var offset = 0
            while offset < chunk.count {
                let written = chunk.withUnsafeBytes { ptr in
                    Darwin.write(fd, ptr.baseAddress! + offset, chunk.count - offset)
                }
                if written < 0 {
                    connection.close()
                    throw GhostClientError.connectionFailed("Write failed: errno \(errno)")
                }
                offset += written
            }

            bytesSent += Int64(chunk.count)
            let progress = Double(bytesSent) / Double(fileSize)
            progressHandler?(progress * 0.95) // Reserve 5% for response
        }

        // Signal end of request
        Darwin.shutdown(fd, SHUT_WR)

        // Read response
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }

        connection.close()

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

    private func clearFileQueueViaVsock(vm: VZVirtualMachine) async throws {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "DELETE",
            path: "/api/v1/files",
            body: nil
        )

        let (statusCode, _) = try parseHTTPResponse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }
    }

    private func fetchURLsViaVsock(vm: VZVirtualMachine) async throws -> [String] {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/urls",
            body: nil
        )

        let (statusCode, body) = try parseHTTPResponse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            return []
        }

        let decoder = JSONDecoder()
        let urlResponse = try decoder.decode(URLListResponse.self, from: body)
        return urlResponse.urls
    }

    private func fetchLogsViaVsock(vm: VZVirtualMachine) async throws -> [String] {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/logs",
            body: nil
        )

        let (statusCode, body) = try parseHTTPResponse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            return []
        }

        let decoder = JSONDecoder()
        let logResponse = try decoder.decode(LogListResponse.self, from: body)
        return logResponse.logs
    }

    private func sendHTTPRequest(
        vm: VZVirtualMachine,
        method: String,
        path: String,
        body: Data?,
        contentType: String? = nil,
        extraHeaders: [String: String]? = nil
    ) async throws -> Data {
        // Ensure we have the VM queue
        guard let queue = self.vmQueue else {
            throw GhostClientError.connectionFailed("VM queue not available")
        }

        // Connect to the guest on the vsock port
        // ALL VZVirtualMachine access must happen on vmQueue per Apple's requirements
        let port = self.vsockPort
        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: GhostClientError.connectionFailed("No socket device available"))
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        continuation.resume(returning: conn)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
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

        if let headers = extraHeaders {
            for (key, value) in headers {
                httpRequest += "\(key): \(value)\r\n"
            }
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

        // Get file descriptor
        let fd = connection.fileDescriptor

        // Do all blocking I/O on a background queue - NOT on main actor!
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Send request in chunks to handle large files
                let chunkSize = 65536 // 64KB chunks
                var offset = 0
                while offset < requestData.count {
                    let end = min(offset + chunkSize, requestData.count)
                    let chunk = requestData[offset..<end]
                    let bytesWritten = chunk.withUnsafeBytes { ptr in
                        Darwin.write(fd, ptr.baseAddress!, chunk.count)
                    }
                    if bytesWritten < 0 {
                        connection.close()
                        continuation.resume(throwing: GhostClientError.connectionFailed("Write failed: errno \(errno)"))
                        return
                    }
                    offset += bytesWritten
                }

                // Shutdown write side to signal end of request
                Darwin.shutdown(fd, SHUT_WR)

                // Read response
                let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                var result = Data()
                while true {
                    let chunk = fileHandle.availableData
                    if chunk.isEmpty {
                        break
                    }
                    result.append(chunk)
                }

                continuation.resume(returning: result)
            }
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

    private nonisolated func parseHTTPResponse(_ data: Data) throws -> (statusCode: Int, body: Data?) {
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
