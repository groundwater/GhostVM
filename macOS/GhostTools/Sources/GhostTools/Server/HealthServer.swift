import Foundation
import NIOCore
import NIOPosix
import os

/// HealthServer listens on vsock port 5002 for persistent health check connections.
///
/// Protocol:
/// 1. Host connects to port 5002
/// 2. Server writes: {"status":"ok","version":"<version>"}\n
/// 3. Connection stays open until host disconnects
/// 4. Connection close = host detects unhealthy
///
/// Accepts one connection at a time. New connections replace the old one.
final class HealthServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "HealthServer")

    private let port: UInt32 = 5002
    private var serverChannel: Channel?
    private var group: EventLoopGroup?

    init() {}

    deinit {
        stop()
    }

    func start() async throws {
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

        guard listen(listenFD, 1) == 0 else {
            close(listenFD)
            throw VsockServerError.listenFailed(errno)
        }

        Self.logger.info("Listening on vsock port \(self.port)")

        let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = elg

        let bootstrap = ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HealthHandler())
            }

        do {
            let channel = try await bootstrap.withBoundSocket(listenFD).get()
            self.serverChannel = channel
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
    }
}

// MARK: - Handler

private final class HealthHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        // Write version JSON on connect
        let json = "{\"status\":\"ok\",\"version\":\"\(kGhostToolsVersion)\"}\n"
        var buffer = context.channel.allocator.buffer(capacity: json.utf8.count)
        buffer.writeString(json)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        // Connection stays open — host reads the version then monitors liveness
    }

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "HealthServer")

    func channelInactive(context: ChannelHandlerContext) {
        Self.logger.info("Client disconnected")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
