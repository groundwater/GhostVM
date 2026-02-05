import Foundation
import Virtualization

/// Errors that can occur in port forwarding
enum PortForwardError: Error, LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create socket: errno \(errno)"
        case .bindFailed(let errno):
            return "Failed to bind socket: errno \(errno)"
        case .listenFailed(let errno):
            return "Failed to listen: errno \(errno)"
        case .connectFailed(let reason):
            return "Connection failed: \(reason)"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        }
    }
}

/// Listens on a host TCP port and forwards connections to the guest VM via vsock.
///
/// Each incoming TCP connection triggers:
/// 1. Vsock connection to guest on port 5001
/// 2. Send "CONNECT <guestPort>\r\n"
/// 3. Wait for "OK\r\n"
/// 4. Bridge TCP <-> vsock bidirectionally
final class PortForwardListener: @unchecked Sendable {
    private let hostPort: UInt16
    private let guestPort: UInt16
    private let vmQueue: DispatchQueue
    private let virtualMachine: VZVirtualMachine

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var isRunning = false
    private var activeConnections = 0
    private let connectionLock = NSLock()

    /// The vsock port where TunnelServer listens in the guest
    private let tunnelServerPort: UInt32 = 5001

    init(hostPort: UInt16, guestPort: UInt16, vm: VZVirtualMachine, queue: DispatchQueue) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.virtualMachine = vm
        self.vmQueue = queue
    }

    deinit {
        stop()
    }

    /// Start listening on the host port
    func start() throws {
        guard !isRunning else { return }

        // Create TCP socket
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw PortForwardError.socketCreationFailed(errno)
        }

        // Set socket options
        var optval: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))
        // TCP_NODELAY to disable Nagle's algorithm
        setsockopt(serverSocket, IPPROTO_TCP, TCP_NODELAY, &optval, socklen_t(MemoryLayout<Int32>.size))

        // Bind to localhost:hostPort
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = hostPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverSocket)
            serverSocket = -1
            throw PortForwardError.bindFailed(errno)
        }

        // Listen
        guard listen(serverSocket, 128) == 0 else {
            close(serverSocket)
            serverSocket = -1
            throw PortForwardError.listenFailed(errno)
        }

        // Set non-blocking for the server socket
        var flags = fcntl(serverSocket, F_GETFL, 0)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        // Create DispatchSource for accept
        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global(qos: .userInitiated))
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }

        isRunning = true
        acceptSource?.resume()

        print("[PortForwardListener] Listening on localhost:\(hostPort) -> guest:\(guestPort)")
    }

    /// Stop listening and close all connections
    func stop() {
        guard isRunning else { return }
        isRunning = false

        acceptSource?.cancel()
        acceptSource = nil

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        print("[PortForwardListener] Stopped forwarding localhost:\(hostPort)")
    }

    /// Accept all pending connections (called from DispatchSource)
    private func acceptConnections() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            if clientSocket < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // No more connections to accept
                    return
                }
                if err == EINTR {
                    continue
                }
                // CRASH with full details
                let msg = "[PortForwardListener] accept() FAILED: errno=\(err) (\(String(cString: strerror(err)))) serverSocket=\(serverSocket)"
                print(msg)
                fatalError(msg)
            }

            // Set TCP_NODELAY on accepted socket
            var optval: Int32 = 1
            setsockopt(clientSocket, IPPROTO_TCP, TCP_NODELAY, &optval, socklen_t(MemoryLayout<Int32>.size))

            // Handle connection on a background GCD queue (not Swift concurrency)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleConnection(clientSocket)
            }
        }
    }

    /// Handle a single forwarded connection
    private func handleConnection(_ tcpFd: Int32) {
        connectionLock.lock()
        activeConnections += 1
        let connCount = activeConnections
        connectionLock.unlock()

        print("[PortForwardListener] [1] New connection on port \(hostPort) -> guest:\(guestPort) (active=\(connCount))")

        defer {
            print("[PortForwardListener] [DEFER] Closing tcpFd=\(tcpFd)")
            close(tcpFd)
            connectionLock.lock()
            activeConnections -= 1
            let remaining = activeConnections
            connectionLock.unlock()
            print("[PortForwardListener] [DEFER-DONE] Connection closed for port \(hostPort) (active=\(remaining))")
        }

        // Set TCP socket to non-blocking
        print("[PortForwardListener] [2] Setting TCP non-blocking")
        var flags = fcntl(tcpFd, F_GETFL, 0)
        _ = fcntl(tcpFd, F_SETFL, flags | O_NONBLOCK)

        // Connect to guest TunnelServer via vsock
        print("[PortForwardListener] [3] Creating semaphore")
        let semaphore = DispatchSemaphore(value: 0)
        var connection: VZVirtioSocketConnection?
        var connectError: Error?

        print("[PortForwardListener] [4] Capturing VM reference")
        let vm = self.virtualMachine
        let port = self.tunnelServerPort

        print("[PortForwardListener] [5] Dispatching to vmQueue for vsock connect to port \(port)...")

        vmQueue.async {
            print("[PortForwardListener] [6-vmQueue] Getting socket device")
            guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                print("[PortForwardListener] [6-vmQueue] NO SOCKET DEVICE!")
                connectError = PortForwardError.connectFailed("No socket device - VM may not have vsock configured")
                semaphore.signal()
                return
            }
            print("[PortForwardListener] [7-vmQueue] Calling socketDevice.connect()")
            socketDevice.connect(toPort: port) { result in
                print("[PortForwardListener] [8-callback] Connect callback received")
                switch result {
                case .success(let conn):
                    print("[PortForwardListener] [8-callback] Success, fd=\(conn.fileDescriptor)")
                    connection = conn
                case .failure(let error):
                    print("[PortForwardListener] [8-callback] Failure: \(error)")
                    connectError = error
                }
                semaphore.signal()
            }
            print("[PortForwardListener] [7-vmQueue] connect() returned, waiting for callback")
        }

        // Wait for connection with timeout
        print("[PortForwardListener] [9] Waiting on semaphore with 5s timeout")
        let timeout = DispatchTime.now() + .seconds(5)
        let waitResult = semaphore.wait(timeout: timeout)
        print("[PortForwardListener] [10] Semaphore returned: \(waitResult == .timedOut ? "TIMEOUT" : "signaled")")

        if waitResult == .timedOut {
            print("[PortForwardListener] [10-TIMEOUT] Timeout connecting to guest vsock - TunnelServer may not be running")
            return  // TCP connection will be closed by defer
        }

        print("[PortForwardListener] [11] Checking connectError")
        if let error = connectError {
            print("[PortForwardListener] [11-ERROR] Failed to connect to guest: \(error)")
            return  // TCP connection will be closed by defer
        }

        print("[PortForwardListener] [12] Unwrapping connection")
        guard let conn = connection else {
            print("[PortForwardListener] [12-NIL] No connection returned from vsock connect")
            return  // TCP connection will be closed by defer
        }

        print("[PortForwardListener] [13] Getting fileDescriptor")
        let vsockFd = conn.fileDescriptor
        print("[PortForwardListener] [14] Connected to guest vsock, fd=\(vsockFd)")

        // Set vsock to non-blocking
        print("[PortForwardListener] [15] Setting vsock non-blocking")
        flags = fcntl(vsockFd, F_GETFL, 0)
        _ = fcntl(vsockFd, F_SETFL, flags | O_NONBLOCK)

        // Send CONNECT command
        print("[PortForwardListener] [16] Sending CONNECT command")
        let connectCmd = "CONNECT \(guestPort)\r\n"
        let cmdWritten = connectCmd.withCString { ptr in
            Darwin.write(vsockFd, ptr, strlen(ptr))
        }
        print("[PortForwardListener] [17] CONNECT write returned \(cmdWritten)")

        if cmdWritten < 0 {
            let err = errno
            print("[PortForwardListener] [17-ERROR] Failed to send CONNECT command: errno=\(err) \(String(cString: strerror(err)))")
            conn.close()
            return
        }

        // Read response with poll
        print("[PortForwardListener] [18] Polling for response")
        var buffer = [UInt8](repeating: 0, count: 256)
        var pfd = pollfd(fd: vsockFd, events: Int16(POLLIN), revents: 0)

        let pollResult = poll(&pfd, 1, 5000) // 5 second timeout
        print("[PortForwardListener] [19] poll() returned \(pollResult)")

        if pollResult < 0 {
            let err = errno
            print("[PortForwardListener] [19-ERROR] poll() failed: errno=\(err) \(String(cString: strerror(err)))")
            conn.close()
            return
        }
        if pollResult == 0 {
            print("[PortForwardListener] [19-TIMEOUT] Timeout waiting for CONNECT response")
            conn.close()
            return
        }

        print("[PortForwardListener] [20] Reading response")
        let bytesRead = Darwin.read(vsockFd, &buffer, buffer.count - 1)
        print("[PortForwardListener] [21] Read returned \(bytesRead)")

        if bytesRead <= 0 {
            let err = errno
            print("[PortForwardListener] [21-ERROR] Failed to read CONNECT response: bytesRead=\(bytesRead) errno=\(err)")
            conn.close()
            return
        }

        print("[PortForwardListener] [22] Decoding response")
        guard let response = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else {
            print("[PortForwardListener] [22-ERROR] Invalid CONNECT response encoding")
            conn.close()
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[PortForwardListener] [23] Response: '\(trimmed)'")

        if trimmed != "OK" {
            print("[PortForwardListener] [23-REFUSED] Guest refused connection: '\(trimmed)'")
            conn.close()
            return
        }

        // Bridge the connections
        print("[PortForwardListener] [24] Starting bridge")
        bridgeConnections(tcpFd: tcpFd, vsockFd: vsockFd, connection: conn)
        print("[PortForwardListener] [25] Bridge returned")
    }

    /// Bridge TCP and vsock connections using two threads - simplest proven approach
    /// Each direction gets its own thread doing blocking read/write
    private func bridgeConnections(tcpFd: Int32, vsockFd: Int32, connection: VZVirtioSocketConnection) {
        let startTime = DispatchTime.now()

        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
            print("[PortForwardListener] BRIDGE CLOSED: elapsed=\(String(format: "%.2f", elapsed))s")
            connection.close()
        }

        // Keep sockets BLOCKING - simplest and most reliable
        var flags = fcntl(tcpFd, F_GETFL, 0)
        _ = fcntl(tcpFd, F_SETFL, flags & ~O_NONBLOCK)

        flags = fcntl(vsockFd, F_GETFL, 0)
        _ = fcntl(vsockFd, F_SETFL, flags & ~O_NONBLOCK)

        let group = DispatchGroup()

        // Thread 1: TCP -> vsock (request direction)
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.copyData(from: tcpFd, to: vsockFd, label: "tcp->vsock")
            Darwin.shutdown(vsockFd, SHUT_WR)
            group.leave()
        }

        // Thread 2: vsock -> TCP (response direction)
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            self.copyData(from: vsockFd, to: tcpFd, label: "vsock->tcp")
            Darwin.shutdown(tcpFd, SHUT_WR)
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
                print("[PortForwardListener] \(label): EOF after \(totalBytes) bytes")
                return
            }

            if bytesRead < 0 {
                let err = errno
                if err == EINTR { continue }
                if isPeerDisconnected(err) {
                    print("[PortForwardListener] \(label): peer closed (errno=\(err)) after \(totalBytes) bytes")
                    return
                }
                // CRASH with full details
                let msg = "[PortForwardListener] \(label): UNEXPECTED read error: errno=\(err) (\(String(cString: strerror(err)))) after \(totalBytes) bytes, source=\(source), dest=\(dest)"
                print(msg)
                fatalError(msg)
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
                        print("[PortForwardListener] \(label): peer closed during write (errno=\(err)) after \(totalBytes) bytes")
                        return
                    }
                    // CRASH with full details
                    let msg = "[PortForwardListener] \(label): UNEXPECTED write error: errno=\(err) (\(String(cString: strerror(err)))) offset=\(offset)/\(bytesRead), totalBytes=\(totalBytes), source=\(source), dest=\(dest)"
                    print(msg)
                    fatalError(msg)
                }
                offset += written
            }

            totalBytes += bytesRead
        }
    }
}
