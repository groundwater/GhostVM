import Foundation
import NIOCore
import NIOHTTP1

/// Dispatches HTTP streams to the appropriate handler based on the request URI.
/// Used for both HTTP/1.1 and HTTP/2 connections.
///
/// - `/api/v1/shell` → ShellHandler (bidirectional streaming)
/// - Everything else → HTTP1RequestHandler (request/response via Router)
final class StreamDispatcher: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private var dispatched = false

    init(router: Router) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        // On first .head, decide which handler to install
        if !dispatched {
            let part = unwrapInboundIn(data)
            guard case .head(let head) = part else {
                // Shouldn't happen — .head always comes first
                context.fireChannelRead(data)
                return
            }

            dispatched = true

            // Shell requests are handled via WebSocket upgrade in the HTTP pipeline,
            // not here. All requests reaching the StreamDispatcher are normal HTTP.

            // Replace ourselves with the Router bridge
            let handler = RouterBridgeHandler(router: router)
            context.pipeline.removeHandler(self, promise: nil)
            context.pipeline.addHandler(handler).whenComplete { _ in
                context.fireChannelRead(data)
            }
            return
        }

        // After dispatch, this handler shouldn't be in the pipeline
        context.fireChannelRead(data)
    }
}

/// Bridges NIO's HTTP types to the existing Router for standard request/response.
/// (Extracted from NIOVsockServer's HTTP1RequestHandler for reuse.)
final class RouterBridgeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: Router
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()

    init(router: Router) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            bodyBuffer.clear()

        case .body(var body):
            bodyBuffer.writeBuffer(&body)

        case .end:
            guard let head = requestHead else { return }
            requestHead = nil

            let method = convertMethod(head.method)
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                headers[name] = value
            }

            let body: Data?
            if bodyBuffer.readableBytes > 0 {
                body = Data(bodyBuffer.readableBytesView)
            } else {
                body = nil
            }
            bodyBuffer.clear()

            let request = HTTPRequest(
                method: method,
                path: head.uri,
                headers: headers,
                body: body
            )

            let channel = context.channel
            let routerRef = self.router
            Task {
                let response = await routerRef.handle(request)
                channel.eventLoop.execute {
                    self.writeResponse(response, context: context)
                }
            }
        }
    }

    private func writeResponse(_ response: HTTPResponse, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }

        let status = HTTPResponseStatus(statusCode: response.status.rawValue)
        var headers = HTTPHeaders()
        for (key, value) in response.headers {
            headers.add(name: key, value: value)
        }
        if let body = response.body {
            headers.replaceOrAdd(name: "content-length", value: "\(body.count)")
        } else {
            headers.replaceOrAdd(name: "content-length", value: "0")
        }
        headers.replaceOrAdd(name: "connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if let body = response.body, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[RouterBridge] Error: \(error)")
        context.close(promise: nil)
    }

    private func convertMethod(_ method: NIOHTTP1.HTTPMethod) -> HTTPMethod {
        switch method {
        case .GET: return .GET
        case .POST: return .POST
        case .PUT: return .PUT
        case .DELETE: return .DELETE
        case .HEAD: return .HEAD
        case .OPTIONS: return .OPTIONS
        case .PATCH: return .PATCH
        default: return .GET
        }
    }
}
