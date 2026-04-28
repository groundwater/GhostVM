import Foundation
import NIOCore
import NIOPosix
import os

/// Event types pushed from guest to host over NDJSON.
enum PushEvent {
    case files([String])
    case urls([String])
    case log(String)
    case ports([PortInfo])
    case app(name: String, bundleId: String, iconBase64: String?)

    var jsonLine: String {
        switch self {
        case .files(let paths):
            let escaped = paths.map { escapeJSON($0) }
            return "{\"type\":\"files\",\"files\":[\(escaped.joined(separator: ","))]}"
        case .urls(let urls):
            let escaped = urls.map { escapeJSON($0) }
            return "{\"type\":\"urls\",\"urls\":[\(escaped.joined(separator: ","))]}"
        case .log(let message):
            return "{\"type\":\"log\",\"message\":\(escapeJSON(message))}"
        case .ports(let portInfos):
            let entries = portInfos.map { "{\"port\":\($0.port),\"process\":\(escapeJSON($0.process))}" }
            return "{\"type\":\"ports\",\"ports\":[\(entries.joined(separator: ","))]}"
        case .app(let name, let bundleId, let iconBase64):
            var json = "{\"type\":\"app\",\"name\":\(escapeJSON(name)),\"bundleId\":\(escapeJSON(bundleId))"
            if let icon = iconBase64 {
                json += ",\"icon\":\(escapeJSON(icon))"
            }
            json += "}"
            return json
        }
    }

    private func escapeJSON(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// EventPushServer listens on vsock port 5003 for persistent connections from the host.
/// Guest services push NDJSON events when data is available (files queued, URLs opened, logs).
///
/// Protocol:
/// 1. Host connects to port 5003
/// 2. Guest pushes NDJSON lines: {"type":"files","files":[...]}\n
/// 3. Host reads lines and dispatches events
/// 4. Connection drops if either side disconnects
final class EventPushServer: @unchecked Sendable {
    nonisolated(unsafe) static let shared = EventPushServer()

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "EventPushServer")

    private let port: UInt32 = 5003
    private var serverChannel: Channel?
    private var group: EventLoopGroup?

    /// The currently connected client channel (only one at a time)
    private var clientChannel: Channel?
    private let clientLock = NSLock()

    /// Called on main thread when a new host client connects.
    var onClientConnected: (@Sendable () -> Void)?

    private init() {}

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

        let server = self
        let bootstrap = ServerBootstrap(group: elg)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(EventPushHandler(server: server))
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

    /// Push an event to the connected host. No-op if no client connected.
    func pushEvent(_ event: PushEvent) {
        clientLock.lock()
        let channel = clientChannel
        clientLock.unlock()

        guard let channel = channel, channel.isActive else { return }

        let line = event.jsonLine + "\n"
        var buffer = channel.allocator.buffer(capacity: line.utf8.count)
        buffer.writeString(line)
        channel.writeAndFlush(NIOAny(buffer), promise: nil)
    }

    fileprivate func setClient(_ channel: Channel?) {
        clientLock.lock()
        let oldChannel = clientChannel
        clientChannel = channel
        clientLock.unlock()

        // Close previous client if replaced
        if let old = oldChannel, old !== channel {
            old.close(promise: nil)
        }

        if channel != nil {
            Self.logger.info("Client connected")
            if let callback = onClientConnected {
                DispatchQueue.main.async { callback() }
            }
        } else {
            Self.logger.info("Client disconnected")
        }
    }

    func stop() {
        setClient(nil)
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

private final class EventPushHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let server: EventPushServer

    init(server: EventPushServer) {
        self.server = server
    }

    func channelActive(context: ChannelHandlerContext) {
        server.setClient(context.channel)
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.setClient(nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
