import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2

/// NIO-based vsock server that supports both HTTP/1.1 and HTTP/2.
///
/// Replaces the hand-rolled VsockServer with NIO's event loop, enabling:
/// - HTTP/2 multiplexed streams (for shell/PTY sessions)
/// - Non-blocking I/O via kqueue (verified to work with AF_VSOCK on macOS 26+)
/// - Clean channel pipeline architecture
final class NIOVsockServer: @unchecked Sendable {
    private let port: UInt32
    private let router: Router
    private var serverChannel: Channel?
    private var group: EventLoopGroup?

    /// Status callback for connection state changes
    var onStatusChange: ((Bool) -> Void)?

    init(port: UInt32 = 5000, router: Router) {
        self.port = port
        self.router = router
    }

    deinit {
        stop()
    }

    /// Starts the NIO-based vsock server.
    func start() async throws {
        let AF_VSOCK: Int32 = 40

        // Create and bind the vsock listen socket manually,
        // then hand it to NIO via withBoundSocket.
        let listenFD = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
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

        print("[NIOVsockServer] Vsock socket bound and listening on port \(port) (fd=\(listenFD))")

        // Create NIO event loop group
        let elg = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = elg

        let routerRef = self.router

        // Hand the listen fd to NIO's ServerBootstrap
        let bootstrap = ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Each accepted connection gets a protocol-detecting pipeline
                channel.pipeline.addHandler(ProtocolDetector(router: routerRef))
            }

        do {
            let channel = try await bootstrap.withBoundSocket(listenFD).get()
            self.serverChannel = channel
            print("[NIOVsockServer] NIO server running on vsock port \(self.port)")
            onStatusChange?(true)
        } catch {
            close(listenFD)
            try? elg.syncShutdownGracefully()
            self.group = nil
            throw error
        }
    }

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
}

// MARK: - Protocol Detection

/// Peeks at the first bytes of a connection to determine if it's HTTP/2 or HTTP/1.1.
/// HTTP/2 connections start with the connection preface: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
/// Everything else is treated as HTTP/1.1.
private final class ProtocolDetector: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let router: Router
    private var buffer = ByteBuffer()
    // HTTP/2 connection preface magic bytes
    private static let h2Preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    init(router: Router) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)

        // Need at least 24 bytes to detect HTTP/2 preface
        if buffer.readableBytes < Self.h2Preface.count {
            // Wait for more data
            return
        }

        let isHTTP2 = buffer.withUnsafeReadableBytes { ptr in
            ptr.prefix(Self.h2Preface.count).elementsEqual(Self.h2Preface)
        }

        // Remove ourselves and install the appropriate pipeline
        let buffered = buffer
        buffer = ByteBuffer()

        if isHTTP2 {
            print("[NIOVsockServer] Detected HTTP/2 connection")
            installHTTP2(context: context, buffered: buffered)
        } else {
            print("[NIOVsockServer] Detected HTTP/1.1 connection")
            installHTTP1(context: context, buffered: buffered)
        }
    }

    private func installHTTP1(context: ChannelHandlerContext, buffered: ByteBuffer) {
        let router = self.router
        context.pipeline.removeHandler(self, promise: nil)

        context.pipeline.addHandlers([
            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
            HTTPResponseEncoder(),
            StreamDispatcher(router: router),
        ]).whenComplete { _ in
            context.fireChannelRead(NIOAny(buffered))
        }
    }

    private func installHTTP2(context: ChannelHandlerContext, buffered: ByteBuffer) {
        let router = self.router
        context.pipeline.removeHandler(self, promise: nil)

        context.channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
            streamChannel.pipeline.addHandlers([
                HTTP2FramePayloadToHTTP1ServerCodec(),
                StreamDispatcher(router: router),
            ])
        }.whenComplete { _ in
            context.fireChannelRead(NIOAny(buffered))
        }
    }
}
