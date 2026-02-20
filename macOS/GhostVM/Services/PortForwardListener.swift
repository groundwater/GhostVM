import Foundation
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
/// 1. Vsock connection to guest on port 5001
/// 2. Send "CONNECT <guestPort>\r\n"
/// 3. Wait for "OK\r\n"
/// 4. Bridge TCP <-> vsock bidirectionally
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

    /// The vsock port where TunnelServer listens in the guest
    private let tunnelServerPort: UInt32 = 5001

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
                // CRASH with full details
                let msg = "[PortForwardListener] accept() FAILED: errno=\(err) (\(String(cString: strerror(err)))) serverSocket=\(serverSocket)"
                Self.logger.fault("\(msg, privacy: .public)")
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
        let vsockIO = AsyncVSockIO(fd: vsockFd, ownsFD: false)

        // Send CONNECT command
        Self.logger.debug("Sending CONNECT command id=\(connectionID, privacy: .public) guestPort=\(self.guestPort)")
        do {
            try await vsockIO.writeAll(Data("CONNECT \(guestPort)\r\n".utf8))
            Self.logger.debug("CONNECT command write completed id=\(connectionID, privacy: .public)")
        } catch {
            reportOperationalError(
                phase: .handshakeWrite,
                message: describe(error: error),
                error: error,
                connectionID: connectionID
            )
            return
        }

        let responseData: Data
        do {
            responseData = try await readConnectResponse(vsockIO)
            Self.logger.debug("CONNECT response bytes read id=\(connectionID, privacy: .public) bytes=\(responseData.count)")
        } catch let error as ConnectReadError {
            switch error {
            case .timeout:
                reportOperationalError(
                    phase: .handshakeRead,
                    message: "Timeout waiting for CONNECT response",
                    error: error,
                    connectionID: connectionID
                )
                return
            case .eof:
                reportOperationalError(
                    phase: .handshakeRead,
                    message: "Failed to read CONNECT response: bytesRead=0 EOF",
                    error: error,
                    connectionID: connectionID
                )
                return
            case .transport(let ioError):
                reportOperationalError(
                    phase: .handshakeRead,
                    message: describe(error: ioError),
                    error: ioError,
                    connectionID: connectionID
                )
                return
            }
        } catch {
            reportOperationalError(
                phase: .handshakeRead,
                message: describe(error: error),
                error: error,
                connectionID: connectionID
            )
            return
        }

        guard let response = String(data: responseData, encoding: .utf8) else {
            reportOperationalError(
                phase: .handshakeProtocol,
                message: "Invalid CONNECT response encoding",
                connectionID: connectionID
            )
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.logger.debug("CONNECT response id=\(connectionID, privacy: .public): \(trimmed, privacy: .public)")

        if trimmed != "OK" {
            reportOperationalError(
                phase: .handshakeProtocol,
                message: "Guest refused connection: '\(trimmed)'",
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
        tcpIO: AsyncVSockIO,
        vsockIO: AsyncVSockIO,
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
            Self.logger.fault("Unexpected bridge error id=\(connectionID, privacy: .public) hostPort=\(self.hostPort) guestPort=\(self.guestPort): \(described, privacy: .public)")
            fatalError("[PortForwardListener] Bridge failed unexpectedly: \(described)")
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
}
