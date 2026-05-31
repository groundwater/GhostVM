import Foundation
import GhostHTTP
import GhostVMKit
import Virtualization
import os

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
/// 1. Vsock connection to guest on port 5000
/// 2. HTTP upgrade request to `/api/v1/tunnel-connect`
/// 3. Raw byte bridge after `101 Switching Protocols`
final class PortForwardListener: @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.ghostvm.ghostvm", category: "PortForwardListener")
    private let hostPort: UInt16
    private let guestPort: UInt16
    private let vmQueue: DispatchQueue
    private let virtualMachine: VZVirtualMachine
    private let onOperationalError: @Sendable (PortForwardRuntimeError) -> Void

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var isRunning = false
    private var activeConnections = 0
    private let connectionLock = NSLock()

    /// The unified guest HTTP server port.
    private let tunnelServerPort: UInt32 = 5000

    init(
        hostPort: UInt16,
        guestPort: UInt16,
        vm: VZVirtualMachine,
        queue: DispatchQueue,
        onOperationalError: @escaping @Sendable (PortForwardRuntimeError) -> Void
    ) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.virtualMachine = vm
        self.vmQueue = queue
        self.onOperationalError = onOperationalError
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
        let flags = fcntl(serverSocket, F_GETFL, 0)
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

        Self.logger.info("Listening on localhost hostPort=\(self.hostPort) guestPort=\(self.guestPort)")
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

        Self.logger.info("Stopped forwarding hostPort=\(self.hostPort)")
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
                // stop() closes the server socket and can race accept.
                if !isRunning || err == EBADF || err == EINVAL {
                    Self.logger.info("Accept loop exiting hostPort=\(self.hostPort) serverSocket=\(self.serverSocket) errno=\(err)")
                    return
                }

                reportOperationalError(
                    phase: .bridge,
                    message: "accept() failed: errno=\(err) (\(String(cString: strerror(err))))",
                    error: AsyncVSockIOError.syscall(op: "accept", errno: err),
                    connectionID: "accept-loop"
                )
                usleep(100_000)
                continue
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
        let connectionID = UUID().uuidString
        connectionLock.lock()
        activeConnections += 1
        let connCount = activeConnections
        connectionLock.unlock()

        Self.logger.debug("New connection id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort) active=\(connCount) tcpFd=\(tcpFd)")

        defer {
            Self.logger.debug("Closing tcp fd for id=\(connectionID, privacy: .public): tcpFd=\(tcpFd)")
            close(tcpFd)
            connectionLock.lock()
            activeConnections -= 1
            let remaining = activeConnections
            connectionLock.unlock()
            Self.logger.debug("Connection closed id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort) active=\(remaining)")
        }

        let connector = AsyncVsockConnector(
            vm: virtualMachine,
            vmQueue: vmQueue,
            port: tunnelServerPort,
            timeoutSeconds: 5
        )

        Self.logger.debug("Connecting to guest tunnel server id=\(connectionID, privacy: .public) tunnelPort=\(self.tunnelServerPort)")
        let conn: VZVirtioSocketConnection
        do {
            conn = try await connector.connect()
        } catch {
            reportOperationalError(
                phase: .connectToGuest,
                message: describe(error: error),
                error: error,
                connectionID: connectionID
            )
            return
        }

        let vsockFd = conn.fileDescriptor
        Self.logger.info("Connected to guest vsock id=\(connectionID, privacy: .public) vsockFd=\(vsockFd)")

        let tcpIO = AsyncVSockIO(fd: tcpFd, ownsFD: false)
        let vsockIO = BlockingVSockChannel(fd: vsockFd, ownsFD: false)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let flags = fcntl(vsockFd, F_GETFL, 0)
                        if flags >= 0 && (flags & O_NONBLOCK) != 0 {
                            _ = fcntl(vsockFd, F_SETFL, flags & ~O_NONBLOCK)
                        }
                        let upgraded = try HTTPClient.performUpgradeRequest(
                            fd: vsockFd,
                            path: "/api/v1/tunnel-connect",
                            headers: [
                                "Host": "localhost",
                                "Upgrade": "tunnel",
                                "Connection": "Upgrade",
                                "Tunnel-Port": "\(self.guestPort)",
                            ]
                        )
                        guard upgraded.responseHead.status == .switchingProtocols else {
                            throw PortForwardError.protocolError("Guest refused tunnel upgrade with status \(upgraded.responseHead.status.rawValue)")
                        }
                        try self.writePrelude(upgraded.prelude, to: tcpFd)
                        continuation.resume(returning: ())
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            Self.logger.debug("Tunnel upgrade completed id=\(connectionID, privacy: .public) guestPort=\(self.guestPort)")
        } catch {
            let phase: PortForwardRuntimeError.Phase
            if error is PortForwardError {
                phase = .handshakeProtocol
            } else {
                phase = .handshakeRead
            }
            reportOperationalError(
                phase: phase,
                message: describe(error: error),
                error: error,
                connectionID: connectionID
            )
            return
        }

        Self.logger.info("Starting bridge id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort)")
        await bridgeConnections(tcpIO: tcpIO, vsockIO: vsockIO, connection: conn, connectionID: connectionID)
        Self.logger.debug("Bridge returned id=\(connectionID, privacy: .public)")
    }

    /// Bridge TCP and vsock connections using async nonblocking I/O
    private func bridgeConnections(
        tcpIO: some SocketChannel,
        vsockIO: some SocketChannel,
        connection: VZVirtioSocketConnection,
        connectionID: String
    ) async {
        let startTime = DispatchTime.now()

        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
            Self.logger.info("Bridge closed id=\(connectionID, privacy: .public) elapsed=\(String(format: "%.2f", elapsed), privacy: .public)s")
            connection.close()
        }

        do {
            try await pipeBidirectional(tcpIO, vsockIO)
        } catch {
            if isOperationalBridgeError(error) {
                reportOperationalError(
                    phase: .bridge,
                    message: describe(error: error),
                    error: error,
                    connectionID: connectionID
                )
                return
            }

            let described = describe(error: error)
            Self.logger.error("Unexpected bridge error id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort): \(described, privacy: .public)")
            reportOperationalError(
                phase: .bridge,
                message: described,
                error: error,
                connectionID: connectionID
            )
        }
    }

    private func isOperationalBridgeError(_ error: Error) -> Bool {
        guard let ioError = error as? AsyncVSockIOError else {
            return false
        }
        switch ioError {
        case .closed, .cancelled:
            return true
        case .syscall(_, let err):
            return isDisconnectErrno(err)
        default:
            return false
        }
    }

    private func isDisconnectErrno(_ err: Int32) -> Bool {
        switch err {
        case ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN, ECONNABORTED, ETIMEDOUT:
            return true
        default:
            return false
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
        if let portError = error as? PortForwardError {
            return portError.localizedDescription
        }
        return String(describing: error)
    }

    private func reportOperationalError(
        phase: PortForwardRuntimeError.Phase,
        message: String,
        error: Error? = nil,
        connectionID: String
    ) {
        let runtimeError = PortForwardRuntimeError(
            hostPort: hostPort,
            guestPort: guestPort,
            phase: phase,
            message: message
        )
        let errnoValue: Int32?
        if let ioError = error as? AsyncVSockIOError, case .syscall(_, let err) = ioError {
            errnoValue = err
        } else {
            errnoValue = nil
        }
        let useWarningLevel = phase == .bridge && (error.map(isOperationalBridgeError) ?? false)
        if let err = errnoValue {
            if useWarningLevel {
                Self.logger.warning("Operational error id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort) phase=\(phase.rawValue, privacy: .public) errno=\(err): \(message, privacy: .public)")
            } else {
                Self.logger.error("Operational error id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort) phase=\(phase.rawValue, privacy: .public) errno=\(err): \(message, privacy: .public)")
            }
        } else {
            if useWarningLevel {
                Self.logger.warning("Operational error id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort) phase=\(phase.rawValue, privacy: .public): \(message, privacy: .public)")
            } else {
                Self.logger.error("Operational error id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort) phase=\(phase.rawValue, privacy: .public): \(message, privacy: .public)")
            }
        }
        onOperationalError(runtimeError)
    }

    private func writePrelude(_ data: Data, to fd: Int32) throws {
        guard !data.isEmpty else { return }

        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress! + offset, data.count - offset)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                throw PortForwardError.connectFailed("short write while replaying tunnel prelude")
            }
            let err = errno
            if err == EINTR {
                continue
            }
            throw PortForwardError.connectFailed("failed to replay tunnel prelude: errno \(err)")
        }
    }
}
