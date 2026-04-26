import Foundation
import NIOCore
import NIOHTTP1
import AppKit

/// Dispatches HTTP streams to the appropriate handler based on the request URI.
/// Used for both HTTP/1.1 and HTTP/2 connections.
///
/// - `/api/v1/shell` → ShellHandler (via WebSocket upgrade, before this handler)
/// - `POST /api/v1/files/receive` → StreamingFileReceiveHandler (streams to disk)
/// - Everything else → RouterBridgeHandler (request/response via Router)
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
                context.fireChannelRead(data)
                return
            }

            dispatched = true

            let handler: ChannelHandler
            if head.method == .POST && head.uri == "/api/v1/files/receive" {
                handler = StreamingFileReceiveHandler()
            } else {
                handler = RouterBridgeHandler(router: router)
            }

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

// MARK: - Streaming File Receive

/// Shared batch state for file receives across connections.
/// Tracks file paths per batch ID so that Finder reveal happens once
/// when the last file in a batch arrives.
private final class BatchTracker {
    static let shared = BatchTracker()
    private var batchFiles: [String: [URL]] = [:]
    private let lock = NSLock()

    func add(url: URL, batchID: String) {
        lock.lock()
        batchFiles[batchID, default: []].append(url)
        lock.unlock()
    }

    func finish(batchID: String) -> [URL] {
        lock.lock()
        let files = batchFiles.removeValue(forKey: batchID) ?? []
        lock.unlock()
        return files
    }
}

/// Handles POST /api/v1/files/receive by streaming the request body
/// directly to disk in chunks — never buffering the full file in memory.
final class StreamingFileReceiveHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var fileHandle: FileHandle?
    private var destURL: URL?
    private var baseURL: URL?
    private var bytesWritten = 0
    private var contentLength = 0
    private var requestHead: HTTPRequestHead?
    private var error: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            bytesWritten = 0
            error = nil

            let rawFilename = head.headers["X-Filename"].first
                ?? "received_file_\(Int(Date().timeIntervalSince1970))"
            contentLength = Int(head.headers["Content-Length"].first ?? "0") ?? 0
            let filename = Self.sanitizeRelativePath(rawFilename)

            print("[StreamingFileReceive] Streaming file receive: \(filename) (\(contentLength) bytes)")

            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
                .appendingPathComponent("GhostVM")
            baseURL = base
            let dest = base.appendingPathComponent(filename)
            destURL = dest

            // Create intermediate directories
            let parentDir = dest.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                print("[StreamingFileReceive] Failed to create directory: \(parentDir.path) - \(error)")
                self.error = error
                return
            }

            FileManager.default.createFile(atPath: dest.path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: dest.path)
            if fileHandle == nil {
                self.error = NSError(domain: "StreamingFileReceive", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "Failed to create file"])
            }

        case .body(let body):
            guard error == nil, let fh = fileHandle else { return }
            let data = Data(body.readableBytesView)
            do {
                try fh.write(contentsOf: data)
                bytesWritten += data.count

                // Progress logging every 10MB
                if bytesWritten % (10 * 1024 * 1024) < data.count {
                    let mb = bytesWritten / (1024 * 1024)
                    let totalMB = contentLength / (1024 * 1024)
                    print("[StreamingFileReceive] Progress: \(mb)/\(totalMB) MB")
                }
            } catch {
                print("[StreamingFileReceive] Write error: \(error)")
                self.error = error
            }

        case .end:
            try? fileHandle?.close()
            fileHandle = nil

            guard let head = requestHead else { return }
            requestHead = nil

            if let error = error {
                writeErrorResponse("Failed to save file: \(error.localizedDescription)", context: context)
                return
            }

            guard let dest = destURL, let base = baseURL else {
                writeErrorResponse("Internal error", context: context)
                return
            }

            print("[StreamingFileReceive] File saved: \(dest.path) (\(bytesWritten) bytes)")

            // Apply permissions if provided
            if let permStr = head.headers["X-Permissions"].first,
               let mode = Int(permStr, radix: 8) {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dest.path)
            }

            // Batch reveal: accumulate paths per batch, reveal on last file
            let batchID = head.headers["X-Batch-ID"].first
            let isLastInBatch = head.headers["X-Batch-Last"].first == "true"

            if let batchID = batchID {
                BatchTracker.shared.add(url: dest, batchID: batchID)
                if isLastInBatch {
                    let allFiles = BatchTracker.shared.finish(batchID: batchID)
                    let topLevelURLs = Self.computeTopLevelItems(allFiles, baseURL: base)
                    NSWorkspace.shared.activateFileViewerSelecting(topLevelURLs)
                }
            } else {
                // No batch — reveal this single file
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            }

            // Send success response
            let response = FileReceiveResponse(path: dest.path)
            guard let jsonData = try? JSONEncoder().encode(response) else {
                writeErrorResponse("Failed to encode response", context: context)
                return
            }
            writeJSONResponse(jsonData, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[StreamingFileReceive] Error: \(error)")
        try? fileHandle?.close()
        fileHandle = nil
        context.close(promise: nil)
    }

    // MARK: - Response helpers

    private func writeErrorResponse(_ message: String, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        let body = Data(#"{"error":"\#(message)"}"#.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(body.count)")
        headers.add(name: "connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: .internalServerError, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func writeJSONResponse(_ data: Data, context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(data.count)")
        headers.add(name: "connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    // MARK: - Path utilities

    /// Sanitize a relative path, preserving folder structure but preventing traversal attacks
    static func sanitizeRelativePath(_ path: String) -> String {
        let components = path.components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { $0.replacingOccurrences(of: "..", with: "_").replacingOccurrences(of: "\\", with: "_") }

        if components.isEmpty {
            return "unnamed"
        }
        return components.joined(separator: "/")
    }

    /// Given a list of file URLs under baseURL, returns the unique top-level items (files or folders)
    static func computeTopLevelItems(_ urls: [URL], baseURL: URL) -> [URL] {
        let basePath = baseURL.path
        var topLevelNames = Set<String>()
        for url in urls {
            let relativePath = String(url.path.dropFirst(basePath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let firstComponent = relativePath.components(separatedBy: "/").first ?? relativePath
            if !firstComponent.isEmpty {
                topLevelNames.insert(firstComponent)
            }
        }
        return topLevelNames.map { baseURL.appendingPathComponent($0) }
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
