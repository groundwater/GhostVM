import Foundation

/// vmctl forward - Creates a TCP listener that bridges to the VM's tunnel proxy
/// Usage: vmctl forward <bundle-path> <host-port> [--guest-port <port>]
///
/// This command connects to the TunnelProxyService via Unix socket and bridges
/// TCP connections on host:port to localhost:guest-port inside the VM.
struct ForwardCommand {
    let bundlePath: String
    let hostPort: UInt16
    let guestPort: UInt16

    init(bundlePath: String, hostPort: UInt16, guestPort: UInt16? = nil) {
        self.bundlePath = bundlePath
        self.hostPort = hostPort
        self.guestPort = guestPort ?? hostPort
    }

    /// Run the forward command (blocks forever until killed)
    func run() throws -> Never {
        // Compute Unix socket path from bundle path
        let hash = abs(bundlePath.hashValue)
        let socketPath = "/tmp/ghostvm-tunnel-\(hash).sock"

        print("[vmctl forward] Forwarding localhost:\(hostPort) -> guest:\(guestPort)")
        print("[vmctl forward] Proxy socket: \(socketPath)")

        // Check if socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            print("Error: Tunnel proxy not running. Is the VM started?")
            exit(1)
        }

        // Create TCP listener on localhost:hostPort
        let listenerSocket = createTCPListener(port: hostPort)
        guard listenerSocket >= 0 else {
            print("Error: Cannot listen on port \(hostPort)")
            exit(1)
        }

        print("[vmctl forward] Listening on localhost:\(hostPort)")

        // Accept loop
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenerSocket, sockaddrPtr, &addrLen)
                }
            }

            if clientSocket < 0 {
                if errno == EINTR {
                    continue
                }
                print("[vmctl forward] Accept error: \(errno)")
                break
            }

            // Handle connection in background
            DispatchQueue.global().async {
                self.handleConnection(clientSocket: clientSocket, socketPath: socketPath)
            }
        }

        close(listenerSocket)
        exit(0)
    }

    /// Create a TCP listener on localhost:port
    private func createTCPListener(port: UInt16) -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            return -1
        }

        // Allow address reuse
        var optval: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult != 0 {
            close(sock)
            return -1
        }

        if listen(sock, 10) != 0 {
            close(sock)
            return -1
        }

        return sock
    }

    /// Handle a single client connection
    private func handleConnection(clientSocket: Int32, socketPath: String) {
        defer {
            close(clientSocket)
        }

        // Connect to Unix socket proxy
        let proxySocket = connectToUnixSocket(path: socketPath)
        guard proxySocket >= 0 else {
            print("[vmctl forward] Cannot connect to proxy")
            return
        }

        defer {
            close(proxySocket)
        }

        // Send CONNECT command to proxy
        let command = "CONNECT \(guestPort)\r\n"
        command.withCString { ptr in
            _ = Darwin.write(proxySocket, ptr, strlen(ptr))
        }

        // Read response
        guard let response = readLine(from: proxySocket) else {
            print("[vmctl forward] No response from proxy")
            return
        }

        if response.hasPrefix("ERROR") {
            print("[vmctl forward] Proxy error: \(response)")
            return
        }

        if !response.hasPrefix("OK") {
            print("[vmctl forward] Unexpected response: \(response)")
            return
        }

        // Bridge the sockets
        bridgeSockets(clientSocket, proxySocket)
    }

    /// Connect to a Unix domain socket
    private func connectToUnixSocket(path: String) -> Int32 {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            return -1
        }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path to sun_path
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { sunPath in
                for (i, byte) in pathBytes.enumerated() where i < 103 {
                    sunPath[i] = byte
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            close(sock)
            return -1
        }

        return sock
    }

    /// Read a line from a socket
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

    /// Bridge two sockets bidirectionally
    private func bridgeSockets(_ a: Int32, _ b: Int32) {
        // Set both sockets to non-blocking
        var flags = fcntl(a, F_GETFL, 0)
        fcntl(a, F_SETFL, flags | O_NONBLOCK)
        flags = fcntl(b, F_GETFL, 0)
        fcntl(b, F_SETFL, flags | O_NONBLOCK)

        var buffer = [UInt8](repeating: 0, count: 65536)
        let maxFd = max(a, b) + 1

        while true {
            var readSet = fd_set()
            __darwin_fd_zero(&readSet)
            __darwin_fd_set(a, &readSet)
            __darwin_fd_set(b, &readSet)

            var timeout = timeval(tv_sec: 60, tv_usec: 0)

            let ready = select(maxFd, &readSet, nil, nil, &timeout)
            if ready <= 0 {
                if ready == 0 {
                    // Timeout - check if connection is still alive
                    continue
                }
                break
            }

            // Forward data from a to b
            if __darwin_fd_isset(a, &readSet) != 0 {
                let bytesRead = read(a, &buffer, buffer.count)
                if bytesRead <= 0 {
                    break
                }
                if !writeAll(b, buffer: buffer, count: bytesRead) {
                    break
                }
            }

            // Forward data from b to a
            if __darwin_fd_isset(b, &readSet) != 0 {
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

    /// Write all bytes to a socket
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
}

// MARK: - fd_set helpers

private func __darwin_fd_zero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func __darwin_fd_set(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = fd % 32
    let mask = Int32(1 << bitOffset)

    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= mask
        }
    }
}

private func __darwin_fd_isset(_ fd: Int32, _ set: inout fd_set) -> Int32 {
    let intOffset = Int(fd / 32)
    let bitOffset = fd % 32
    let mask = Int32(1 << bitOffset)

    return withUnsafePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            (bits[intOffset] & mask) != 0 ? 1 : 0
        }
    }
}
