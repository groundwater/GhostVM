import Foundation
import GhostVMKit
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

            Task { [weak self] in
                await self?.handleConnection(clientSocket)
            }
        }
    }

    /// Handle a single forwarded connection
    private func handleConnection(_ tcpFd: Int32) async {
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

        let connector = AsyncVsockConnector(
            vm: virtualMachine,
            vmQueue: vmQueue,
            port: tunnelServerPort,
            timeoutSeconds: 5
        )

        print("[PortForwardListener] [3] Connecting to guest TunnelServer...")
        let conn: VZVirtioSocketConnection
        do {
            conn = try await connector.connect()
        } catch {
            let msg = "[PortForwardListener] Failed to connect to guest TunnelServer: \(describe(error: error))"
            print(msg)
            fatalError(msg)
        }

        print("[PortForwardListener] [13] Getting fileDescriptor")
        let vsockFd = conn.fileDescriptor
        print("[PortForwardListener] [14] Connected to guest vsock, fd=\(vsockFd)")

        let tcpIO = AsyncVSockIO(fd: tcpFd, ownsFD: false)
        let vsockIO = AsyncVSockIO(fd: vsockFd, ownsFD: false)

        // Send CONNECT command
        print("[PortForwardListener] [16] Sending CONNECT command")
        do {
            try await vsockIO.writeAll(Data("CONNECT \(guestPort)\r\n".utf8))
            print("[PortForwardListener] [17] CONNECT write completed")
        } catch {
            let msg = "[PortForwardListener] Failed to send CONNECT command: \(describe(error: error))"
            print(msg)
            fatalError(msg)
        }

        print("[PortForwardListener] [20] Reading response")
        let responseData: Data
        do {
            responseData = try await readConnectResponse(vsockIO)
            print("[PortForwardListener] [21] Read returned \(responseData.count)")
        } catch let error as ConnectReadError {
            switch error {
            case .timeout:
                fatalError("[PortForwardListener] Timeout waiting for CONNECT response")
            case .eof:
                fatalError("[PortForwardListener] Failed to read CONNECT response: bytesRead=0 EOF")
            case .transport(let ioError):
                fatalError("[PortForwardListener] Failed to read CONNECT response: \(describe(error: ioError))")
            }
        } catch {
            fatalError("[PortForwardListener] Failed to read CONNECT response: \(describe(error: error))")
        }

        print("[PortForwardListener] [22] Decoding response")
        guard let response = String(data: responseData, encoding: .utf8) else {
            fatalError("[PortForwardListener] Invalid CONNECT response encoding")
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        print("[PortForwardListener] [23] Response: '\(trimmed)'")

        if trimmed != "OK" {
            fatalError("[PortForwardListener] Guest refused connection: '\(trimmed)'")
        }

        // Bridge the connections
        print("[PortForwardListener] [24] Starting bridge")
        await bridgeConnections(tcpIO: tcpIO, vsockIO: vsockIO, connection: conn)
        print("[PortForwardListener] [25] Bridge returned")
    }

    /// Bridge TCP and vsock connections using async nonblocking I/O
    private func bridgeConnections(tcpIO: AsyncVSockIO, vsockIO: AsyncVSockIO, connection: VZVirtioSocketConnection) async {
        let startTime = DispatchTime.now()

        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
            print("[PortForwardListener] BRIDGE CLOSED: elapsed=\(String(format: "%.2f", elapsed))s")
            connection.close()
        }

        do {
            try await pipeBidirectional(tcpIO, vsockIO)
        } catch {
            if isExpectedBridgeError(error) {
                print("[PortForwardListener] Bridge closed: \(describe(error: error))")
            } else {
                // CRASH with full details
                let msg = "[PortForwardListener] Bridge failed unexpectedly: \(describe(error: error))"
                print(msg)
                fatalError(msg)
            }
        }
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

    private enum ConnectReadError: Error {
        case timeout
        case eof
        case transport(AsyncVSockIOError)
    }

    private func readConnectResponse(_ io: AsyncVSockIO) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                do {
                    guard let data = try await io.read(maxBytes: 255), !data.isEmpty else {
                        throw ConnectReadError.eof
                    }
                    return data
                } catch let error as AsyncVSockIOError {
                    throw ConnectReadError.transport(error)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw ConnectReadError.timeout
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
                return "syscall \(op) failed: errno=\(err) (\(String(cString: strerror(err))))"
            case .cancelled:
                return "cancelled"
            }
        }
        return String(describing: error)
    }
}
