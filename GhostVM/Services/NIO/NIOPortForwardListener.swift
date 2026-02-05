import Foundation
import NIOCore
import NIOPosix
import Virtualization

/// Listens on a host TCP port and forwards connections to the guest VM via vsock.
///
/// Uses SwiftNIO for TCP handling and DispatchSource for vsock I/O.
/// This hybrid approach is necessary because vsock FDs don't work well
/// with NIO's socket-based channel wrappers.
final class NIOPortForwardListener: @unchecked Sendable {
    private let hostPort: UInt16
    private let guestPort: UInt16
    private let eventLoopGroup: EventLoopGroup
    private let virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue

    private var serverChannel: Channel?
    private var isRunning = false

    /// The vsock port where TunnelServer listens in the guest
    private let tunnelServerPort: UInt32 = 5001

    init(
        hostPort: UInt16,
        guestPort: UInt16,
        eventLoopGroup: EventLoopGroup,
        vm: VZVirtualMachine,
        vmQueue: DispatchQueue
    ) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.eventLoopGroup = eventLoopGroup
        self.virtualMachine = vm
        self.vmQueue = vmQueue
    }

    /// Start listening on the host port
    func start() throws {
        guard !isRunning else { return }

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
            .childChannelInitializer { [weak self] channel in
                guard let self = self else {
                    return channel.close().flatMap { channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
                }
                return self.handleNewConnection(channel)
            }

        let channel = try bootstrap.bind(host: "127.0.0.1", port: Int(hostPort)).wait()
        serverChannel = channel
        isRunning = true

        print("[NIOPortForwardListener] Listening on localhost:\(hostPort) -> guest:\(guestPort)")
    }

    /// Stop listening and close all connections
    func stop() {
        guard isRunning else { return }
        isRunning = false

        serverChannel?.close(promise: nil)
        serverChannel = nil

        print("[NIOPortForwardListener] Stopped forwarding localhost:\(hostPort)")
    }

    /// Handle a new TCP connection
    private func handleNewConnection(_ tcpChannel: Channel) -> EventLoopFuture<Void> {
        let eventLoop = tcpChannel.eventLoop
        let promise = eventLoop.makePromise(of: Void.self)

        // Create the bridge handler (will be configured after vsock connects)
        let bridgeHandler = VsockBridgeHandler(guestPort: guestPort)

        // Add handler to TCP channel pipeline
        tcpChannel.pipeline.addHandler(bridgeHandler).whenComplete { [weak self] result in
            switch result {
            case .success:
                self?.connectVsock(for: bridgeHandler, tcpChannel: tcpChannel, promise: promise)
            case .failure(let error):
                promise.fail(error)
            }
        }

        return promise.futureResult
    }

    /// Connect to vsock and set up the bridge
    private func connectVsock(for handler: VsockBridgeHandler, tcpChannel: Channel, promise: EventLoopPromise<Void>) {
        let vm = self.virtualMachine
        let port = self.tunnelServerPort
        let guestPort = self.guestPort

        vmQueue.async {
            guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                tcpChannel.eventLoop.execute {
                    promise.fail(PortForwardError.connectFailed("No socket device"))
                }
                return
            }

            socketDevice.connect(toPort: port) { result in
                switch result {
                case .success(let connection):
                    // Perform handshake and setup bridge on the TCP channel's event loop
                    tcpChannel.eventLoop.execute {
                        self.setupBridge(
                            handler: handler,
                            tcpChannel: tcpChannel,
                            connection: connection,
                            guestPort: guestPort,
                            promise: promise
                        )
                    }

                case .failure(let error):
                    tcpChannel.eventLoop.execute {
                        promise.fail(error)
                    }
                }
            }
        }
    }

    /// Set up the vsock bridge with handshake
    private func setupBridge(
        handler: VsockBridgeHandler,
        tcpChannel: Channel,
        connection: VZVirtioSocketConnection,
        guestPort: UInt16,
        promise: EventLoopPromise<Void>
    ) {
        let vsockFd = connection.fileDescriptor

        // Set non-blocking
        let flags = fcntl(vsockFd, F_GETFL, 0)
        _ = fcntl(vsockFd, F_SETFL, flags | O_NONBLOCK)

        // Perform CONNECT handshake synchronously (fast operation)
        let connectCmd = "CONNECT \(guestPort)\r\n"
        let cmdWritten = connectCmd.withCString { ptr in
            Darwin.write(vsockFd, ptr, strlen(ptr))
        }

        if cmdWritten < 0 {
            connection.close()
            promise.fail(PortForwardError.protocolError("Failed to send CONNECT"))
            return
        }

        // Wait for response with poll (short timeout)
        var pfd = pollfd(fd: vsockFd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pfd, 1, 5000)

        if pollResult <= 0 {
            connection.close()
            promise.fail(PortForwardError.protocolError("Timeout waiting for CONNECT response"))
            return
        }

        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = Darwin.read(vsockFd, &buffer, buffer.count - 1)

        if bytesRead <= 0 {
            connection.close()
            promise.fail(PortForwardError.protocolError("Failed to read CONNECT response"))
            return
        }

        guard let response = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else {
            connection.close()
            promise.fail(PortForwardError.protocolError("Invalid response encoding"))
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != "OK" {
            connection.close()
            promise.fail(PortForwardError.connectFailed("Guest refused: \(trimmed)"))
            return
        }

        // Handshake successful - configure the bridge
        handler.setVsockConnection(connection, channel: tcpChannel)
        promise.succeed(())
    }
}

/// Handler that bridges a NIO TCP channel with a vsock connection using DispatchSource
final class VsockBridgeHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let guestPort: UInt16
    private var connection: VZVirtioSocketConnection?
    private var vsockFd: Int32 = -1
    private weak var tcpChannel: Channel?

    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var pendingWrites: [ByteBuffer] = []
    private var isWriting = false
    private var isClosed = false

    private let ioQueue = DispatchQueue(label: "vsock-bridge-io", qos: .userInitiated)

    init(guestPort: UInt16) {
        self.guestPort = guestPort
    }

    deinit {
        // Ensure cleanup happens even if channelInactive wasn't called
        cleanupSync()
    }

    /// Configure the vsock side after handshake completes
    func setVsockConnection(_ connection: VZVirtioSocketConnection, channel: Channel) {
        self.connection = connection
        self.vsockFd = connection.fileDescriptor
        self.tcpChannel = channel

        ioQueue.async { [weak self] in
            self?.setupVsockReadSource()
            // Flush any data that arrived before vsock was ready
            self?.flushPendingWrites()
        }
    }

    // MARK: - Inbound (TCP -> vsock)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !isClosed else { return }
        let buffer = unwrapInboundIn(data)
        writeToVsock(buffer)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.fireChannelReadComplete()
    }

    func channelInactive(context: ChannelHandlerContext) {
        cleanup()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fatalError("[VsockBridgeHandler] TCP error: \(error)")
    }

    // MARK: - Vsock read handling

    private func setupVsockReadSource() {
        guard vsockFd >= 0, !isClosed else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: vsockFd, queue: ioQueue)

        source.setEventHandler { [weak self] in
            self?.handleVsockRead()
        }

        source.setCancelHandler { [weak self] in
            // Cancel handler - connection closed in cleanup()
        }

        readSource = source
        source.resume()
    }

    private func handleVsockRead() {
        guard !isClosed, vsockFd >= 0, let channel = tcpChannel else { return }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = Darwin.read(vsockFd, &buffer, buffer.count)

        if bytesRead > 0 {
            // Forward to TCP channel
            let data = Array(buffer[0..<bytesRead])
            channel.eventLoop.execute { [weak self] in
                guard let self = self, !self.isClosed, let channel = self.tcpChannel else { return }
                var nioBuffer = channel.allocator.buffer(capacity: bytesRead)
                nioBuffer.writeBytes(data)
                channel.writeAndFlush(nioBuffer, promise: nil)
            }
        } else if bytesRead == 0 {
            // vsock closed - trigger cleanup
            closeFromVsock()
        } else {
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                fatalError("[VsockBridgeHandler] vsock read failed: errno=\(err) \(String(cString: strerror(err)))")
            }
        }
    }

    /// Called when vsock side closes/errors - close TCP and cleanup
    private func closeFromVsock() {
        guard !isClosed else { return }
        isClosed = true

        // Cancel sources first (we're on ioQueue)
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        pendingWrites.removeAll()

        // Close vsock connection
        connection?.close()
        connection = nil
        vsockFd = -1

        // Close TCP channel
        tcpChannel?.eventLoop.execute { [weak self] in
            self?.tcpChannel?.close(promise: nil)
        }
    }

    // MARK: - Vsock write handling

    private func writeToVsock(_ buffer: ByteBuffer) {
        ioQueue.async { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.pendingWrites.append(buffer)
            self.flushPendingWrites()
        }
    }

    private func flushPendingWrites() {
        guard !isClosed, !isWriting, !pendingWrites.isEmpty, vsockFd >= 0 else { return }

        isWriting = true

        while !pendingWrites.isEmpty && !isClosed {
            var buffer = pendingWrites.removeFirst()
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { continue }

            var offset = 0
            while offset < bytes.count && !isClosed {
                let written = bytes.withUnsafeBytes { ptr in
                    Darwin.write(vsockFd, ptr.baseAddress! + offset, bytes.count - offset)
                }

                if written > 0 {
                    offset += written
                } else if written < 0 {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        // Would block - save remaining data and set up write source
                        var remaining = ByteBuffer()
                        remaining.writeBytes(bytes[offset...])
                        pendingWrites.insert(remaining, at: 0)
                        setupWriteSource()
                        isWriting = false
                        return
                    } else if err == EPIPE || err == ECONNRESET {
                        // Peer closed - not a crash
                        print("[VsockBridgeHandler] vsock peer closed while writing \(bytes.count - offset) bytes")
                        isWriting = false
                        closeFromVsock()
                        return
                    } else {
                        fatalError("[VsockBridgeHandler] vsock write failed: errno=\(err) \(String(cString: strerror(err))) offset=\(offset)/\(bytes.count)")
                    }
                } else if written == 0 {
                    fatalError("[VsockBridgeHandler] vsock write returned 0, offset=\(offset)/\(bytes.count)")
                }
            }
        }

        isWriting = false
    }

    private func setupWriteSource() {
        guard writeSource == nil, vsockFd >= 0, !isClosed else { return }

        let source = DispatchSource.makeWriteSource(fileDescriptor: vsockFd, queue: ioQueue)

        source.setEventHandler { [weak self] in
            guard let self = self, !self.isClosed else { return }
            self.writeSource?.cancel()
            self.writeSource = nil
            self.flushPendingWrites()
        }

        writeSource = source
        source.resume()
    }

    // MARK: - Cleanup

    /// Called when TCP channel closes - cleanup vsock side
    private func cleanup() {
        ioQueue.async { [weak self] in
            self?.cleanupSync()
        }
    }

    /// Synchronous cleanup - call from ioQueue or deinit
    private func cleanupSync() {
        guard !isClosed else { return }
        isClosed = true

        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        pendingWrites.removeAll()

        connection?.close()
        connection = nil
        vsockFd = -1
    }
}
