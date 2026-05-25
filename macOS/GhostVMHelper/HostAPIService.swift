import AppKit
import Foundation
import GhostHTTP
import GhostVMKit
@preconcurrency import Virtualization

/// Host-side HTTP API served over a Unix domain socket.
/// vmctl connects here. Requests are proxied to GhostTools in the guest
/// (including screenshot and batch automation paths).
final class HostAPIService {
    private let connectionSlots = DispatchSemaphore(value: 64)
    private weak var client: GhostClient?
    private var vmName: String
    private var socketPath: String
    private var serverFD: Int32 = -1
    private var isRunning = false

    init(vmName: String) {
        self.vmName = vmName
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let apiDir = supportDir.appendingPathComponent("GhostVM/api")
        try? FileManager.default.createDirectory(at: apiDir, withIntermediateDirectories: true)
        self.socketPath = apiDir.appendingPathComponent("\(vmName).GhostVM.sock").path
    }

    func start(client: GhostClient, vmWindow: NSWindow?) {
        self.client = client
        _ = vmWindow

        // Clean up stale socket
        unlink(socketPath)

        // Create Unix domain socket
        serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            NSLog("HostAPIService: Failed to create socket: errno \(errno)")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("HostAPIService: Socket path too long")
            Darwin.close(serverFD)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("HostAPIService: Failed to bind: errno \(errno)")
            Darwin.close(serverFD)
            return
        }

        // Listen
        guard Darwin.listen(serverFD, 5) == 0 else {
            NSLog("HostAPIService: Failed to listen: errno \(errno)")
            Darwin.close(serverFD)
            return
        }

        isRunning = true
        NSLog("HostAPIService: Listening on \(socketPath)")

        // Accept connections on a background thread
        let fd = serverFD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 {
                    if errno == EBADF || errno == EINVAL {
                        break // Socket closed
                    }
                    usleep(10_000)
                    continue
                }
                self?.connectionSlots.wait()
                Task { [weak self] in
                    defer { self?.connectionSlots.signal() }
                    await self?.handleConnection(clientFD)
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
        NSLog("HostAPIService: Stopped")
    }

    nonisolated private static func setReceiveTimeout(fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    nonisolated private static func logTransportFailure(_ message: String) {
        NSLog("HostAPIService FATAL: \(message)\n\(Thread.callStackSymbols.joined(separator: "\n"))")
    }

    nonisolated private static func connectRawWithTimeout(
        client: GhostClient,
        port: UInt32,
        seconds: TimeInterval
    ) async throws -> VZVirtioSocketConnection {
        final class ConnectState: @unchecked Sendable {
            private let lock = NSLock()
            let semaphore = DispatchSemaphore(value: 0)
            var completed = false
            var timedOut = false
            var connection: VZVirtioSocketConnection?
            var error: Error?

            func finish(connection: VZVirtioSocketConnection) {
                lock.lock()
                completed = true
                if timedOut {
                    lock.unlock()
                    connection.close()
                    semaphore.signal()
                    return
                }
                self.connection = connection
                lock.unlock()
                semaphore.signal()
            }

            func finish(error: Error) {
                lock.lock()
                completed = true
                self.error = error
                lock.unlock()
                semaphore.signal()
            }

            func markTimedOut() {
                lock.lock()
                timedOut = true
                lock.unlock()
            }
        }

        let state = ConnectState()
        Task {
            do {
                let connection = try await client.connectRaw(port: port)
                state.finish(connection: connection)
            } catch {
                state.finish(error: error)
            }
        }

        let completed = try await runBlocking {
            state.semaphore.wait(timeout: .now() + seconds) == .success
        }
        guard completed else {
            state.markTimedOut()
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "Operation timed out after \(seconds) seconds"]
            )
        }
        if let error = state.error {
            throw error
        }
        if let connection = state.connection {
            return connection
        }
        throw GhostClientError.connectionFailed("Connection attempt completed without a result")
    }

    // MARK: - Connection Handler

    private func handleConnection(_ fd: Int32) async {
        Self.setReceiveTimeout(fd: fd, seconds: 30)
        var responseStarted = false

        do {
            let (request, prelude) = try await Self.runBlocking {
                try HTTPCodec.readRequest(fd: fd)
            }

            let cleanPath = request.path.components(separatedBy: "?").first ?? request.path
            if cleanPath == "/api/v1/shell" {
                await handleShellProxy(vmctlFD: fd, request: request)
                return
            }
            if cleanPath == "/api/v1/vsock-connect" {
                await handleVsockConnectProxy(vmctlFD: fd, headers: request.headers)
                return
            }

            let body = try await Self.readRequestBody(fd: fd, request: request, prelude: prelude)
            let response = await route(request: request, body: body)
            responseStarted = true
            try await Self.writeResponse(fd: fd, response: response)
        } catch {
            Self.logTransportFailure("Failed to handle request: \(error)")
            if !responseStarted {
                try? await Self.writeResponse(fd: fd, response: Self.errorResponse(for: error))
            }
        }

        Darwin.close(fd)
    }

    // MARK: - Shell Proxy

    /// Proxies a shell session: vmctl ↔ HostAPIService ↔ GhostTools (vsock).
    /// Instead of request/response, switches to bidirectional byte bridging.
    private func handleShellProxy(vmctlFD: Int32, request: HTTPRequestHead) async {
        guard let client = client else {
            try? Self.writeResponseSync(fd: vmctlFD, response: .error(.internalServerError, message: "Guest client not available"))
            Darwin.close(vmctlFD)
            return
        }

        NSLog("HostAPIService: Shell proxy starting")

        // Open a raw vsock connection to GhostTools on port 5000
        let guestConnection: VZVirtioSocketConnection
        do {
            guestConnection = try await Self.connectRawWithTimeout(client: client, port: 5000, seconds: 10)
        } catch {
            NSLog("HostAPIService: Shell proxy failed to connect to guest: \(error)")
            try? Self.writeResponseSync(fd: vmctlFD, response: .error(.internalServerError, message: "Failed to connect shell proxy"))
            Darwin.close(vmctlFD)
            return
        }

        let guestFD = guestConnection.fileDescriptor
        NSLog("HostAPIService: Shell proxy connected to guest (fd=\(guestFD))")

        let upgraded: HTTPUpgradedConnection
        do {
            Self.setReceiveTimeout(fd: guestFD, seconds: 30)
            upgraded = try await Self.runBlocking {
                try HTTPClient.performUpgradeRequest(
                    fd: guestFD,
                    method: request.method.rawValue,
                    path: request.path,
                    headers: request.headers
                )
            }
        } catch {
            NSLog("HostAPIService: Shell proxy failed to forward upgrade request to guest")
            Self.logTransportFailure("Shell proxy upgrade failed: \(error)")
            try? Self.writeResponseSync(fd: vmctlFD, response: .error(.internalServerError, message: "Shell upgrade failed"))
            guestConnection.close()
            Darwin.close(vmctlFD)
            return
        }

        Self.setReceiveTimeout(fd: guestFD, seconds: 0)

        do {
            try await Self.runBlocking {
                try HTTPCodec.writeResponseHead(
                    fd: vmctlFD,
                    status: upgraded.responseHead.status,
                    headers: upgraded.responseHead.headers
                )
                if !upgraded.prelude.isEmpty {
                    try HTTPCodec.writeAll(fd: vmctlFD, data: upgraded.prelude)
                }
            }
        } catch {
            Self.logTransportFailure("Shell proxy failed to relay guest upgrade response to client: \(error)")
            guestConnection.close()
            Darwin.close(vmctlFD)
            return
        }

        // Now bridge bidirectionally: vmctlFD ↔ guestFD
        // Both sides are raw byte streams from this point on.
        await Self.bridgeBytes(fdA: vmctlFD, fdB: guestFD, label: "shell")
        guestConnection.close()
        Darwin.close(vmctlFD)
        NSLog("HostAPIService: Shell proxy session ended")
    }

    // MARK: - Generic Vsock Proxy
    //
    // Bridges vmctl's unix-socket connection to a raw vsock connection at a
    // requested guest port. After the 101 response, both sides are pure bytes.
    // Used by `vmctl vsock connect <port>` — netcat-style debugging tool.

    private func handleVsockConnectProxy(vmctlFD: Int32, headers: HTTPHeaders) async {
        guard let client = client else {
            Self.writeShortError(fd: vmctlFD, status: 500, text: "Internal Server Error")
            Darwin.close(vmctlFD)
            return
        }

        // Required: Vsock-Port header.
        let portString = headers["Vsock-Port"]
        guard let portString = portString, let port = UInt32(portString) else {
            Self.writeShortError(fd: vmctlFD, status: 400, text: "Missing or invalid Vsock-Port header")
            Darwin.close(vmctlFD)
            return
        }

        NSLog("HostAPIService: vsock-connect proxy starting (port=\(port))")

        let guestConnection: VZVirtioSocketConnection
        do {
            guestConnection = try await Self.connectRawWithTimeout(client: client, port: port, seconds: 10)
        } catch {
            NSLog("HostAPIService: vsock-connect failed to open port \(port): \(error)")
            Self.writeShortError(fd: vmctlFD, status: 502, text: "Bad Gateway: \(error.localizedDescription)")
            Darwin.close(vmctlFD)
            return
        }

        let guestFD = guestConnection.fileDescriptor
        NSLog("HostAPIService: vsock-connect opened guest fd=\(guestFD) port=\(port)")

        // Tell vmctl the bridge is up.
        do {
            try Self.writeResponseSync(
                fd: vmctlFD,
                response: HTTPResponse(
                    status: .switchingProtocols,
                    headers: [
                        "Upgrade": "vsock",
                        "Connection": "Upgrade",
                    ]
                ),
                headOnly: true
            )
        } catch {
            Self.logTransportFailure("vsock-connect failed to write 101 to vmctl: \(error)")
            guestConnection.close()
            Darwin.close(vmctlFD)
            return
        }

        await Self.bridgeBytes(fdA: vmctlFD, fdB: guestFD, label: "vsock-connect(\(port))")
        guestConnection.close()
        Darwin.close(vmctlFD)
        NSLog("HostAPIService: vsock-connect(\(port)) session ended")
    }

    /// Bidirectional blocking byte bridge between two fds. Returns when both
    /// directions have hit EOF/error. Uses SHUT_WR to propagate half-close so
    /// the peer of each direction sees a proper EOF.
    nonisolated static func bridgeBytes(fdA: Int32, fdB: Int32, label: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()

            setReceiveTimeout(fd: fdA, seconds: 0)
            setReceiveTimeout(fd: fdB, seconds: 0)

            // A → B
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 16384)
                var shouldSignalEOF = true
                while true {
                    let n = Darwin.read(fdA, &buffer, buffer.count)
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    if n <= 0 { break }
                    let ok = buffer.withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress else { return n == 0 }
                        do {
                            try HTTPCodec.writeAll(fd: fdB, ptr: base, count: n)
                            return true
                        } catch {
                            return false
                        }
                    }
                    if !ok {
                        NSLog("HostAPIService: \(label) write A→B failed: errno \(errno)")
                        Darwin.shutdown(fdA, SHUT_RD)
                        Darwin.shutdown(fdB, SHUT_WR)
                        shouldSignalEOF = false
                        break
                    }
                }
                if shouldSignalEOF {
                    Darwin.shutdown(fdB, SHUT_WR)
                }
                group.leave()
            }

            // B → A
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [UInt8](repeating: 0, count: 16384)
                var shouldSignalEOF = true
                while true {
                    let n = Darwin.read(fdB, &buffer, buffer.count)
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    if n <= 0 { break }
                    let ok = buffer.withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress else { return n == 0 }
                        do {
                            try HTTPCodec.writeAll(fd: fdA, ptr: base, count: n)
                            return true
                        } catch {
                            return false
                        }
                    }
                    if !ok {
                        NSLog("HostAPIService: \(label) write B→A failed: errno \(errno)")
                        Darwin.shutdown(fdB, SHUT_RD)
                        Darwin.shutdown(fdA, SHUT_WR)
                        shouldSignalEOF = false
                        break
                    }
                }
                if shouldSignalEOF {
                    Darwin.shutdown(fdA, SHUT_WR)
                }
                group.leave()
            }

            group.notify(queue: .global()) {
                continuation.resume()
            }
        }
    }

    nonisolated private static func writeShortError(fd: Int32, status: Int, text: String) {
        try? writeResponseSync(fd: fd, response: .error(.from(code: status), message: text))
    }

    private func clipboardType(explicitType: String?, contentType: String?) -> String {
        if let explicitType, !explicitType.isEmpty {
            return explicitType
        }
        guard let contentType else { return "public.utf8-plain-text" }

        let mimeType = contentType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch mimeType {
        case "image/png": return "public.png"
        case "image/tiff": return "public.tiff"
        case "image/jpeg": return "public.jpeg"
        case "text/rtf", "application/rtf": return "public.rtf"
        case "text/plain": return "public.utf8-plain-text"
        default: return "public.utf8-plain-text"
        }
    }

    // MARK: - Router

    private func route(request: HTTPRequestHead, body: Data?) async -> HTTPResponse {
        let cleanPath = request.path.components(separatedBy: "?").first ?? request.path

        // Health
        if cleanPath == "/health" {
            return .json(try! JSONSerialization.data(withJSONObject: ["status": "ok"]))
        }

        // Everything else: proxy to guest via GhostClient
        return await proxyToGuest(request: request, body: body)
    }

    // MARK: - Guest Proxy

    private func proxyToGuest(request: HTTPRequestHead, body: Data?) async -> HTTPResponse {
        guard let client = client else {
            return .error(.internalServerError, message: "Guest client not available")
        }

        let method = request.method.rawValue
        let path = request.path
        let cleanPath = path.components(separatedBy: "?").first ?? path

        do {
            if cleanPath == "/vm/screenshot" && method == "GET" {
                let format = HTTPUtilities.parseQuery(path, key: "format") ?? "png"
                let scale = Double(HTTPUtilities.parseQuery(path, key: "scale") ?? "1.0") ?? 1.0
                let result = try await client.captureGuestScreenshot(format: format, scale: scale)
                return HTTPResponse(status: .ok, headers: ["Content-Type": result.contentType], body: .bytes(result.data))
            }
            if cleanPath == "/vm/screenshot/annotated" && method == "GET" {
                let scale = Double(HTTPUtilities.parseQuery(path, key: "scale") ?? "0.5") ?? 0.5
                let data = try await client.captureGuestAnnotatedScreenshot(scale: scale)
                return .json(data)
            }
            if cleanPath == "/api/v1/batch" && method == "POST" {
                guard let body = body else {
                    return .error(.badRequest, message: "Request body required")
                }
                guard let request = try? JSONDecoder().decode(BatchRequest.self, from: body) else {
                    return .error(.badRequest, message: "Invalid JSON")
                }
                let data = try await client.executeGuestBatch(request)
                return .json(data)
            }

            if cleanPath == "/api/v1/clipboard" {
                if method == "GET" {
                    let resp = try await client.getClipboard()
                    if let data = resp.data {
                        let clipType = resp.type ?? "public.utf8-plain-text"
                        return HTTPResponse(status: .ok, headers: [
                            "Content-Type": "application/octet-stream",
                            "X-Clipboard-Type": clipType,
                        ], body: .bytes(data))
                    }
                    return HTTPResponse(status: .noContent)
                } else if method == "POST" {
                    guard let body = body, !body.isEmpty else {
                        return .error(.badRequest, message: "Request body required")
                    }
                    let explicitType = request.headers["X-Clipboard-Type"]
                    let contentType = request.headers["Content-Type"]?.lowercased()

                    let (clipboardBody, clipType): (Data, String) = {
                        // Backward compatibility for older UI clients posting JSON:
                        // {"content":"...","type":"public.utf8-plain-text"}
                        if explicitType == nil,
                           contentType?.contains("application/json") == true,
                           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                           let content = object["content"] as? String {
                            let parsedType = (object["type"] as? String) ?? "public.utf8-plain-text"
                            return (Data(content.utf8), parsedType)
                        }
                        return (body, clipboardType(explicitType: explicitType, contentType: contentType))
                    }()

                    try await client.setClipboard(data: clipboardBody, type: clipType)
                    return Self.okResponse()
                }
            }

            if cleanPath == "/api/v1/apps" && method == "GET" {
                let resp = try await client.listApps()
                let data = try JSONEncoder().encode(resp)
                return .json(data)
            }
            if cleanPath == "/api/v1/apps/launch" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let bundleId = json["bundleId"] as? String else {
                    return .error(.badRequest, message: "Need bundleId")
                }
                try await client.launchApp(bundleId: bundleId)
                return Self.okResponse()
            }
            if cleanPath == "/api/v1/apps/activate" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let bundleId = json["bundleId"] as? String else {
                    return .error(.badRequest, message: "Need bundleId")
                }
                try await client.activateApp(bundleId: bundleId)
                return Self.okResponse()
            }
            if cleanPath == "/api/v1/apps/quit" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let bundleId = json["bundleId"] as? String else {
                    return .error(.badRequest, message: "Need bundleId")
                }
                try await client.quitApp(bundleId: bundleId)
                return Self.okResponse()
            }
            if cleanPath == "/api/v1/apps/frontmost" && method == "GET" {
                let bundleId = try await client.getFrontmostApp()
                let data = try JSONSerialization.data(withJSONObject: ["bundleId": bundleId ?? ""])
                return .json(data)
            }

            if cleanPath == "/api/v1/accessibility" && method == "GET" {
                let depth = Int(HTTPUtilities.parseQuery(path, key: "depth") ?? "5") ?? 5
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                if target.isMulti {
                    let trees = try await client.getAccessibilityTrees(depth: depth, target: target)
                    let data = try JSONEncoder().encode(trees)
                    return .json(data)
                } else {
                    let tree = try await client.getAccessibilityTree(depth: depth, target: target)
                    let data = try JSONEncoder().encode(tree)
                    return .json(data)
                }
            }
            if cleanPath == "/api/v1/accessibility/focused" && method == "GET" {
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                let info = try await client.getFocusedElement(target: target)
                let data = try JSONSerialization.data(withJSONObject: info)
                return .json(data)
            }
            if cleanPath == "/api/v1/accessibility/action" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return .error(.badRequest, message: "Invalid JSON")
                }
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                try await client.performAccessibilityAction(
                    label: json["label"] as? String,
                    role: json["role"] as? String,
                    action: json["action"] as? String ?? "AXPress",
                    target: target, wait: false
                )
                return Self.okResponse()
            }
            if cleanPath == "/api/v1/accessibility/menu" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let menuPath = json["path"] as? [String] else {
                    return .error(.badRequest, message: "Need path array")
                }
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                try await client.triggerMenuItem(path: menuPath, target: target, wait: false)
                return Self.okResponse()
            }
            if cleanPath == "/api/v1/accessibility/type" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let value = json["value"] as? String else {
                    return .error(.badRequest, message: "Need value")
                }
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                try await client.setAccessibilityValue(
                    value, label: json["label"] as? String,
                    role: json["role"] as? String, target: target
                )
                return Self.okResponse()
            }

            if cleanPath == "/api/v1/pointer" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let action = json["action"] as? String else {
                    return .error(.badRequest, message: "Need action")
                }
                let responseData = try await client.sendPointerEvent(
                    action: action,
                    x: json["x"] as? Double,
                    y: json["y"] as? Double,
                    button: json["button"] as? String,
                    label: json["label"] as? String,
                    endX: json["endX"] as? Double,
                    endY: json["endY"] as? Double,
                    deltaX: json["deltaX"] as? Double,
                    deltaY: json["deltaY"] as? Double,
                    wait: false
                )
                if let data = responseData {
                    return .json(data)
                }
                return Self.okResponse()
            }

            if cleanPath == "/api/v1/input" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return .error(.badRequest, message: "Invalid JSON")
                }
                try await client.sendKeyboardInput(
                    text: json["text"] as? String,
                    keys: json["keys"] as? [String],
                    modifiers: json["modifiers"] as? [String],
                    rate: json["rate"] as? Int,
                    wait: false
                )
                return Self.okResponse()
            }

            if cleanPath == "/api/v1/exec" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let command = json["command"] as? String else {
                    return .error(.badRequest, message: "Need command")
                }
                let resp = try await client.exec(
                    command: command,
                    args: json["args"] as? [String],
                    timeout: json["timeout"] as? Int
                )
                let data = try JSONEncoder().encode(resp)
                return .json(data)
            }

            if cleanPath == "/api/v1/elements" && method == "GET" {
                let data = try await client.getElements()
                return .json(data)
            }

            if cleanPath == "/api/v1/permissions" {
                let data = try await client.checkPermissions(prompt: method == "POST")
                return .json(data)
            }

            if cleanPath == "/api/v1/open" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let openPath = json["path"] as? String else {
                    return .error(.badRequest, message: "Need path")
                }
                try await client.openPath(openPath)
                return Self.okResponse()
            }

            if cleanPath == "/api/v1/files" {
                if method == "GET" {
                    let files = try await client.listFiles()
                    let data = try JSONEncoder().encode(FileListResponse(files: files))
                    return .json(data)
                }
                if method == "DELETE" {
                    try await client.clearFileQueue()
                    return Self.okResponse()
                }
            }

            if cleanPath == "/api/v1/fs" && method == "GET" {
                let dirPath = HTTPUtilities.parseQuery(path, key: "path") ?? "~"
                let resp = try await client.listDirectory(path: dirPath)
                let data = try JSONEncoder().encode(resp)
                return .json(data)
            }

            return .error(.notFound, message: "Not found: \(cleanPath)")
        } catch {
            let desc = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return .error(.internalServerError, message: desc)
        }
    }

    nonisolated private static func okResponse() -> HTTPResponse {
        .json(try! JSONSerialization.data(withJSONObject: ["ok": true]))
    }

    nonisolated private static func errorResponse(for error: Error) -> HTTPResponse {
        let status: HTTPStatus
        if let httpError = error as? HTTPError {
            switch httpError {
            case .headerTooLarge:
                status = .headerTooLarge
            case .bodyTooLarge:
                status = .payloadTooLarge
            case .unexpectedEOF, .readFailed:
                status = .requestTimeout
            default:
                status = .badRequest
            }
        } else {
            status = .internalServerError
        }
        return .error(status, message: error.localizedDescription)
    }

    nonisolated private static func readRequestBody(fd: Int32, request: HTTPRequestHead, prelude: Data) async throws -> Data? {
        let framing = HTTPCodec.requestFraming(for: request)
        switch framing {
        case .knownLength(0):
            return nil
        default:
            return try await runBlocking {
                let reader = HTTPBodyReader(fd: fd, framing: framing, prelude: prelude)
                return try reader.readAll(maxSize: 64 * 1024 * 1024)
            }
        }
    }

    nonisolated private static func writeResponse(fd: Int32, response: HTTPResponse) async throws {
        try await runBlocking {
            try writeResponseSync(fd: fd, response: response)
        }
    }

    nonisolated private static func writeResponseSync(fd: Int32, response: HTTPResponse, headOnly: Bool = false) throws {
        if headOnly {
            try HTTPCodec.writeResponseHead(fd: fd, status: response.status, headers: response.headers)
        } else {
            try HTTPCodec.writeResponse(response, fd: fd)
        }
    }

    nonisolated private static func runBlocking<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

}
