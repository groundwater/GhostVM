import Foundation
import os

struct TunnelRuntimeError: Sendable {
    enum Phase: String, Sendable {
        case handshakeRead
        case handshakeProtocol
        case connectLocal
        case bridge
    }

    let phase: Phase
    let message: String
    let targetPort: UInt16?
    let timestamp: Date

    init(phase: Phase, message: String, targetPort: UInt16? = nil, timestamp: Date = Date()) {
        self.phase = phase
        self.message = message
        self.targetPort = targetPort
        self.timestamp = timestamp
    }
}

func tunnelIsDisconnectErrno(_ err: Int32) -> Bool {
    switch err {
    case ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN, ECONNABORTED, ETIMEDOUT:
        return true
    default:
        return false
    }
}

func tunnelIsOperationalBridgeError(_ error: Error) -> Bool {
    guard let ioError = error as? AsyncVSockIOError else {
        return false
    }
    switch ioError {
    case .closed, .cancelled:
        return true
    case .syscall(_, let err):
        return tunnelIsDisconnectErrno(err)
    default:
        return false
    }
}

/// TunnelServer listens on vsock port 5001 and handles CONNECT requests
/// from the host to bridge TCP connections to localhost services in the guest.
///
/// Protocol:
/// 1. Host sends: "CONNECT <port>\r\n"
/// 2. Server connects to localhost:<port>
/// 3. Server responds: "OK\r\n" or "ERROR <message>\r\n"
/// 4. Bidirectional bridging via async nonblocking I/O
final class TunnelServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "TunnelServer")
    private let port: UInt32 = 5001
    private var serverSocket: Int32 = -1
    private var isRunning = false

    /// Status callback for connection state changes
    var onStatusChange: ((Bool) -> Void)?
    var onOperationalError: ((TunnelRuntimeError) -> Void)?
    var onConnectionSuccess: (() -> Void)?

    init() {}

    deinit {
        stop()
    }

    /// Starts the tunnel server
    func start() async throws {
        Self.logger.info("Creating tunnel socket on port \(self.port)")

        // Create vsock socket
        serverSocket = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            Self.logger.fault("Socket creation failed errno=\(errno)")
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
        Self.logger.info("Listening on vsock port \(self.port)")

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
                    let err = errno
                    if err == EINTR { continue }
                    if self?.isRunning != true || err == EBADF || err == EINVAL {
                        Self.logger.info("Accept loop exiting serverSocket=\(self?.serverSocket ?? -1) errno=\(err)")
                        break
                    }
                    self?.reportOperationalError(
                        TunnelRuntimeError(
                            phase: .bridge,
                            message: "accept() failed: errno=\(err) \(String(cString: strerror(err)))"
                        ),
                        connectionID: "accept-loop",
                        error: AsyncVSockIOError.syscall(op: "accept", errno: err)
                    )
                    usleep(100_000)
                    continue
                }

                Task { [weak self] in
                    await self?.handleConnection(clientSocket)
                }
            }
        }
    }

    /// Handles a single tunnel connection
    private func handleConnection(_ vsockFd: Int32) async {
        let connectionID = UUID().uuidString
        Self.logger.debug("New incoming host connection id=\(connectionID, privacy: .public) fd=\(vsockFd)")

        let vsockIO = BlockingVSockChannel(fd: vsockFd, ownsFD: true)
        defer {
            vsockIO.close()
            Self.logger.debug("Connection closed id=\(connectionID, privacy: .public) fd=\(vsockFd)")
        }

        let commandData: Data
        do {
            commandData = try await readHandshakeCommand(vsockIO)
        } catch let error as HandshakeReadError {
            switch error {
            case .timeout:
                reportOperationalError(
                    TunnelRuntimeError(
                        phase: .handshakeRead,
                        message: "Timeout waiting for CONNECT command from host"
                    ),
                    connectionID: connectionID,
                    error: error
                )
                return
            case .eof:
                reportOperationalError(
                    TunnelRuntimeError(
                        phase: .handshakeRead,
                        message: "Failed to read CONNECT command: EOF"
                    ),
                    connectionID: connectionID,
                    error: error
                )
                return
            case .transport(let ioError):
                reportOperationalError(
                    TunnelRuntimeError(
                        phase: .handshakeRead,
                        message: describe(error: ioError)
                    ),
                    connectionID: connectionID,
                    error: ioError
                )
                return
            }
        } catch {
            Self.logger.fault("Unexpected handshake read error id=\(connectionID, privacy: .public): \(String(describing: error), privacy: .public)")
            fatalError("[TunnelServer] Failed to read CONNECT command: unexpected error \(error)")
        }

        // Parse "CONNECT <port>\r\n"
        guard let command = String(data: commandData, encoding: .utf8) else {
            reportOperationalError(
                TunnelRuntimeError(
                    phase: .handshakeProtocol,
                    message: "Invalid command encoding"
                ),
                connectionID: connectionID
            )
            await sendError(vsockIO, message: "Invalid command encoding")
            return
        }

        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.logger.debug("Received command id=\(connectionID, privacy: .public): \(trimmed, privacy: .public)")

        guard trimmed.hasPrefix("CONNECT ") else {
            reportOperationalError(
                TunnelRuntimeError(
                    phase: .handshakeProtocol,
                    message: "Expected CONNECT command, got '\(trimmed)'"
                ),
                connectionID: connectionID
            )
            await sendError(vsockIO, message: "Expected CONNECT command")
            return
        }

        let portString = String(trimmed.dropFirst("CONNECT ".count))
        guard let targetPort = UInt16(portString) else {
            reportOperationalError(
                TunnelRuntimeError(
                    phase: .handshakeProtocol,
                    message: "Invalid port number '\(portString)'"
                ),
                connectionID: connectionID
            )
            await sendError(vsockIO, message: "Invalid port number")
            return
        }

        Self.logger.debug("Connecting to localhost id=\(connectionID, privacy: .public) targetPort=\(targetPort)")

        // Connect to localhost on the target port
        guard let tcpFd = connectToLocalhost(port: targetPort) else {
            reportOperationalError(
                TunnelRuntimeError(
                    phase: .connectLocal,
                    message: "Failed to connect to localhost:\(targetPort)",
                    targetPort: targetPort
                ),
                connectionID: connectionID
            )
            await sendError(vsockIO, message: "Connection refused to port \(targetPort)")
            return
        }
        let tcpIO = AsyncVSockIO(fd: tcpFd, ownsFD: true)

        Self.logger.info("Connected to localhost id=\(connectionID, privacy: .public) targetPort=\(targetPort)")

        // Send OK response
        do {
            try await vsockIO.writeAll(Data("OK\r\n".utf8))
        } catch {
            reportOperationalError(
                TunnelRuntimeError(
                    phase: .handshakeProtocol,
                    message: "Failed to write OK response: \(describe(error: error))",
                    targetPort: targetPort
                ),
                connectionID: connectionID,
                error: error
            )
            return
        }

        onConnectionSuccess?()
        Self.logger.info("Starting bridge id=\(connectionID, privacy: .public) targetPort=\(targetPort)")

        do {
            try await pipeBidirectional(vsockIO, tcpIO)
        } catch {
            if tunnelIsOperationalBridgeError(error) {
                reportOperationalError(
                    TunnelRuntimeError(
                        phase: .bridge,
                        message: describe(error: error),
                        targetPort: targetPort
                    ),
                    connectionID: connectionID,
                    error: error
                )
                return
            }
            let described = describe(error: error)
            Self.logger.fault("Unexpected bridge failure id=\(connectionID, privacy: .public) targetPort=\(targetPort): \(described, privacy: .public)")
            fatalError("[TunnelServer] Bridge failed unexpectedly: \(described)")
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

    /// Send an error response
    private func sendError(_ io: some SocketChannel, message: String) async {
        let response = "ERROR \(message)\r\n"
        do {
            try await io.writeAll(Data(response.utf8))
        } catch {
            let described = describe(error: error)
            Self.logger.warning("Failed to send error response to host: \(described, privacy: .public)")
        }
    }

    private enum HandshakeReadError: Error {
        case timeout
        case eof
        case transport(AsyncVSockIOError)
    }

    private func readHandshakeCommand(_ io: some SocketChannel) async throws -> Data {
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

    private func reportOperationalError(
        _ runtimeError: TunnelRuntimeError,
        connectionID: String,
        error: Error? = nil
    ) {
        let errnoValue: Int32?
        if let ioError = error as? AsyncVSockIOError, case .syscall(_, let err) = ioError {
            errnoValue = err
        } else {
            errnoValue = nil
        }

        let targetPortText = runtimeError.targetPort.map(String.init) ?? "none"
        let useWarningLevel = runtimeError.phase == .bridge && (error.map(tunnelIsOperationalBridgeError) ?? false)

        if let err = errnoValue {
            if useWarningLevel {
                Self.logger.warning("Operational tunnel error id=\(connectionID, privacy: .public) phase=\(runtimeError.phase.rawValue, privacy: .public) targetPort=\(targetPortText, privacy: .public) errno=\(err): \(runtimeError.message, privacy: .public)")
            } else {
                Self.logger.error("Operational tunnel error id=\(connectionID, privacy: .public) phase=\(runtimeError.phase.rawValue, privacy: .public) targetPort=\(targetPortText, privacy: .public) errno=\(err): \(runtimeError.message, privacy: .public)")
            }
        } else {
            if useWarningLevel {
                Self.logger.warning("Operational tunnel error id=\(connectionID, privacy: .public) phase=\(runtimeError.phase.rawValue, privacy: .public) targetPort=\(targetPortText, privacy: .public): \(runtimeError.message, privacy: .public)")
            } else {
                Self.logger.error("Operational tunnel error id=\(connectionID, privacy: .public) phase=\(runtimeError.phase.rawValue, privacy: .public) targetPort=\(targetPortText, privacy: .public): \(runtimeError.message, privacy: .public)")
            }
        }
        onOperationalError?(runtimeError)
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
