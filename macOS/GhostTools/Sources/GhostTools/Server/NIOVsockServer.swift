import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOHTTP2
import NIOWebSocket
import os

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
            .childChannelOption(.allowRemoteHalfClosure, value: true)
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
            try? await elg.shutdownGracefully()
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

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "ProtocolDetector")

    private let router: Router
    private var buffer = ByteBuffer()
    // HTTP/2 connection preface magic bytes
    private static let h2Preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)

    init(router: Router) {
        self.router = router
    }

    func channelActive(context: ChannelHandlerContext) {
        Self.logger.debug("channelActive fd=\(context.channel.localAddress.debugDescription, privacy: .public)")
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        Self.logger.debug("channelInactive")
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        let incomingBytes = incoming.readableBytes
        buffer.writeBuffer(&incoming)

        Self.logger.debug("channelRead: +\(incomingBytes) bytes, total buffered=\(self.buffer.readableBytes)")

        // Need at least 24 bytes to detect HTTP/2 preface
        if buffer.readableBytes < Self.h2Preface.count {
            Self.logger.debug("waiting for more data (need \(Self.h2Preface.count) bytes)")
            return
        }

        let isHTTP2 = buffer.withUnsafeReadableBytes { ptr in
            ptr.prefix(Self.h2Preface.count).elementsEqual(Self.h2Preface)
        }

        // Log the first bytes for debugging
        let preview = buffer.withUnsafeReadableBytes { ptr -> String in
            let len = min(ptr.count, 80)
            return String(bytes: ptr.prefix(len), encoding: .utf8)?
                .replacingOccurrences(of: "\r\n", with: "\\r\\n")
                .replacingOccurrences(of: "\n", with: "\\n")
                ?? "<non-utf8>"
        }
        Self.logger.info("protocol detect: isHTTP2=\(isHTTP2) buffered=\(self.buffer.readableBytes) preview=\(preview, privacy: .public)")

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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Self.logger.error("errorCaught: \(error.localizedDescription, privacy: .public)")
        context.fireErrorCaught(error)
    }

    private func installHTTP1(context: ChannelHandlerContext, buffered: ByteBuffer) {
        let router = self.router
        Self.logger.debug("installHTTP1: removing ProtocolDetector, buffered=\(buffered.readableBytes) bytes")
        context.pipeline.removeHandler(self, promise: nil)

        // WebSocket upgrader for /api/v1/shell
        let wsUpgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { channel, head in
                let path = head.uri.components(separatedBy: "?").first ?? head.uri
                Self.logger.info("shouldUpgrade: path=\(path, privacy: .public) uri=\(head.uri, privacy: .public)")
                if path == "/api/v1/shell" {
                    Self.logger.info("shouldUpgrade: ACCEPTING websocket upgrade")
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                }
                Self.logger.info("shouldUpgrade: REJECTING (path mismatch)")
                return channel.eventLoop.makeSucceededFuture(nil)
            },
            upgradePipelineHandler: { channel, head in
                Self.logger.info("upgradePipelineHandler: installing ShellWebSocketHandler")
                let query = head.uri.components(separatedBy: "?").dropFirst().joined()
                let params = ProtocolDetector.parseQuery(query)
                let cols = UInt16(params["cols"] ?? "80") ?? 80
                let rows = UInt16(params["rows"] ?? "24") ?? 24

                return channel.pipeline.addHandler(
                    ShellWebSocketHandler(cols: cols, rows: rows)
                )
            }
        )

        // Use NIO's built-in pipeline setup with WebSocket upgrade support
        Self.logger.debug("installHTTP1: configuring HTTP server pipeline")
        context.channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (
                upgraders: [wsUpgrader],
                completionHandler: { context in
                    // Remove StreamDispatcher — it handles HTTP routing, not WebSocket
                    context.pipeline.removeHandler(name: "StreamDispatcher", promise: nil)
                    Self.logger.info("WebSocket upgrade complete, StreamDispatcher removed")
                }
            )
        ).flatMap {
            Self.logger.debug("installHTTP1: adding StreamDispatcher")
            // Add the router handler for non-upgraded requests
            return context.channel.pipeline.addHandler(StreamDispatcher(router: router), name: "StreamDispatcher")
        }.whenComplete { result in
            switch result {
            case .success:
                Self.logger.info("installHTTP1: pipeline ready, replaying \(buffered.readableBytes) buffered bytes")
                context.channel.pipeline.fireChannelRead(NIOAny(buffered))
                Self.logger.debug("installHTTP1: fireChannelRead returned")
            case .failure(let error):
                Self.logger.fault("installHTTP1: pipeline install FAILED: \(error.localizedDescription, privacy: .public)")
                print("[NIOVsockServer] FATAL: HTTP/1 pipeline install failed: \(error)\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                context.close(promise: nil)
            }
        }
    }

    /// Parse URL query string into key-value pairs
    static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
                result[key] = value
            }
        }
        return result
    }

    private func installHTTP2(context: ChannelHandlerContext, buffered: ByteBuffer) {
        let router = self.router
        context.pipeline.removeHandler(self, promise: nil)

        context.channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
            streamChannel.pipeline.addHandlers([
                HTTP2FramePayloadToHTTP1ServerCodec(),
                StreamDispatcher(router: router),
            ])
        }.whenComplete { result in
            switch result {
            case .success:
                context.fireChannelRead(NIOAny(buffered))
            case .failure(let error):
                print("[NIOVsockServer] FATAL: HTTP/2 pipeline install failed: \(error)\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                context.close(promise: nil)
            }
        }
    }
}
