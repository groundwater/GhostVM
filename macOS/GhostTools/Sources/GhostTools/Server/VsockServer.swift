import Foundation
import AppKit

/// AF_VSOCK socket family constant (40 on macOS)
private let AF_VSOCK: Int32 = 40

/// VMADDR_CID_ANY - accept connections from any CID
private let VMADDR_CID_ANY: UInt32 = 0xFFFFFFFF

/// sockaddr_vm structure for vsock addressing
/// Must match the kernel's sockaddr_vm layout
struct sockaddr_vm {
    var svm_len: UInt8
    var svm_family: UInt8
    var svm_reserved1: UInt16
    var svm_port: UInt32
    var svm_cid: UInt32
    var svm_zero: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)

    init(port: UInt32, cid: UInt32 = VMADDR_CID_ANY) {
        self.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        self.svm_family = UInt8(AF_VSOCK)
        self.svm_reserved1 = 0
        self.svm_port = port
        self.svm_cid = cid
    }
}

/// Errors that can occur in the VsockServer
enum VsockServerError: Error, LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case readFailed(Int32)
    case writeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create socket: errno \(errno)"
        case .bindFailed(let errno):
            return "Failed to bind socket: errno \(errno)"
        case .listenFailed(let errno):
            return "Failed to listen: errno \(errno)"
        case .acceptFailed(let errno):
            return "Failed to accept connection: errno \(errno)"
        case .readFailed(let errno):
            return "Failed to read from socket: errno \(errno)"
        case .writeFailed(let errno):
            return "Failed to write to socket: errno \(errno)"
        }
    }
}

/// A simple vsock server that listens for connections from the host
final class VsockServer: @unchecked Sendable {
    private let port: UInt32
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let router: Router

    /// Tracks file paths per batch ID for batched Finder reveal
    private var batchFiles: [String: [URL]] = [:]
    private let batchLock = NSLock()

    /// Status callback for connection state changes
    var onStatusChange: ((Bool) -> Void)?

    init(port: UInt32 = 80, router: Router) {
        self.port = port
        self.router = router
    }

    deinit {
        stop()
    }

    /// Starts the vsock server
    func start() async throws {
        print("[VsockServer] Creating socket with AF_VSOCK=\(AF_VSOCK), SOCK_STREAM=\(SOCK_STREAM)")
        // Create vsock socket
        serverSocket = socket(AF_VSOCK, SOCK_STREAM, 0)
        print("[VsockServer] socket() returned: \(serverSocket), errno: \(errno)")
        guard serverSocket >= 0 else {
            print("[VsockServer] Socket creation failed! errno=\(errno)")
            throw VsockServerError.socketCreationFailed(errno)
        }

        // Set socket options for reuse
        var optval: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        // Bind to vsock address
        var addr = sockaddr_vm(port: port)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverSocket)
            throw VsockServerError.bindFailed(errno)
        }

        // Listen for connections
        guard listen(serverSocket, 10) == 0 else {
            close(serverSocket)
            throw VsockServerError.listenFailed(errno)
        }

        // Keep socket BLOCKING — kqueue/poll don't fire for AF_VSOCK on macOS guests
        isRunning = true
        onStatusChange?(true)
        print("VsockServer listening on port \(port)")

        // Blocking accept loop on dedicated GCD thread (not async Task — would block cooperative pool)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while self?.isRunning == true {
                var clientAddr = sockaddr_vm(port: 0)
                var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(self?.serverSocket ?? -1, sockaddrPtr, &addrLen)
                    }
                }

                if clientSocket < 0 {
                    if errno == EINTR { continue }
                    break // socket closed by stop()
                }

                // Handle connection in a task
                Task {
                    await self?.handleConnection(clientSocket)
                }
            }
        }
    }

    /// Handles a single client connection
    private func handleConnection(_ socket: Int32) async {
        defer {
            close(socket)
        }

        // Read headers first
        guard let (headers, initialBody) = readHTTPHeaders(from: socket) else {
            return
        }

        // Parse the request line and headers
        guard let request = HTTPParser.parseRequest(headers) else {
            let response = HTTPResponse(status: .badRequest, body: Data(#"{"error":"Invalid HTTP request"}"#.utf8))
            writeResponse(response, to: socket)
            return
        }

        // Check if this is a streaming file upload
        if request.path == "/api/v1/files/receive" && request.method == .POST {
            let response = await handleStreamingFileReceive(
                request: request,
                socket: socket,
                initialBody: initialBody
            )
            writeResponse(response, to: socket)
            return
        }

        // For other requests, read the full body if needed
        let contentLength = Int(request.header("Content-Length") ?? "0") ?? 0
        var fullBody = initialBody

        if contentLength > initialBody.count {
            let remaining = contentLength - initialBody.count
            if let moreData = readExactBytes(from: socket, count: remaining) {
                fullBody.append(moreData)
            }
        }

        // Create request with full body
        let fullRequest = HTTPRequest(
            method: request.method,
            path: request.path,
            headers: request.headers,
            body: fullBody.isEmpty ? nil : fullBody
        )

        // Route the request and get response
        let response = await router.handle(fullRequest)

        // Write response
        writeResponse(response, to: socket)
    }

    /// Handle streaming file upload - writes directly to disk
    private func handleStreamingFileReceive(
        request: HTTPRequest,
        socket: Int32,
        initialBody: Data
    ) async -> HTTPResponse {
        let rawFilename = request.header("X-Filename") ?? "received_file_\(Int(Date().timeIntervalSince1970))"
        let contentLength = Int(request.header("Content-Length") ?? "0") ?? 0

        // Sanitize the path to prevent traversal while preserving folder structure
        let filename = sanitizeRelativePath(rawFilename)

        print("[VsockServer] Streaming file receive: \(filename) (\(contentLength) bytes)")

        // Base directory for received files
        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("GhostVM")

        let destURL = baseURL.appendingPathComponent(filename)

        // Create ALL intermediate directories (including subfolders in the relative path)
        let parentDir = destURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            print("[VsockServer] Failed to create directory: \(parentDir.path) - \(error)")
            return HTTPResponse.error(.internalServerError, message: "Failed to create directory: \(error.localizedDescription)")
        }

        FileManager.default.createFile(atPath: destURL.path, contents: nil)

        guard let fileHandle = FileHandle(forWritingAtPath: destURL.path) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to create file")
        }

        defer {
            try? fileHandle.close()
        }

        // Write initial body data
        var bytesWritten = 0
        if !initialBody.isEmpty {
            do {
                try fileHandle.write(contentsOf: initialBody)
                bytesWritten += initialBody.count
            } catch {
                return HTTPResponse.error(.internalServerError, message: "Failed to write file")
            }
        }

        // Stream remaining data directly to file
        var buffer = [UInt8](repeating: 0, count: 65536)
        while bytesWritten < contentLength {
            let toRead = min(buffer.count, contentLength - bytesWritten)
            let bytesRead = read(socket, &buffer, toRead)

            if bytesRead <= 0 {
                print("[VsockServer] Read error or EOF at \(bytesWritten)/\(contentLength)")
                break
            }

            do {
                try fileHandle.write(contentsOf: buffer[0..<bytesRead])
                bytesWritten += bytesRead

                // Progress logging every 10MB
                if bytesWritten % (10 * 1024 * 1024) < 65536 {
                    let mb = bytesWritten / (1024 * 1024)
                    let totalMB = contentLength / (1024 * 1024)
                    print("[VsockServer] Progress: \(mb)/\(totalMB) MB")
                }
            } catch {
                return HTTPResponse.error(.internalServerError, message: "Failed to write file")
            }
        }

        print("[VsockServer] File saved: \(destURL.path) (\(bytesWritten) bytes)")

        // Apply permissions if provided
        if let permStr = request.header("X-Permissions"),
           let mode = Int(permStr, radix: 8) {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: destURL.path)
        }

        // Batch reveal: accumulate paths per batch, reveal on last file
        let batchID = request.header("X-Batch-ID")
        let isLastInBatch = request.header("X-Batch-Last") == "true"

        if let batchID = batchID {
            batchLock.lock()
            batchFiles[batchID, default: []].append(destURL)
            if isLastInBatch {
                let allFiles = batchFiles.removeValue(forKey: batchID) ?? [destURL]
                batchLock.unlock()
                // Compute top-level items to reveal
                let topLevelURLs = computeTopLevelItems(allFiles, baseURL: baseURL)
                NSWorkspace.shared.activateFileViewerSelecting(topLevelURLs)
            } else {
                batchLock.unlock()
            }
        } else {
            // No batch — reveal this single file
            NSWorkspace.shared.activateFileViewerSelecting([destURL])
        }

        let response = FileReceiveResponse(path: destURL.path)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    /// Reads HTTP headers and returns them along with any body data already read
    private func readHTTPHeaders(from socket: Int32) -> (headers: Data, initialBody: Data)? {
        var headerData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let headerEnd = Data("\r\n\r\n".utf8)

        while true {
            let bytesRead = read(socket, &buffer, buffer.count)
            if bytesRead <= 0 {
                return headerData.isEmpty ? nil : (headerData, Data())
            }

            headerData.append(contentsOf: buffer[0..<bytesRead])

            // Check for end of headers
            if let range = headerData.range(of: headerEnd) {
                let headers = headerData[..<range.upperBound]
                let body = headerData[range.upperBound...]
                return (Data(headers), Data(body))
            }

            // Safety: headers shouldn't be more than 64KB
            if headerData.count > 65536 {
                return nil
            }
        }
    }

    /// Reads exactly `count` bytes from socket
    private func readExactBytes(from socket: Int32, count: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(65536, count))

        while data.count < count {
            let toRead = min(buffer.count, count - data.count)
            let bytesRead = read(socket, &buffer, toRead)
            if bytesRead <= 0 {
                break
            }
            data.append(contentsOf: buffer[0..<bytesRead])
        }

        return data
    }

    /// Writes an HTTP response to the socket
    private func writeResponse(_ response: HTTPResponse, to socket: Int32) {
        let responseData = HTTPParser.formatResponse(response)
        responseData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            var offset = 0
            while offset < responseData.count {
                let bytesWritten = write(socket, baseAddress.advanced(by: offset), responseData.count - offset)
                if bytesWritten < 0 {
                    if errno == EINTR { continue }
                    print("[VsockServer] write failed: errno \(errno)")
                    return
                }
                if bytesWritten == 0 { return }
                offset += bytesWritten
            }
        }
    }

    /// Stops the server
    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        onStatusChange?(false)
    }

    /// Given a list of file URLs under baseURL, returns the unique top-level items (files or folders)
    /// For example, if files are baseURL/MyApp.app/Contents/MacOS/binary and baseURL/MyApp.app/Contents/Info.plist,
    /// this returns [baseURL/MyApp.app]
    private func computeTopLevelItems(_ urls: [URL], baseURL: URL) -> [URL] {
        let basePath = baseURL.path
        var topLevelNames = Set<String>()
        for url in urls {
            let relativePath = String(url.path.dropFirst(basePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let firstComponent = relativePath.components(separatedBy: "/").first ?? relativePath
            if !firstComponent.isEmpty {
                topLevelNames.insert(firstComponent)
            }
        }
        return topLevelNames.map { baseURL.appendingPathComponent($0) }
    }

    /// Sanitize a relative path, preserving folder structure but preventing traversal attacks
    private func sanitizeRelativePath(_ path: String) -> String {
        // Split into components and filter out dangerous ones
        let components = path.components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { $0.replacingOccurrences(of: "..", with: "_").replacingOccurrences(of: "\\", with: "_") }

        // Ensure we have at least a filename
        if components.isEmpty {
            return "unnamed"
        }

        return components.joined(separator: "/")
    }
}
