import Foundation
import NIOCore
import NIOHTTP1
import AppKit
import os

/// Dispatches HTTP streams to the appropriate handler based on the request URI.
/// Used for both HTTP/1.1 and HTTP/2 connections.
///
/// - `/api/v1/shell` → ShellHandler (via WebSocket upgrade, before this handler)
/// - `POST /api/v1/files/receive` → StreamingFileReceiveHandler (streams to disk)
/// - Everything else → RouterBridgeHandler (request/response via Router)
final class StreamDispatcher: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "StreamDispatcher")

    private let router: Router
    private var dispatched = false

    init(router: Router) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !dispatched {
            let part = unwrapInboundIn(data)
            guard case .head(let head) = part else {
                context.fireChannelRead(data)
                return
            }

            dispatched = true
            Self.logger.info("dispatching \(head.method.rawValue, privacy: .public) \(head.uri, privacy: .public)")

            // Choose handler and add it directly after us in the pipeline.
            // We stay in the pipeline as a pass-through — no remove/re-add race.
            let newHandler: ChannelHandler & RemovableChannelHandler
            if head.method == .POST && head.uri == "/api/v1/files/receive" {
                newHandler = StreamingFileReceiveHandler()
            } else {
                newHandler = RouterBridgeHandler(router: router)
            }

            // Synchronous add — we're on the event loop already
            do {
                try context.pipeline.syncOperations.addHandler(newHandler, position: .after(self))
            } catch {
                Self.logger.fault("failed to add handler: \(error.localizedDescription, privacy: .public)")
                context.close(promise: nil)
                return
            }
        }

        // Forward everything (including the initial .head) to the next handler
        context.fireChannelRead(data)
    }
}

// MARK: - Streaming File Receive

/// Shared batch state for file receives across connections.
/// Tracks file paths per batch ID so that Finder reveal happens once
/// when the last file in a batch arrives.
private final class BatchTracker {
    nonisolated(unsafe) static let shared = BatchTracker()
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
    private var httpVersion: HTTPVersion = .http1_1
    private var bytesWritten = 0
    private var contentLength = 0
    private var requestHead: HTTPRequestHead?
    private var error: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            requestHead = head
            httpVersion = head.version
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
        if httpVersion.major == 1 {
            headers.add(name: "connection", value: "close")
        }

        let head = HTTPResponseHead(version: httpVersion, status: .internalServerError, headers: headers)
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
        if httpVersion.major == 1 {
            headers.add(name: "connection", value: "close")
        }

        let head = HTTPResponseHead(version: httpVersion, status: .ok, headers: headers)
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
final class RouterBridgeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "RouterBridge")

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
            Self.logger.info("request head: \(head.method.rawValue, privacy: .public) \(head.uri, privacy: .public)")
            requestHead = head
            bodyBuffer.clear()

        case .body(var body):
            Self.logger.debug("request body chunk: \(body.readableBytes) bytes")
            bodyBuffer.writeBuffer(&body)

        case .end:
            guard let head = requestHead else {
                Self.logger.warning("received .end with no requestHead")
                return
            }
            requestHead = nil
            Self.logger.info("request complete: \(head.method.rawValue, privacy: .public) \(head.uri, privacy: .public) bodySize=\(self.bodyBuffer.readableBytes)")

            guard let method = convertMethod(head.method) else {
                Self.logger.error("unsupported HTTP method: \(head.method.rawValue, privacy: .public)")
                print("[RouterBridge] FATAL: unsupported HTTP method \(head.method)\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                writeResponse(HTTPResponse.error(.methodNotAllowed, message: "Unsupported HTTP method: \(head.method)"), version: head.version, context: context)
                requestHead = nil
                bodyBuffer.clear()
                return
            }
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
            let httpVersion = head.version
            nonisolated(unsafe) let ctx = context
            nonisolated(unsafe) let handlerRef = self
            Task {
                Self.logger.debug("routing \(head.uri, privacy: .public) to Router.handle")
                let response = await routerRef.handle(request)
                Self.logger.info("router returned status=\(response.status.rawValue) bodySize=\(response.body?.count ?? 0) for \(head.uri, privacy: .public)")
                channel.eventLoop.execute {
                    handlerRef.writeResponse(response, version: httpVersion, context: ctx)
                }
            }
        }
    }

    private func writeResponse(_ response: HTTPResponse, version: HTTPVersion = .http1_1, context: ChannelHandlerContext) {
        guard context.channel.isActive else {
            Self.logger.warning("writeResponse: channel inactive, dropping response status=\(response.status.rawValue)")
            return
        }

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
        // connection header is forbidden in HTTP/2
        if version.major == 1 {
            headers.replaceOrAdd(name: "connection", value: "close")
        }

        Self.logger.debug("writeResponse: status=\(status.code) version=\(version.major).\(version.minor)")

        let head = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        if let body = response.body, !body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }

        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { result in
            switch result {
            case .success:
                Self.logger.debug("writeResponse: flush+close succeeded")
            case .failure(let error):
                Self.logger.error("writeResponse: flush failed: \(error.localizedDescription, privacy: .public)")
            }
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Self.logger.error("errorCaught: \(error.localizedDescription, privacy: .public)")
        print("[RouterBridge] Error: \(error)")
        context.close(promise: nil)
    }

    private func convertMethod(_ method: NIOHTTP1.HTTPMethod) -> HTTPMethod? {
        switch method {
        case .GET: return .GET
        case .POST: return .POST
        case .PUT: return .PUT
        case .DELETE: return .DELETE
        case .HEAD: return .HEAD
        case .OPTIONS: return .OPTIONS
        case .PATCH: return .PATCH
        default: return nil
        }
    }
}
