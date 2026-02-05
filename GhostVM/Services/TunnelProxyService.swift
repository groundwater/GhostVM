import Foundation
@preconcurrency import Virtualization

/// Service that provides a Unix socket proxy for vmctl forward subprocesses
/// to connect to the guest VM's tunnel server (vsock:5001)
@MainActor
public final class TunnelProxyService: ObservableObject {
    private nonisolated(unsafe) let virtualMachine: VZVirtualMachine
    private nonisolated(unsafe) let vmQueue: DispatchQueue
    private let socketPath: String

    private nonisolated(unsafe) var serverSocket: Int32 = -1
    private nonisolated(unsafe) var _isRunning = false
    private var acceptTask: Task<Void, Never>?

    private nonisolated var isRunning: Bool {
        get { _isRunning }
    }

    private func setRunning(_ value: Bool) {
        _isRunning = value
    }

    /// Initialize the proxy service
    /// - Parameters:
    ///   - vm: The virtual machine to connect to
    ///   - queue: The VM's dispatch queue (required for vsock operations)
    ///   - bundlePath: Path to the VM bundle (used to derive socket path)
    public init(vm: VZVirtualMachine, queue: DispatchQueue, bundlePath: String) {
        self.virtualMachine = vm
        self.vmQueue = queue
        self.socketPath = TunnelProxyService.socketPath(for: bundlePath)
    }

    /// Compute the Unix socket path for a given bundle path
    /// Uses a stable hash (djb2) since String.hashValue is not stable across processes
    public static func socketPath(for bundlePath: String) -> String {
        let hash = stableHash(bundlePath)
        return "/tmp/ghostvm-tunnel-\(hash).sock"
    }

    /// djb2 hash - stable across processes unlike String.hashValue
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        return hash
    }

    /// Start the proxy service
    public func start() async throws {
        guard !isRunning else { return }

        print("[TunnelProxy] Starting on \(socketPath)")

        // Remove existing socket file if present
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create Unix domain socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw TunnelProxyError.socketCreationFailed(errno)
        }

        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path to sun_path
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { sunPath in
                for (i, byte) in pathBytes.enumerated() where i < 103 {
                    sunPath[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverSocket)
            throw TunnelProxyError.bindFailed(errno)
        }

        // Listen for connections
        guard listen(serverSocket, 10) == 0 else {
            close(serverSocket)
            throw TunnelProxyError.listenFailed(errno)
        }

        setRunning(true)
        print("[TunnelProxy] Listening on \(socketPath)")

        // Start accept loop
        acceptTask = Task.detached { [weak self] in
            await self?.acceptLoop()
        }
    }

    /// Stop the proxy service
    public func stop() {
        setRunning(false)
        acceptTask?.cancel()
        acceptTask = nil

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        // Remove socket file
        try? FileManager.default.removeItem(atPath: socketPath)

        print("[TunnelProxy] Stopped")
    }

    /// Accept loop for incoming connections
    private nonisolated func acceptLoop() async {
        while isRunning {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

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
                    print("[TunnelProxy] Accept failed: errno \(errno)")
                }
                break
            }

            // Handle each connection in its own task
            Task.detached { [weak self] in
                await self?.handleConnection(clientSocket)
            }
        }
    }

    /// Handle a single proxy connection
    /// Protocol: receives "CONNECT <port>\r\n" from vmctl forward,
    /// connects to guest vsock:5001, sends the same command, and bridges
    private nonisolated func handleConnection(_ clientSocket: Int32) async {
        defer {
            close(clientSocket)
        }

        // Read the CONNECT command from vmctl forward
        guard let command = readLine(from: clientSocket) else {
            print("[TunnelProxy] Failed to read command from client")
            return
        }

        print("[TunnelProxy] Received: \(command)")

        // Validate command format
        let parts = command.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2,
              parts[0].uppercased() == "CONNECT",
              let port = UInt16(parts[1]) else {
            sendError(clientSocket, message: "Invalid command")
            return
        }

        // Connect to guest vsock:5001
        print("[TunnelProxy] Connecting to guest TunnelServer...")
        guard let guestConnection = await connectToGuest() else {
            print("[TunnelProxy] Failed to connect to guest TunnelServer")
            sendError(clientSocket, message: "Cannot connect to guest tunnel server")
            return
        }
        let guestSocket = guestConnection.fileDescriptor
        print("[TunnelProxy] Connected to guest, fd=\(guestSocket)")

        defer {
            guestConnection.close()
        }

        // Forward the CONNECT command to guest
        let forwardCommand = "CONNECT \(port)\r\n"
        forwardCommand.withCString { ptr in
            _ = Darwin.write(guestSocket, ptr, strlen(ptr))
        }
        print("[TunnelProxy] Sent CONNECT to guest, waiting for response...")

        // Read response from guest
        guard let response = readLine(from: guestSocket) else {
            print("[TunnelProxy] No response from guest (readLine returned nil)")
            sendError(clientSocket, message: "No response from guest")
            return
        }
        print("[TunnelProxy] Guest response: \(response)")

        if response.hasPrefix("ERROR") {
            print("[TunnelProxy] Guest returned error: \(response)")
            // Forward error to client
            let errorMsg = response + "\r\n"
            errorMsg.withCString { ptr in
                _ = Darwin.write(clientSocket, ptr, strlen(ptr))
            }
            return
        }

        if !response.hasPrefix("OK") {
            print("[TunnelProxy] Unexpected guest response: \(response)")
            sendError(clientSocket, message: "Unexpected response from guest")
            return
        }

        // Send OK to client
        let ok = "OK\r\n"
        ok.withCString { ptr in
            _ = Darwin.write(clientSocket, ptr, strlen(ptr))
        }

        print("[TunnelProxy] Bridging client -> guest port \(port)")

        // Bridge the sockets
        bridgeSockets(clientSocket, guestSocket)

        print("[TunnelProxy] Connection closed for port \(port)")
    }

    /// Connect to guest vsock:5001 (tunnel server)
    /// Returns the connection object - caller must keep it alive for the duration of use
    private nonisolated func connectToGuest() async -> VZVirtioSocketConnection? {
        // ALL VZVirtualMachine access must happen on vmQueue per Apple's requirements
        do {
            let connection = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<VZVirtioSocketConnection, Error>) in
                vmQueue.async { [virtualMachine] in
                    guard let socketDevice = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
                        continuation.resume(throwing: TunnelProxyError.socketCreationFailed(-1))
                        return
                    }
                    socketDevice.connect(toPort: 5001) { result in
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
        } catch {
            print("[TunnelProxy] Failed to connect to guest: \(error)")
            return nil
        }
    }

    /// Read a line from a socket
    private nonisolated func readLine(from socket: Int32) -> String? {
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
    private nonisolated func sendError(_ socket: Int32, message: String) {
        let response = "ERROR \(message)\r\n"
        response.withCString { ptr in
            _ = Darwin.write(socket, ptr, strlen(ptr))
        }
    }

    /// Bridge two sockets bidirectionally using poll()
    private nonisolated func bridgeSockets(_ a: Int32, _ b: Int32) {
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

        while true {
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
                // Timeout - check if sockets are still valid
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

    /// Write all bytes to a socket
    private nonisolated func writeAll(_ socket: Int32, buffer: [UInt8], count: Int) -> Bool {
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

    deinit {
        _isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
        }
    }
}

// MARK: - Errors

enum TunnelProxyError: Error, LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create socket: errno \(errno)"
        case .bindFailed(let errno):
            return "Failed to bind socket: errno \(errno)"
        case .listenFailed(let errno):
            return "Failed to listen: errno \(errno)"
        }
    }
}

