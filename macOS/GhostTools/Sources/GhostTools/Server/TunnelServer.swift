import Foundation

/// TunnelServer listens on vsock port 5001 and handles CONNECT requests
/// from the host to bridge TCP connections to localhost services in the guest.
///
/// Protocol:
/// 1. Host sends: "CONNECT <port>\r\n"
/// 2. Server connects to localhost:<port>
/// 3. Server responds: "OK\r\n" or "ERROR <message>\r\n"
/// 4. Bidirectional bridging via poll()
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

                // Handle connection on a background GCD queue
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.handleConnection(clientSocket)
                }
            }
        }
    }

    /// Handles a single tunnel connection
    private func handleConnection(_ vsockFd: Int32) {
        print("[TunnelServer] New incoming connection from host, fd=\(vsockFd)")

        defer {
            close(vsockFd)
            print("[TunnelServer] Connection closed, fd=\(vsockFd)")
        }

        // Set non-blocking immediately
        var flags = fcntl(vsockFd, F_GETFL, 0)
        _ = fcntl(vsockFd, F_SETFL, flags | O_NONBLOCK)

        // Read the CONNECT command with poll
        var buffer = [UInt8](repeating: 0, count: 256)
        var pfd = pollfd(fd: vsockFd, events: Int16(POLLIN), revents: 0)

        let pollResult = poll(&pfd, 1, 5000) // 5 second timeout for handshake
        if pollResult < 0 {
            let err = errno
            fatalError("[TunnelServer] handleConnection poll() failed: errno=\(err) \(String(cString: strerror(err)))")
        }
        if pollResult == 0 {
            fatalError("[TunnelServer] Timeout waiting for CONNECT command from host - is PortForwardListener sending the command?")
        }

        let bytesRead = read(vsockFd, &buffer, buffer.count - 1)

        if bytesRead <= 0 {
            let err = errno
            fatalError("[TunnelServer] Failed to read CONNECT command: bytesRead=\(bytesRead) errno=\(err) \(String(cString: strerror(err)))")
        }

        // Parse "CONNECT <port>\r\n"
        guard let command = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else {
            print("[TunnelServer] ERROR: Invalid command encoding")
            sendError(vsockFd, message: "Invalid command encoding")
            return
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[TunnelServer] Received command: '\(trimmed)'")

        guard trimmed.hasPrefix("CONNECT ") else {
            print("[TunnelServer] ERROR: Expected CONNECT command, got: '\(trimmed)'")
            sendError(vsockFd, message: "Expected CONNECT command")
            return
        }

        let portString = String(trimmed.dropFirst("CONNECT ".count))
        guard let targetPort = UInt16(portString) else {
            print("[TunnelServer] ERROR: Invalid port number: '\(portString)'")
            sendError(vsockFd, message: "Invalid port number")
            return
        }

        print("[TunnelServer] Connecting to localhost:\(targetPort)...")

        // Connect to localhost on the target port
        guard let tcpFd = connectToLocalhost(port: targetPort) else {
            print("[TunnelServer] ERROR: Failed to connect to localhost:\(targetPort) - is service running?")
            sendError(vsockFd, message: "Connection refused to port \(targetPort)")
            return
        }

        print("[TunnelServer] Connected to localhost:\(targetPort), sending OK")

        // Send OK response
        let okResponse = "OK\r\n"
        let okWritten = okResponse.withCString { ptr in
            write(vsockFd, ptr, strlen(ptr))
        }
        if okWritten < 0 {
            let err = errno
            fatalError("[TunnelServer] Failed to write OK response: errno=\(err) \(String(cString: strerror(err)))")
        }

        print("[TunnelServer] Starting bidirectional bridge for port \(targetPort)")

        // Bridge the connections using poll()
        bridgeConnections(vsockFd: vsockFd, tcpFd: tcpFd)

        close(tcpFd)
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

    /// Bridge two file descriptors using two threads - simplest proven approach
    /// Each direction gets its own thread doing blocking read/write
    private func bridgeConnections(vsockFd: Int32, tcpFd: Int32) {
        // Keep sockets BLOCKING - simplest and most reliable
        // Remove any non-blocking flags that might have been set
        var flags = fcntl(vsockFd, F_GETFL, 0)
        _ = fcntl(vsockFd, F_SETFL, flags & ~O_NONBLOCK)

        flags = fcntl(tcpFd, F_GETFL, 0)
        _ = fcntl(tcpFd, F_SETFL, flags & ~O_NONBLOCK)

        let group = DispatchGroup()

        // Thread 1: vsock -> TCP
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.copyData(from: vsockFd, to: tcpFd, label: "vsock->tcp")
            Darwin.shutdown(tcpFd, SHUT_WR)  // Signal EOF to TCP peer
            group.leave()
        }

        // Thread 2: TCP -> vsock
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.copyData(from: tcpFd, to: vsockFd, label: "tcp->vsock")
            Darwin.shutdown(vsockFd, SHUT_WR)  // Signal EOF to vsock peer
            group.leave()
        }

        // Wait for both directions to complete
        group.wait()
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

    /// Simple blocking copy: read from source, write to dest, repeat until EOF
    private func copyData(from source: Int32, to dest: Int32, label: String) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var totalBytes: Int = 0

        while true {
            let bytesRead = Darwin.read(source, &buffer, buffer.count)

            if bytesRead == 0 {
                print("[TunnelServer] \(label): EOF after \(totalBytes) bytes")
                return
            }

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                if isPeerDisconnected(err) {
                    print("[TunnelServer] \(label): peer closed (errno=\(err)) after \(totalBytes) bytes")
                    return
                }
                fatalError("[TunnelServer] \(label): read failed: errno=\(err) \(String(cString: strerror(err)))")
            }

            var offset = 0
            while offset < bytesRead {
                let written = buffer.withUnsafeBytes { ptr in
                    Darwin.write(dest, ptr.baseAddress! + offset, bytesRead - offset)
                }

                if written <= 0 {
                    let err = errno
                    if err == EINTR { continue }
                    if isPeerDisconnected(err) {
                        print("[TunnelServer] \(label): peer closed during write (errno=\(err)) after \(totalBytes) bytes")
                        return
                    }
                    fatalError("[TunnelServer] \(label): write failed: errno=\(err) \(String(cString: strerror(err))) offset=\(offset)/\(bytesRead)")
                }
                offset += written
            }

            totalBytes += bytesRead
        }
    }

    /// Send an error response
    private func sendError(_ fd: Int32, message: String) {
        let response = "ERROR \(message)\r\n"
        _ = response.withCString { ptr in
            write(fd, ptr, strlen(ptr))
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
