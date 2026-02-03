import Foundation

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
        // Create vsock socket
        serverSocket = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
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

        isRunning = true
        onStatusChange?(true)
        print("VsockServer listening on port \(port)")

        // Accept loop
        await acceptLoop()
    }

    /// Main accept loop - runs until stopped
    private func acceptLoop() async {
        while isRunning {
            var clientAddr = sockaddr_vm(port: 0)
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            if clientSocket < 0 {
                if errno == EINTR {
                    continue
                }
                if isRunning {
                    print("Accept failed: errno \(errno)")
                }
                break
            }

            // Handle connection in a task
            Task {
                await handleConnection(clientSocket)
            }
        }
    }

    /// Handles a single client connection
    private func handleConnection(_ socket: Int32) async {
        defer {
            close(socket)
        }

        // Read the HTTP request
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = read(socket, &buffer, buffer.count)

        guard bytesRead > 0 else {
            return
        }

        let requestData = Data(buffer[0..<bytesRead])

        // Parse HTTP request
        guard let request = HTTPParser.parseRequest(requestData) else {
            let response = HTTPResponse(status: .badRequest, body: Data(#"{"error":"Invalid HTTP request"}"#.utf8))
            writeResponse(response, to: socket)
            return
        }

        // Route the request and get response
        let response = await router.handle(request)

        // Write response
        writeResponse(response, to: socket)
    }

    /// Writes an HTTP response to the socket
    private func writeResponse(_ response: HTTPResponse, to socket: Int32) {
        let responseData = HTTPParser.formatResponse(response)
        responseData.withUnsafeBytes { bufferPointer in
            _ = write(socket, bufferPointer.baseAddress!, responseData.count)
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
}
