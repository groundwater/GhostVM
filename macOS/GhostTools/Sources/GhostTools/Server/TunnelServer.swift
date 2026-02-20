import Foundation

/// TunnelServer listens on vsock port 5001 and handles CONNECT requests
/// from the host to bridge TCP connections to localhost services in the guest.
///
/// Protocol:
/// 1. Host sends: "CONNECT <port>\r\n"
/// 2. Server connects to localhost:<port>
/// 3. Server responds: "OK\r\n" or "ERROR <message>\r\n"
/// 4. Bidirectional bridging via async nonblocking I/O
final class TunnelServer: @unchecked Sendable {
    private let port: UInt32 = 5001
    private var serverSocket: Int32 = -1
    private var isRunning = false

    /// Status callback for connection state changes
    var onStatusChange: ((Bool) -> Void)?

    init() {}

    deinit {
        stop()
    }

    /// Starts the tunnel server
    func start() async throws {
        print("[TunnelServer] Creating socket on port \(port)")

        // Create vsock socket
        serverSocket = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("[TunnelServer] Socket creation failed! errno=\(errno)")
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
        guard listen(serverSocket, 128) == 0 else {
            close(serverSocket)
            throw VsockServerError.listenFailed(errno)
        }

        // Keep socket BLOCKING — kqueue/poll don't fire for AF_VSOCK on macOS guests
        isRunning = true
        onStatusChange?(true)
        print("[TunnelServer] Listening on vsock port \(port)")

        // Blocking accept loop on dedicated thread
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

                Task { [weak self] in
                    await self?.handleConnection(clientSocket)
                }
            }
        }
    }

    /// Handles a single tunnel connection
    private func handleConnection(_ vsockFd: Int32) async {
        print("[TunnelServer] New incoming connection from host, fd=\(vsockFd)")

        let vsockIO = AsyncVSockIO(fd: vsockFd, ownsFD: true)
        defer {
            vsockIO.close()
            print("[TunnelServer] Connection closed, fd=\(vsockFd)")
        }

        let commandData: Data
        do {
            commandData = try await readHandshakeCommand(vsockIO)
        } catch let error as HandshakeReadError {
            switch error {
            case .timeout:
                fatalError("[TunnelServer] Timeout waiting for CONNECT command from host - is PortForwardListener sending the command?")
            case .eof:
                fatalError("[TunnelServer] Failed to read CONNECT command: bytesRead=0 errno=0 EOF")
            case .transport(let ioError):
                fatalError("[TunnelServer] Failed to read CONNECT command: \(describe(error: ioError))")
            }
        } catch {
            fatalError("[TunnelServer] Failed to read CONNECT command: unexpected error \(error)")
        }

        // Parse "CONNECT <port>\r\n"
        guard let command = String(data: commandData, encoding: .utf8) else {
            print("[TunnelServer] ERROR: Invalid command encoding")
            await sendError(vsockIO, message: "Invalid command encoding")
            return
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[TunnelServer] Received command: '\(trimmed)'")

        guard trimmed.hasPrefix("CONNECT ") else {
            print("[TunnelServer] ERROR: Expected CONNECT command, got: '\(trimmed)'")
            await sendError(vsockIO, message: "Expected CONNECT command")
            return
        }

        let portString = String(trimmed.dropFirst("CONNECT ".count))
        guard let targetPort = UInt16(portString) else {
            print("[TunnelServer] ERROR: Invalid port number: '\(portString)'")
            await sendError(vsockIO, message: "Invalid port number")
            return
        }

        print("[TunnelServer] Connecting to localhost:\(targetPort)...")

        // Connect to localhost on the target port
        guard let tcpFd = connectToLocalhost(port: targetPort) else {
            print("[TunnelServer] ERROR: Failed to connect to localhost:\(targetPort) - is service running?")
            await sendError(vsockIO, message: "Connection refused to port \(targetPort)")
            return
        }
        let tcpIO = AsyncVSockIO(fd: tcpFd, ownsFD: true)

        print("[TunnelServer] Connected to localhost:\(targetPort), sending OK")

        // Send OK response
        do {
            try await vsockIO.writeAll(Data("OK\r\n".utf8))
        } catch {
            fatalError("[TunnelServer] Failed to write OK response: \(describe(error: error))")
        }

        print("[TunnelServer] Starting bidirectional bridge for port \(targetPort)")

        do {
            try await pipeBidirectional(vsockIO, tcpIO)
        } catch {
            if isExpectedBridgeError(error) {
                print("[TunnelServer] Bridge closed: \(describe(error: error))")
            } else {
                fatalError("[TunnelServer] Bridge failed unexpectedly: \(describe(error: error))")
            }
        }
    }

    /// Connect to localhost on the specified port
    private func connectToLocalhost(port: UInt16) -> Int32? {
        // Try IPv4 first
        if let fd = connectIPv4(port: port) {
            return fd
        }

        // Fall back to IPv6
        return connectIPv6(port: port)
    }

    private func connectIPv4(port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // Set TCP_NODELAY to disable Nagle's algorithm
        var optval: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return fd
        }

        close(fd)
        return nil
    }

    private func connectIPv6(port: UInt16) -> Int32? {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // Set TCP_NODELAY to disable Nagle's algorithm
        var optval: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }

        if result == 0 {
            return fd
        }

        close(fd)
        return nil
    }

    /// Error codes that indicate peer disconnected (not a bug)
    private func isPeerDisconnected(_ err: Int32) -> Bool {
        switch err {
        case ECONNRESET,  // Connection reset by peer
             EPIPE,       // Broken pipe
             ENOTCONN,    // Socket not connected
             ESHUTDOWN,   // Can't send after socket shutdown
             ECONNABORTED, // Connection aborted
             EHOSTUNREACH, // Host unreachable
             ENETUNREACH,  // Network unreachable
             ETIMEDOUT:    // Connection timed out
            return true
        default:
            return false
        }
    }

    private func isExpectedBridgeError(_ error: Error) -> Bool {
        if let ioError = error as? AsyncVSockIOError {
            switch ioError {
            case .closed, .cancelled:
                return true
            case .syscall(_, let err):
                return isPeerDisconnected(err)
            default:
                return false
            }
        }
        return false
    }

    /// Send an error response
    private func sendError(_ io: AsyncVSockIO, message: String) async {
        let response = "ERROR \(message)\r\n"
        do {
            try await io.writeAll(Data(response.utf8))
        } catch {
            print("[TunnelServer] Failed to send error response: \(describe(error: error))")
        }
    }

    private enum HandshakeReadError: Error {
        case timeout
        case eof
        case transport(AsyncVSockIOError)
    }

    private func readHandshakeCommand(_ io: AsyncVSockIO) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do {
                    guard let data = try await io.read(maxBytes: 255), !data.isEmpty else {
                        throw HandshakeReadError.eof
                    }
                    return data
                } catch let error as AsyncVSockIOError {
                    throw HandshakeReadError.transport(error)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw HandshakeReadError.timeout
            }

            do {
                let first = try await group.next()!
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func describe(error: Error) -> String {
        if let ioError = error as? AsyncVSockIOError {
            switch ioError {
            case .closed:
                return "closed"
            case .eofBeforeExpected(let expected, let received):
                return "eofBeforeExpected expected=\(expected) received=\(received)"
            case .interrupted:
                return "interrupted"
            case .wouldBlock:
                return "wouldBlock"
            case .syscall(let op, let err):
                return "syscall \(op) failed: errno=\(err) \(String(cString: strerror(err)))"
            case .cancelled:
                return "cancelled"
            }
        }
        return String(describing: error)
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
