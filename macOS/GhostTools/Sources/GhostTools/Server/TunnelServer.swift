import Foundation
import NIOCore
import NIOPosix
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

/// TunnelServer listens on vsock port 5001 and handles CONNECT requests
/// from the host to bridge TCP connections to localhost services in the guest.
///
/// Protocol:
/// 1. Host sends: "CONNECT <port>\r\n"
/// 2. Server connects to localhost:<port>
/// 3. Server responds: "OK\r\n" or "ERROR <message>\r\n"
/// 4. Bidirectional bridging via NIO channel forwarding
final class TunnelServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "TunnelServer")
    private let port: UInt32 = 5001
    private var serverChannel: Channel?
    private var group: EventLoopGroup?

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

        let listenFD = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            Self.logger.fault("Socket creation failed errno=\(errno)")
            throw VsockServerError.socketCreationFailed(errno)
        }

        var optval: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_vm(port: port)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        guard bindResult == 0 else {
            close(listenFD)
            throw VsockServerError.bindFailed(errno)
        }

        guard listen(listenFD, 128) == 0 else {
            close(listenFD)
            throw VsockServerError.listenFailed(errno)
        }

        Self.logger.info("Listening on vsock port \(self.port)")

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = elg

        let serverRef = self
        let bootstrap = ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(TunnelHandshakeHandler(server: serverRef, group: elg))
            }

        do {
            let channel = try await bootstrap.withBoundSocket(listenFD).get()
            self.serverChannel = channel
            onStatusChange?(true)
        } catch {
            close(listenFD)
            try? await elg.shutdownGracefully()
            self.group = nil
            throw error
        }
    }

    /// Stops the server
    func stop() {
        if let channel = serverChannel {
            try? channel.close().wait()
            serverChannel = nil
        }
        if let group = self.group {
            try? group.syncShutdownGracefully()
            self.group = nil
        }
        onStatusChange?(false)
    }

    fileprivate func reportOperationalError(_ error: TunnelRuntimeError, connectionID: String) {
        let targetPortText = error.targetPort.map(String.init) ?? "none"
        let useWarning = error.phase == .bridge
        if useWarning {
            Self.logger.warning("Operational tunnel error id=\(connectionID, privacy: .public) phase=\(error.phase.rawValue, privacy: .public) targetPort=\(targetPortText, privacy: .public): \(error.message, privacy: .public)")
        } else {
            Self.logger.error("Operational tunnel error id=\(connectionID, privacy: .public) phase=\(error.phase.rawValue, privacy: .public) targetPort=\(targetPortText, privacy: .public): \(error.message, privacy: .public)")
        }
        onOperationalError?(error)
    }

    fileprivate func reportConnectionSuccess() {
        onConnectionSuccess?()
    }
}

// MARK: - Handshake Handler

/// Handles the initial CONNECT handshake on a vsock channel.
/// Once the handshake succeeds, removes itself and installs a GlueHandler
/// that bridges the vsock channel to a TCP channel connected to localhost.
private final class TunnelHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "TunnelHandshake")

    private let server: TunnelServer
    private let group: EventLoopGroup
    private let connectionID = UUID().uuidString
    private var buffer = ByteBuffer()

    init(server: TunnelServer, group: EventLoopGroup) {
        self.server = server
        self.group = group
    }

    func channelActive(context: ChannelHandlerContext) {
        Self.logger.debug("New connection id=\(self.connectionID, privacy: .public)")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        // Look for \r\n to complete the handshake line
        guard let bytes = buffer.readableBytesView.firstRange(of: [0x0D, 0x0A]) else {
            // Need more data. Protect against absurdly long lines.
            if buffer.readableBytes > 255 {
                sendErrorAndClose(context: context, message: "Command too long")
                server.reportOperationalError(
                    TunnelRuntimeError(phase: .handshakeRead, message: "Command exceeded 255 bytes"),
                    connectionID: connectionID
                )
            }
            return
        }

        // Extract the command line (without \r\n)
        let lineEnd = bytes.lowerBound
        let lineStartIndex = buffer.readerIndex
        let lineLength = lineEnd - lineStartIndex
        guard let command = buffer.getString(at: lineStartIndex, length: lineLength) else {
            sendErrorAndClose(context: context, message: "Invalid command encoding")
            server.reportOperationalError(
                TunnelRuntimeError(phase: .handshakeProtocol, message: "Invalid command encoding"),
                connectionID: connectionID
            )
            return
        }

        // Consume the command + \r\n
        buffer.moveReaderIndex(forwardBy: lineLength + 2)

        let trimmed = command.trimmingCharacters(in: .whitespaces)
        Self.logger.debug("Received command id=\(self.connectionID, privacy: .public): \(trimmed, privacy: .public)")

        guard trimmed.hasPrefix("CONNECT ") else {
            sendErrorAndClose(context: context, message: "Expected CONNECT command")
            server.reportOperationalError(
                TunnelRuntimeError(phase: .handshakeProtocol, message: "Expected CONNECT command, got '\(trimmed)'"),
                connectionID: connectionID
            )
            return
        }

        let portString = String(trimmed.dropFirst("CONNECT ".count))
        guard let targetPort = UInt16(portString) else {
            sendErrorAndClose(context: context, message: "Invalid port number")
            server.reportOperationalError(
                TunnelRuntimeError(phase: .handshakeProtocol, message: "Invalid port number '\(portString)'"),
                connectionID: connectionID
            )
            return
        }

        Self.logger.debug("Connecting to localhost id=\(self.connectionID, privacy: .public) targetPort=\(targetPort)")

        // Connect to localhost using NIO ClientBootstrap
        let connID = self.connectionID
        let serverRef = self.server
        let leftoverBuffer = self.buffer  // any bytes after the handshake line

        ClientBootstrap(group: context.eventLoop)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelInitializer { tcpChannel in
                tcpChannel.pipeline.addHandler(GlueHandler())
            }
            .connect(host: "127.0.0.1", port: Int(targetPort))
            .whenComplete { result in
                switch result {
                case .success(let tcpChannel):
                    Self.logger.info("Connected to localhost id=\(connID, privacy: .public) targetPort=\(targetPort)")

                    // Send OK response
                    var okBuf = context.channel.allocator.buffer(capacity: 4)
                    okBuf.writeStaticString("OK\r\n")
                    context.writeAndFlush(self.wrapOutboundOut(okBuf)).whenComplete { writeResult in
                        switch writeResult {
                        case .success:
                            serverRef.reportConnectionSuccess()
                            Self.logger.info("Starting bridge id=\(connID, privacy: .public) targetPort=\(targetPort)")

                            // Remove handshake handler and install glue on the vsock side
                            let vsockGlue = GlueHandler()
                            context.pipeline.removeHandler(self).flatMap {
                                context.pipeline.addHandler(vsockGlue)
                            }.flatMap {
                                // Fetch the GlueHandler from the TCP channel
                                tcpChannel.pipeline.handler(type: GlueHandler.self)
                            }.whenSuccess { tcpGlue in
                                // Partner the two glue handlers.
                                // Each handler's context is already set via handlerAdded.
                                vsockGlue.partner = tcpGlue
                                tcpGlue.partner = vsockGlue

                                // Replay any leftover data after the handshake
                                if leftoverBuffer.readableBytes > 0 {
                                    tcpGlue.partnerWrite(leftoverBuffer)
                                }
                            }

                        case .failure(let error):
                            Self.logger.error("Failed to write OK response id=\(connID, privacy: .public): \(String(describing: error), privacy: .public)")
                            serverRef.reportOperationalError(
                                TunnelRuntimeError(
                                    phase: .handshakeProtocol,
                                    message: "Failed to write OK response: \(error)",
                                    targetPort: targetPort
                                ),
                                connectionID: connID
                            )
                            tcpChannel.close(promise: nil)
                            context.close(promise: nil)
                        }
                    }

                case .failure(let error):
                    Self.logger.error("Failed to connect to localhost:\(targetPort) id=\(connID, privacy: .public): \(String(describing: error), privacy: .public)")
                    serverRef.reportOperationalError(
                        TunnelRuntimeError(
                            phase: .connectLocal,
                            message: "Failed to connect to localhost:\(targetPort): \(error)",
                            targetPort: targetPort
                        ),
                        connectionID: connID
                    )
                    self.sendErrorAndClose(context: context, message: "Connection refused to port \(targetPort)")
                }
            }
    }

    func channelInactive(context: ChannelHandlerContext) {
        Self.logger.debug("Connection closed during handshake id=\(self.connectionID, privacy: .public)")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Self.logger.error("Error during handshake id=\(self.connectionID, privacy: .public): \(String(describing: error), privacy: .public)")
        server.reportOperationalError(
            TunnelRuntimeError(phase: .handshakeRead, message: "Handshake error: \(error)"),
            connectionID: connectionID
        )
        context.close(promise: nil)
    }

    private func sendErrorAndClose(context: ChannelHandlerContext, message: String) {
        let response = "ERROR \(message)\r\n"
        var buf = context.channel.allocator.buffer(capacity: response.utf8.count)
        buf.writeString(response)
        context.writeAndFlush(wrapOutboundOut(buf)).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

// MARK: - Bidirectional Bridge (Glue Handler)

/// Bridges two NIO channels by forwarding reads from one to writes on the other.
/// Each side of the tunnel (vsock and TCP) gets a GlueHandler instance, and
/// they are partnered together after the handshake completes.
private final class GlueHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "TunnelGlue")

    /// The paired handler on the other side of the bridge.
    var partner: GlueHandler?
    /// The channel handler context for this side, used by the partner to write data.
    var context: ChannelHandlerContext?

    // Store the context when handler is added to the pipeline
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        partner?.partnerWrite(buffer)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    /// Called by the partner to write data to this handler's channel.
    func partnerWrite(_ buffer: ByteBuffer) {
        guard let context = self.context else { return }
        context.write(wrapOutboundOut(buffer), promise: nil)
    }

    /// Called by the partner to flush writes on this handler's channel.
    func partnerFlush() {
        context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        // When one side closes, close the other
        if let partnerCtx = partner?.context {
            partner?.partner = nil
            partner = nil
            partnerCtx.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, event == .inputClosed {
            // Remote half-closure: close our output to the partner
            if let partnerCtx = partner?.context {
                partnerCtx.close(promise: nil)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Self.logger.warning("Bridge error: \(String(describing: error), privacy: .public)")
        // Close both sides on error
        context.close(promise: nil)
        if let partnerCtx = partner?.context {
            partner?.partner = nil
            partner = nil
            partnerCtx.close(promise: nil)
        }
    }
}
