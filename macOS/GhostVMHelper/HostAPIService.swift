import AppKit
import Foundation
import GhostVMKit

/// Host-side HTTP API served over a Unix domain socket.
/// vmctl connects here. Requests are proxied to GhostTools in the guest
/// (including screenshot and batch automation paths).
@MainActor
final class HostAPIService {
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
                    continue
                }
                Task { @MainActor [weak self] in
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

    // MARK: - Connection Handler

    private func handleConnection(_ fd: Int32) async {
        // Read HTTP request from the socket on a background queue
        let requestData: Data = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 65536)
                // Read until we have the full request (headers + body)
                var headerEnd = -1
                var contentLength = 0

                while true {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[0..<n])

                    // Check if we've received all headers
                    if headerEnd < 0, let str = String(data: data, encoding: .utf8),
                       let range = str.range(of: "\r\n\r\n") {
                        headerEnd = str.distance(from: str.startIndex, to: range.upperBound)
                        // Parse Content-Length
                        let headerStr = String(str[str.startIndex..<range.lowerBound])
                        for line in headerStr.components(separatedBy: "\r\n") {
                            if line.lowercased().hasPrefix("content-length:") {
                                contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                            }
                        }
                    }

                    // Check if we have the full body
                    if headerEnd >= 0 && data.count >= headerEnd + contentLength {
                        break
                    }
                }
                continuation.resume(returning: data)
            }
        }

        guard !requestData.isEmpty,
              let requestStr = String(data: requestData, encoding: .utf8) else {
            Darwin.close(fd)
            return
        }

        // Parse method, path, body
        let (method, path, headers, body) = parseHTTPRequest(requestStr, rawData: requestData)

        // Route and get response
        let response = await route(method: method, path: path, headers: headers, body: body)

        // Write response on background queue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var headerStr = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
                for (key, value) in response.extraHeaders {
                    headerStr += "\(key): \(value)\r\n"
                }
                headerStr += "\r\n"
                let headerData = Data(headerStr.utf8)
                headerData.withUnsafeBytes { ptr in
                    _ = Darwin.write(fd, ptr.baseAddress!, headerData.count)
                }
                if !response.body.isEmpty {
                    response.body.withUnsafeBytes { ptr in
                        _ = Darwin.write(fd, ptr.baseAddress!, response.body.count)
                    }
                }
                Darwin.close(fd)
                continuation.resume()
            }
        }
    }

    // MARK: - HTTP Parsing

    private func parseHTTPRequest(_ str: String, rawData: Data) -> (method: String, path: String, headers: [String: String]?, body: Data?) {
        let lines = str.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return ("GET", "/", nil, nil) }
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let path = parts.count > 1 ? parts[1] : "/"

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Extract body after \r\n\r\n
        // IMPORTANT: Search in raw bytes, not the UTF-8 string, to avoid character/byte offset misalignment
        let delimiter = Data([0x0d, 0x0a, 0x0d, 0x0a]) // \r\n\r\n
        if let delimiterRange = rawData.range(of: delimiter) {
            let headerEndIndex = delimiterRange.upperBound
            if rawData.count > headerEndIndex {
                return (method, path, headers, Data(rawData[headerEndIndex...]))
            }
        }
        return (method, path, headers.isEmpty ? nil : headers, nil)
    }

    // MARK: - Response Type

    private struct Response {
        let statusCode: Int
        let statusText: String
        let contentType: String
        let body: Data
        let extraHeaders: [String: String]

        init(statusCode: Int, statusText: String, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
            self.statusCode = statusCode
            self.statusText = statusText
            self.contentType = contentType
            self.body = body
            self.extraHeaders = extraHeaders
        }

        static func json(_ data: Data, status: Int = 200) -> Response {
            let httpStatus = HTTPUtilities.HTTPStatus.from(code: status)
            return Response(
                statusCode: httpStatus.rawValue,
                statusText: httpStatus.reasonPhrase,
                contentType: "application/json",
                body: data
            )
        }

        static func png(_ data: Data) -> Response {
            Response(statusCode: 200, statusText: "OK", contentType: "image/png", body: data)
        }

        static func jpeg(_ data: Data) -> Response {
            Response(statusCode: 200, statusText: "OK", contentType: "image/jpeg", body: data)
        }

        static func binary(_ data: Data, headers: [String: String] = [:]) -> Response {
            Response(statusCode: 200, statusText: "OK", contentType: "application/octet-stream", body: data, extraHeaders: headers)
        }

        static func noContent() -> Response {
            Response(statusCode: 204, statusText: "No Content", contentType: "application/json", body: Data())
        }

        static func error(_ status: Int, message: String) -> Response {
            let httpStatus = HTTPUtilities.HTTPStatus.from(code: status)
            let body = try! JSONSerialization.data(withJSONObject: ["error": message])
            return Response(
                statusCode: httpStatus.rawValue,
                statusText: httpStatus.reasonPhrase,
                contentType: "application/json",
                body: body
            )
        }

        static func ok() -> Response {
            json(try! JSONSerialization.data(withJSONObject: ["ok": true]))
        }
    }

    // MARK: - Router

    private func route(method: String, path: String, headers: [String: String]?, body: Data?) async -> Response {
        let cleanPath = path.components(separatedBy: "?").first ?? path

        // Health
        if cleanPath == "/health" {
            return Response.json(try! JSONSerialization.data(withJSONObject: ["status": "ok"]))
        }

        // Screenshot and batch are now guest-side only.
        if cleanPath == "/vm/screenshot" || cleanPath == "/vm/screenshot/annotated" || cleanPath == "/api/v1/batch" {
            return await proxyToGuest(method: method, path: path, headers: headers, body: body)
        }

        // Everything else: proxy to guest via GhostClient
        return await proxyToGuest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Guest Proxy

    private func proxyToGuest(method: String, path: String, headers: [String: String]?, body: Data?) async -> Response {
        guard let client = client else {
            return .error(500, message: "Guest client not available")
        }

        // Use GhostClient's sendHTTPRequest by building a raw HTTP request through the vsock
        // For simplicity, use the specific client methods based on the path
        let cleanPath = path.components(separatedBy: "?").first ?? path

        do {
            // Guest-side screenshot endpoints
            if cleanPath == "/vm/screenshot" && method == "GET" {
                let format = HTTPUtilities.parseQuery(path, key: "format") ?? "png"
                let scale = Double(HTTPUtilities.parseQuery(path, key: "scale") ?? "1.0") ?? 1.0
                let result = try await client.captureGuestScreenshot(format: format, scale: scale)
                return Response(statusCode: 200, statusText: "OK", contentType: result.contentType, body: result.data)
            }
            if cleanPath == "/vm/screenshot/annotated" && method == "GET" {
                let scale = Double(HTTPUtilities.parseQuery(path, key: "scale") ?? "0.5") ?? 0.5
                let data = try await client.captureGuestAnnotatedScreenshot(scale: scale)
                return .json(data)
            }
            if cleanPath == "/api/v1/batch" && method == "POST" {
                guard let body = body else {
                    return .error(400, message: "Request body required")
                }
                guard let request = try? JSONDecoder().decode(BatchRequest.self, from: body) else {
                    return .error(400, message: "Invalid JSON")
                }
                let data = try await client.executeGuestBatch(request)
                return .json(data)
            }

            // Clipboard
            if cleanPath == "/api/v1/clipboard" {
                if method == "GET" {
                    let resp = try await client.getClipboard()
                    if let data = resp.data {
                        let clipType = resp.type ?? "public.utf8-plain-text"
                        return .binary(data, headers: [
                            "Content-Type": "application/octet-stream",
                            "X-Clipboard-Type": clipType,
                        ])
                    }
                    return .noContent()
                } else if method == "POST" {
                    guard let body = body, !body.isEmpty else {
                        return .error(400, message: "Request body required")
                    }
                    let explicitType = headers?["X-Clipboard-Type"] ?? headers?["x-clipboard-type"]
                    let contentType = (headers?["Content-Type"] ?? headers?["content-type"])?.lowercased()

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
                        return (body, explicitType ?? "public.utf8-plain-text")
                    }()

                    try await client.setClipboard(data: clipboardBody, type: clipType)
                    return .ok()
                }
            }

            // Apps
            if cleanPath == "/api/v1/apps" && method == "GET" {
                let resp = try await client.listApps()
                let data = try JSONEncoder().encode(resp)
                return .json(data)
            }
            if cleanPath == "/api/v1/apps/launch" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let bundleId = json["bundleId"] as? String else {
                    return .error(400, message: "Need bundleId")
                }
                try await client.launchApp(bundleId: bundleId)
                return .ok()
            }
            if cleanPath == "/api/v1/apps/activate" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let bundleId = json["bundleId"] as? String else {
                    return .error(400, message: "Need bundleId")
                }
                try await client.activateApp(bundleId: bundleId)
                return .ok()
            }
            if cleanPath == "/api/v1/apps/quit" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let bundleId = json["bundleId"] as? String else {
                    return .error(400, message: "Need bundleId")
                }
                try await client.quitApp(bundleId: bundleId)
                return .ok()
            }
            if cleanPath == "/api/v1/apps/frontmost" && method == "GET" {
                let bundleId = try await client.getFrontmostApp()
                let data = try JSONSerialization.data(withJSONObject: ["bundleId": bundleId ?? ""])
                return .json(data)
            }

            // Accessibility
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
                    return .error(400, message: "Invalid JSON")
                }
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                try await client.performAccessibilityAction(
                    label: json["label"] as? String,
                    role: json["role"] as? String,
                    action: json["action"] as? String ?? "AXPress",
                    target: target, wait: false
                )
                return .ok()
            }
            if cleanPath == "/api/v1/accessibility/menu" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let menuPath = json["path"] as? [String] else {
                    return .error(400, message: "Need path array")
                }
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                try await client.triggerMenuItem(path: menuPath, target: target, wait: false)
                return .ok()
            }
            if cleanPath == "/api/v1/accessibility/type" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let value = json["value"] as? String else {
                    return .error(400, message: "Need value")
                }
                let targetStr = HTTPUtilities.parseQuery(path, key: "target") ?? "front"
                let target = AXTarget(queryValue: targetStr) ?? .front
                try await client.setAccessibilityValue(
                    value, label: json["label"] as? String,
                    role: json["role"] as? String, target: target
                )
                return .ok()
            }

            // Pointer
            if cleanPath == "/api/v1/pointer" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let action = json["action"] as? String else {
                    return .error(400, message: "Need action")
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
                return .ok()
            }

            // Keyboard
            if cleanPath == "/api/v1/input" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    return .error(400, message: "Invalid JSON")
                }
                try await client.sendKeyboardInput(
                    text: json["text"] as? String,
                    keys: json["keys"] as? [String],
                    modifiers: json["modifiers"] as? [String],
                    rate: json["rate"] as? Int,
                    wait: false
                )
                return .ok()
            }

            // Exec
            if cleanPath == "/api/v1/exec" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let command = json["command"] as? String else {
                    return .error(400, message: "Need command")
                }
                let resp = try await client.exec(
                    command: command,
                    args: json["args"] as? [String],
                    timeout: json["timeout"] as? Int
                )
                let data = try JSONEncoder().encode(resp)
                return .json(data)
            }

            // Elements
            if cleanPath == "/api/v1/elements" && method == "GET" {
                let data = try await client.getElements()
                return .json(data)
            }

            // Permissions
            if cleanPath == "/api/v1/permissions" {
                // Proxy to guest
                let data = try await client.getElements() // Use elements as a proxy for permission check
                return .json(data)
            }

            // Open
            if cleanPath == "/api/v1/open" && method == "POST" {
                guard let body = body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let openPath = json["path"] as? String else {
                    return .error(400, message: "Need path")
                }
                try await client.openPath(openPath)
                return .ok()
            }

            // File operations
            if cleanPath == "/api/v1/files" {
                if method == "GET" {
                    let files = try await client.listFiles()
                    let data = try JSONEncoder().encode(FileListResponse(files: files))
                    return .json(data)
                }
                if method == "DELETE" {
                    try await client.clearFileQueue()
                    return .ok()
                }
            }

            // File system
            if cleanPath == "/api/v1/fs" && method == "GET" {
                let dirPath = HTTPUtilities.parseQuery(path, key: "path") ?? "~"
                let resp = try await client.listDirectory(path: dirPath)
                let data = try JSONEncoder().encode(resp)
                return .json(data)
            }

            return .error(404, message: "Not found: \(cleanPath)")
        } catch {
            let desc = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return .error(500, message: desc)
        }
    }

}
