import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import os

/// NIO-based vsock server. Plain HTTP/1.1 with WebSocket upgrade for /api/v1/shell.
/// Non-blocking I/O via kqueue (verified to work with AF_VSOCK on macOS 26+).
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

        let bootstrap = ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                let wsUpgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, head in
                        let path = head.uri.components(separatedBy: "?").first ?? head.uri
                        if path == "/api/v1/shell" {
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        }
                        return channel.eventLoop.makeSucceededFuture(nil)
                    },
                    upgradePipelineHandler: { channel, head in
                        let query = head.uri.components(separatedBy: "?").dropFirst().joined()
                        let params = parseQuery(query)
                        let cols = UInt16(params["cols"] ?? "80") ?? 80
                        let rows = UInt16(params["rows"] ?? "24") ?? 24
                        return channel.pipeline.addHandler(
                            ShellWebSocketHandler(cols: cols, rows: rows)
                        )
                    }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [wsUpgrader],
                        completionHandler: { ctx in
                            ctx.pipeline.removeHandler(name: "StreamDispatcher", promise: nil)
                        }
                    )
                ).flatMap {
                    channel.pipeline.addHandler(
                        StreamDispatcher(router: routerRef),
                        name: "StreamDispatcher"
                    )
                }
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

private func parseQuery(_ query: String) -> [String: String] {
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

