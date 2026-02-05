import Foundation

/// Errors that can occur in the TunnelServer
enum TunnelServerError: Error, LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case connectionFailed(String)
    case protocolError(String)

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
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .protocolError(let reason):
            return "Protocol error: \(reason)"
        }
    }
}

/// A vsock server that tunnels connections to localhost ports
/// Protocol: "CONNECT <port>\r\n" -> "OK\r\n" or "ERROR <msg>\r\n"
final class TunnelServer: @unchecked Sendable {
    private let port: UInt32 = 5001
    private var serverSocket: Int32 = -1
    private var isRunning = false

    init() {}

    deinit {
        stop()
    }

    /// Starts the tunnel server on vsock port 5001
    func start() async throws {
        print("[TunnelServer] Creating socket with AF_VSOCK=40, SOCK_STREAM=\(SOCK_STREAM)")

        // Create vsock socket
        serverSocket = socket(40, SOCK_STREAM, 0)  // AF_VSOCK = 40
        guard serverSocket >= 0 else {
            print("[TunnelServer] Socket creation failed! errno=\(errno)")
            throw TunnelServerError.socketCreationFailed(errno)
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
            throw TunnelServerError.bindFailed(errno)
        }

        // Listen for connections
        guard listen(serverSocket, 10) == 0 else {
            close(serverSocket)
            throw TunnelServerError.listenFailed(errno)
        }

        isRunning = true
        print("[TunnelServer] Listening on vsock port \(port)")

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
                    print("[TunnelServer] Accept failed: errno \(errno)")
                }
                break
            }

            // Handle connection in a task
            Task {
                await handleConnection(clientSocket)
            }
        }
    }

    /// Handles a single tunnel connection
    private func handleConnection(_ socket: Int32) async {
        defer {
            close(socket)
        }

        // Read the CONNECT command
        guard let command = readLine(from: socket) else {
            print("[TunnelServer] Failed to read command")
            return
        }

        log("[TunnelServer] Received command: \(command)")

        // Parse "CONNECT <port>"
        let parts = command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2,
              parts[0].uppercased() == "CONNECT",
              let targetPort = UInt16(parts[1]) else {
            sendError(socket, message: "Invalid command. Use: CONNECT <port>")
            return
        }

        // Connect to localhost:targetPort
        let targetSocket = connectToLocalhost(port: targetPort)
        guard targetSocket >= 0 else {
            sendError(socket, message: "Cannot connect to localhost:\(targetPort)")
            return
        }

        // Send OK response
        let ok = "OK\r\n"
        ok.withCString { ptr in
            _ = Darwin.write(socket, ptr, strlen(ptr))
        }

        log("[TunnelServer] Bridging vsock -> localhost:\(targetPort)")

        // Bridge the two sockets bidirectionally
        bridgeSockets(socket, targetSocket)

        close(targetSocket)
        log("[TunnelServer] Tunnel closed for port \(targetPort)")
    }

    /// Read a line (up to \r\n or \n) from a socket
    private func readLine(from socket: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        var result = ""

        while result.count < 256 {
            let bytesRead = read(socket, &buffer, 1)
            if bytesRead <= 0 {
                break
            }

            let char = Character(UnicodeScalar(buffer[0]))
            if char == "\n" {
                break
            }
            if char != "\r" {
                result.append(char)
            }
        }

        return result.isEmpty ? nil : result
    }

    /// Send an error response
    private func sendError(_ socket: Int32, message: String) {
        let response = "ERROR \(message)\r\n"
        response.withCString { ptr in
            _ = Darwin.write(socket, ptr, strlen(ptr))
        }
    }

    /// Connect to localhost on the specified port (tries IPv4 first, then IPv6)
    private func connectToLocalhost(port: UInt16) -> Int32 {
        // Try IPv4 first
        log("[TunnelServer] Trying IPv4 127.0.0.1:\(port)...")
        if let sock = connectToIPv4(port: port) {
            log("[TunnelServer] IPv4 connected!")
            return sock
        }
        log("[TunnelServer] IPv4 failed (errno=\(errno)), trying IPv6...")
        // Fall back to IPv6
        if let sock = connectToIPv6(port: port) {
            log("[TunnelServer] IPv6 connected!")
            return sock
        }
        log("[TunnelServer] IPv6 also failed (errno=\(errno))")
        return -1
    }

    private func connectToIPv4(port: UInt16) -> Int32? {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            close(sock)
            return nil
        }
        return sock
    }

    private func connectToIPv6(port: UInt16) -> Int32? {
        let sock = socket(AF_INET6, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_loopback

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }

        if result != 0 {
            close(sock)
            return nil
        }
        return sock
    }

    /// Bridge two sockets bidirectionally using poll()
    private func bridgeSockets(_ a: Int32, _ b: Int32) {
        // Set both sockets to non-blocking
        var flags = fcntl(a, F_GETFL, 0)
        fcntl(a, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(b, F_GETFL, 0)
        fcntl(b, F_SETFL, flags | O_NONBLOCK)

        var buffer = [UInt8](repeating: 0, count: 65536)

        // Use poll() instead of select() - simpler and no fd_set size limits
        var fds: [pollfd] = [
            pollfd(fd: a, events: Int16(POLLIN), revents: 0),
            pollfd(fd: b, events: Int16(POLLIN), revents: 0)
        ]

        while isRunning {
            // Reset revents
            fds[0].revents = 0
            fds[1].revents = 0

            let ready = poll(&fds, 2, 30000)  // 30 second timeout
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            if ready == 0 {
                // Timeout - continue to check if still running
                continue
            }

            // Check for errors or hangup on either socket
            let errorMask = Int16(POLLERR | POLLHUP | POLLNVAL)
            if (fds[0].revents & errorMask) != 0 || (fds[1].revents & errorMask) != 0 {
                break
            }

            // Forward data from a to b
            if (fds[0].revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(a, &buffer, buffer.count)
                if bytesRead <= 0 {
                    break
                }
                if !writeAll(b, buffer: buffer, count: bytesRead) {
                    break
                }
            }

            // Forward data from b to a
            if (fds[1].revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(b, &buffer, buffer.count)
                if bytesRead <= 0 {
                    break
                }
                if !writeAll(a, buffer: buffer, count: bytesRead) {
                    break
                }
            }
        }
    }

    /// Write all bytes to a socket, handling partial writes
    private func writeAll(_ socket: Int32, buffer: [UInt8], count: Int) -> Bool {
        var written = 0
        while written < count {
            let result = buffer.withUnsafeBufferPointer { ptr in
                Darwin.write(socket, ptr.baseAddress! + written, count - written)
            }
            if result <= 0 {
                return false
            }
            written += result
        }
        return true
    }

    /// Stops the server
    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
}

