import Foundation
import Virtualization
import GhostVMKit

/// HTTP client for communicating with GhostTools running in the guest VM
/// Supports both vsock (production) and TCP (development) connections
@MainActor
public final class GhostClient: GhostClientProtocol {
    private nonisolated(unsafe) let virtualMachine: VZVirtualMachine?
    private nonisolated(unsafe) let vmQueue: DispatchQueue?
    private let vsockPort: UInt32 = 5000
    private nonisolated(unsafe) let authToken: String?

    // For development/testing without vsock
    private nonisolated(unsafe) let tcpHost: String?
    private nonisolated(unsafe) let tcpPort: Int?

    private nonisolated(unsafe) var urlSession: URLSession?

    /// Initialize client for vsock communication with a running VM
    /// - Parameters:
    ///   - virtualMachine: The VZVirtualMachine instance
    ///   - vmQueue: The dispatch queue used for VM operations (from WindowlessVMSession.vmQueue)
    ///   - authToken: Optional authentication token
    public init(virtualMachine: VZVirtualMachine, vmQueue: DispatchQueue, authToken: String? = nil) {
        self.virtualMachine = virtualMachine
        self.vmQueue = vmQueue
        self.authToken = authToken
        self.tcpHost = nil
        self.tcpPort = nil
    }

    /// Initialize client for TCP communication (development/testing)
    public init(host: String, port: Int, authToken: String? = nil) {
        self.virtualMachine = nil
        self.vmQueue = nil
        self.authToken = authToken
        self.tcpHost = host
        self.tcpPort = port

        // Create URL session for TCP connections
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.urlSession = URLSession(configuration: config)
    }

    /// Get current guest clipboard contents
    public func getClipboard() async throws -> ClipboardGetResponse {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await getClipboardViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return try await getClipboardViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    /// Set guest clipboard contents
    public func setClipboard(content: String, type: String = "public.utf8-plain-text") async throws {
        let request = ClipboardPostRequest(content: content, type: type)

        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            try await setClipboardViaTCP(host: tcpHost, port: tcpPort, request: request)
        } else if let vm = virtualMachine {
            try await setClipboardViaVsock(vm: vm, request: request)
        } else {
            throw GhostClientError.notConnected
        }
    }

    // MARK: - File Transfer

    /// Send a file to the guest VM (streaming - supports large files)
    /// - Parameters:
    ///   - fileURL: URL of the file to send
    ///   - relativePath: Optional relative path to preserve folder structure (e.g., "folder/subfolder/file.txt")
    ///   - progressHandler: Optional callback for progress updates (0.0 to 1.0)
    /// - Returns: The path where the file was saved in the guest
    public nonisolated func sendFile(fileURL: URL, relativePath: String? = nil, batchID: String? = nil, isLastInBatch: Bool = false, permissions: Int? = nil, progressHandler: ((Double) -> Void)? = nil) async throws -> String {
        let pathToSend = relativePath ?? fileURL.lastPathComponent
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await sendFileViaTCP(host: tcpHost, port: tcpPort, fileURL: fileURL, relativePath: pathToSend, batchID: batchID, isLastInBatch: isLastInBatch, permissions: permissions, progressHandler: progressHandler)
        } else if let vm = virtualMachine {
            return try await sendFileViaVsock(vm: vm, fileURL: fileURL, relativePath: pathToSend, batchID: batchID, isLastInBatch: isLastInBatch, permissions: permissions, progressHandler: progressHandler)
        } else {
            throw GhostClientError.notConnected
        }
    }

    /// Fetch a file from the guest VM
    /// - Parameter path: The file path in the guest to fetch
    /// - Returns: The file data and filename
    public func fetchFile(at path: String) async throws -> (data: Data, filename: String, permissions: Int?) {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await fetchFileViaTCP(host: tcpHost, port: tcpPort, path: path)
        } else if let vm = virtualMachine {
            return try await fetchFileViaVsock(vm: vm, path: path)
        } else {
            throw GhostClientError.notConnected
        }
    }

    /// List files available from the guest
    public func listFiles() async throws -> [String] {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await listFilesViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return try await listFilesViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    /// Clear the file queue on the guest
    public func clearFileQueue() async throws {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            try await clearFileQueueViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            try await clearFileQueueViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    // MARK: - URL Forwarding

    /// Fetch and clear pending URLs from guest (URLs to open on host)
    public func fetchPendingURLs() async throws -> [String] {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return try await fetchURLsViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return try await fetchURLsViaVsock(vm: vm)
        } else {
            throw GhostClientError.notConnected
        }
    }

    // MARK: - Open Path

    /// Ask the guest to open a path (e.g. in Finder)
    public func openPath(_ path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            try await openPathViaTCP(host: tcpHost, port: tcpPort, body: body)
        } else if let vm = virtualMachine {
            try await openPathViaVsock(vm: vm, body: body)
        } else {
            throw GhostClientError.notConnected
        }
    }

    private func openPathViaTCP(host: String, port: Int, body: Data) async throws {
        guard let session = urlSession else { throw GhostClientError.notConnected }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/open")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = body

        let (_, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func openPathViaVsock(vm: VZVirtualMachine, body: Data) async throws {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "POST",
            path: "/api/v1/open",
            body: body,
            contentType: "application/json"
        )
        let (statusCode, _) = try HTTPResponseParser.parse(responseData)
        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }
    }

    // MARK: - App Management

    /// List running GUI apps in the guest
    public func listApps() async throws -> AppListResponse {
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: "/api/v1/apps", body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw GhostClientError.invalidResponse(statusCode)
            }
            return try JSONDecoder().decode(AppListResponse.self, from: body)
        }
        throw GhostClientError.notConnected
    }

    /// Launch an app by bundle identifier in the guest
    public func launchApp(bundleId: String) async throws {
        let body = try JSONEncoder().encode(["bundleId": bundleId])
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/apps/launch", body: body, contentType: "application/json")
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Activate (bring to front) an app in the guest
    public func activateApp(bundleId: String) async throws {
        let body = try JSONEncoder().encode(["bundleId": bundleId])
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/apps/activate", body: body, contentType: "application/json")
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Quit an app in the guest
    public func quitApp(bundleId: String) async throws {
        let body = try JSONEncoder().encode(["bundleId": bundleId])
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/apps/quit", body: body, contentType: "application/json")
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    // MARK: - File System

    /// List directory contents in the guest
    public func listDirectory(path: String) async throws -> FSListResponse {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: "/api/v1/fs?path=\(encodedPath)", body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw GhostClientError.invalidResponse(statusCode)
            }
            return try JSONDecoder().decode(FSListResponse.self, from: body)
        }
        throw GhostClientError.notConnected
    }

    /// Create a directory in the guest
    public func mkdir(path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/fs/mkdir", body: body, contentType: "application/json")
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Delete a file or directory in the guest
    public func deleteFile(path: String) async throws {
        let body = try JSONEncoder().encode(["path": path])
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/fs/delete", body: body, contentType: "application/json")
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Move/rename a file or directory in the guest
    public func moveFile(from: String, to: String) async throws {
        let body = try JSONEncoder().encode(["from": from, "to": to])
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/fs/move", body: body, contentType: "application/json")
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Accessibility

    /// Build a path with optional target query param
    private func a11yPath(_ base: String, depth: Int? = nil, target: AXTarget = .front) -> String {
        var parts: [String] = []
        if let depth = depth { parts.append("depth=\(depth)") }
        if case .front = target { /* omit for backward compat */ } else {
            let encoded = target.queryValue.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target.queryValue
            parts.append("target=\(encoded)")
        }
        if parts.isEmpty { return base }
        return base + "?" + parts.joined(separator: "&")
    }

    /// Get the accessibility tree of a single target app in the guest
    public func getAccessibilityTree(depth: Int = 5, target: AXTarget = .front) async throws -> AXTreeResponse {
        if let vm = virtualMachine {
            let path = a11yPath("/api/v1/accessibility", depth: depth, target: target)
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: path, body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw guestError(body, statusCode: statusCode)
            }
            return try JSONDecoder().decode(AXTreeResponse.self, from: body)
        }
        throw GhostClientError.notConnected
    }

    /// Get accessibility trees for a multi-target query (--all, --visible)
    public func getAccessibilityTrees(depth: Int = 5, target: AXTarget = .front) async throws -> [AXTreeResponse] {
        if let vm = virtualMachine {
            let path = a11yPath("/api/v1/accessibility", depth: depth, target: target)
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: path, body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw guestError(body, statusCode: statusCode)
            }
            if target.isMulti {
                return try JSONDecoder().decode([AXTreeResponse].self, from: body)
            } else {
                let single = try JSONDecoder().decode(AXTreeResponse.self, from: body)
                return [single]
            }
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Accessibility Actions

    /// Extract error message from a guest JSON response body, or fall back to status code
    private func guestError(_ respBody: Data?, statusCode: Int) -> GhostClientError {
        if let respBody = respBody,
           let json = try? JSONSerialization.jsonObject(with: respBody) as? [String: Any],
           let msg = json["error"] as? String {
            return .guestError(msg)
        }
        return .invalidResponse(statusCode)
    }

    /// Perform an action on an element in the guest (AXPress, etc.)
    public func performAccessibilityAction(label: String? = nil, role: String? = nil, action: String = "AXPress", target: AXTarget = .front, wait: Bool = false) async throws {
        var payload: [String: Any] = ["action": action]
        if let label = label { payload["label"] = label }
        if let role = role { payload["role"] = role }
        if wait { payload["wait"] = true }
        let body = try JSONSerialization.data(withJSONObject: payload)

        if let vm = virtualMachine {
            let path = a11yPath("/api/v1/accessibility/action", target: target)
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: path, body: body, contentType: "application/json")
            let (statusCode, respBody) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw guestError(respBody, statusCode: statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Trigger a menu item by path (e.g. ["File", "New Window"])
    public func triggerMenuItem(path: [String], target: AXTarget = .front, wait: Bool = false) async throws {
        var payload: [String: Any] = ["path": path]
        if wait { payload["wait"] = true }
        let body = try JSONSerialization.data(withJSONObject: payload)

        if let vm = virtualMachine {
            let urlPath = a11yPath("/api/v1/accessibility/menu", target: target)
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: urlPath, body: body, contentType: "application/json")
            let (statusCode, respBody) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw guestError(respBody, statusCode: statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Set the value of an element (or focused element if no label/role)
    public func setAccessibilityValue(_ value: String, label: String? = nil, role: String? = nil, target: AXTarget = .front) async throws {
        var payload: [String: Any] = ["value": value]
        if let label = label { payload["label"] = label }
        if let role = role { payload["role"] = role }
        let body = try JSONSerialization.data(withJSONObject: payload)

        if let vm = virtualMachine {
            let path = a11yPath("/api/v1/accessibility/type", target: target)
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: path, body: body, contentType: "application/json")
            let (statusCode, respBody) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw guestError(respBody, statusCode: statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Get info about the currently focused UI element
    public func getFocusedElement(target: AXTarget = .front) async throws -> [String: Any] {
        if let vm = virtualMachine {
            let path = a11yPath("/api/v1/accessibility/focused", target: target)
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: path, body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw GhostClientError.invalidResponse(statusCode)
            }
            return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Pointer

    /// Send a pointer/mouse event to the guest
    @discardableResult
    public func sendPointerEvent(action: String, x: Double?, y: Double?, button: String?, label: String?, endX: Double?, endY: Double?, deltaX: Double? = nil, deltaY: Double? = nil, wait: Bool = false) async throws -> Data? {
        var payload: [String: Any] = ["action": action]
        if let x = x { payload["x"] = x }
        if let y = y { payload["y"] = y }
        if let button = button { payload["button"] = button }
        if let label = label { payload["label"] = label }
        if let endX = endX { payload["endX"] = endX }
        if let endY = endY { payload["endY"] = endY }
        if let deltaX = deltaX { payload["deltaX"] = deltaX }
        if let deltaY = deltaY { payload["deltaY"] = deltaY }
        if wait { payload["wait"] = true }
        let body = try JSONSerialization.data(withJSONObject: payload)

        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/pointer", body: body, contentType: "application/json")
            let (statusCode, respBody) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else {
                if statusCode == 403 {
                    throw GhostClientError.connectionFailed("Accessibility permission required in guest")
                }
                throw GhostClientError.invalidResponse(statusCode)
            }
            return respBody
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Keyboard

    /// Send keyboard input to the guest
    public func sendKeyboardInput(text: String?, keys: [String]?, modifiers: [String]?, rate: Int?, wait: Bool = false) async throws {
        var payload: [String: Any] = [:]
        if let text = text { payload["text"] = text }
        if let keys = keys { payload["keys"] = keys }
        if let modifiers = modifiers { payload["modifiers"] = modifiers }
        if let rate = rate { payload["rate"] = rate }
        if wait { payload["wait"] = true }
        let body = try JSONSerialization.data(withJSONObject: payload)

        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/input", body: body, contentType: "application/json")
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else {
                if statusCode == 403 {
                    throw GhostClientError.connectionFailed("Accessibility permission required in guest")
                }
                throw GhostClientError.invalidResponse(statusCode)
            }
            return
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Shell Exec

    /// Execute a command in the guest and return stdout/stderr/exitCode
    public func exec(command: String, args: [String]? = nil, timeout: Int? = nil) async throws -> ExecResponse {
        var payload: [String: Any] = ["command": command]
        if let args = args { payload["args"] = args }
        if let timeout = timeout { payload["timeout"] = timeout }
        let body = try JSONSerialization.data(withJSONObject: payload)

        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/exec", body: body, contentType: "application/json")
            let (statusCode, respBody) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let respBody = respBody else {
                throw GhostClientError.invalidResponse(statusCode)
            }
            return try JSONDecoder().decode(ExecResponse.self, from: respBody)
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Elements (a11y overlay + JSON)

    /// Get interactive elements from guest (shows overlays in guest, returns element JSON)
    public func getElements() async throws -> Data {
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: "/api/v1/elements", body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw guestError(body, statusCode: statusCode)
            }
            return body
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Guest Screenshot / Batch

    /// Capture a screenshot inside the guest (always full-screen).
    public func captureGuestScreenshot(format: String = "png", scale: Double = 1.0) async throws -> (data: Data, contentType: String) {
        if let vm = virtualMachine {
            let path = "/vm/screenshot?format=\(format)&scale=\(scale)"
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: path, body: nil)
            let (statusCode, headers, body) = try HTTPResponseParser.parseBinaryWithHeaders(responseData)
            guard statusCode == 200, let body = body else {
                throw guestError(body, statusCode: statusCode)
            }
            let contentType = headers["Content-Type"] ?? "application/octet-stream"
            return (body, contentType)
        }
        throw GhostClientError.notConnected
    }

    /// Capture annotated screenshot (image + elements) inside the guest.
    public func captureGuestAnnotatedScreenshot(scale: Double = 0.5) async throws -> Data {
        if let vm = virtualMachine {
            let path = "/vm/screenshot/annotated?scale=\(scale)"
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: path, body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw guestError(body, statusCode: statusCode)
            }
            return body
        }
        throw GhostClientError.notConnected
    }

    /// Execute automation batch in the guest.
    public func executeGuestBatch(_ request: BatchRequest) async throws -> Data {
        let body = try JSONEncoder().encode(request)
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(
                vm: vm,
                method: "POST",
                path: "/api/v1/batch",
                body: body,
                contentType: "application/json"
            )
            let (statusCode, respBody) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let respBody = respBody else {
                throw guestError(respBody, statusCode: statusCode)
            }
            return respBody
        }
        throw GhostClientError.notConnected
    }

    /// Show wait indicator overlay in guest
    public func showWaitIndicator() async throws {
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/overlay/wait-show", body: nil)
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Hide wait indicator overlay in guest
    public func hideWaitIndicator() async throws {
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "POST", path: "/api/v1/overlay/wait-hide", body: nil)
            let (statusCode, _) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200 else { throw GhostClientError.invalidResponse(statusCode) }
            return
        }
        throw GhostClientError.notConnected
    }

    /// Get frontmost app bundle ID from guest
    public func getFrontmostApp() async throws -> String? {
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: "GET", path: "/api/v1/apps/frontmost", body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw GhostClientError.invalidResponse(statusCode)
            }
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let bundleId = json["bundleId"] as? String else {
                return nil
            }
            return bundleId.isEmpty ? nil : bundleId
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Permissions

    /// Check or prompt for accessibility permission in the guest
    /// - Parameter prompt: if true, shows macOS permission dialog in the guest
    /// - Returns: JSON data with permission status
    public func checkPermissions(prompt: Bool = false) async throws -> Data {
        let method = prompt ? "POST" : "GET"
        if let vm = virtualMachine {
            let responseData = try await sendHTTPRequest(vm: vm, method: method, path: "/api/v1/permissions", body: nil)
            let (statusCode, body) = try HTTPResponseParser.parse(responseData)
            guard statusCode == 200, let body = body else {
                throw GhostClientError.invalidResponse(statusCode)
            }
            return body
        }
        throw GhostClientError.notConnected
    }

    // MARK: - Log Streaming

    /// Fetch and clear buffered logs from guest
    public func fetchLogs() async throws -> [String] {
        guard let vm = virtualMachine else {
            throw GhostClientError.notConnected
        }
        return try await fetchLogsViaVsock(vm: vm)
    }

    // MARK: - Health Check

    /// Check if GhostTools is running and reachable in the guest
    /// - Returns: true if the guest tools are responding, false otherwise
    public func checkHealth() async -> Bool {
        if let tcpHost = tcpHost, let tcpPort = tcpPort {
            return await checkHealthViaTCP(host: tcpHost, port: tcpPort)
        } else if let vm = virtualMachine {
            return await checkHealthViaVsock(vm: vm)
        } else {
            return false
        }
    }

    private func checkHealthViaTCP(host: String, port: Int) async -> Bool {
        guard let session = urlSession else { return false }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/health")!)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = 2

        do {
            let (_, response) = try await session.data(for: urlRequest)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }

    private func checkHealthViaVsock(vm: VZVirtualMachine) async -> Bool {
        guard let queue = self.vmQueue else {
            return false
        }

        let port = self.vsockPort

        // ALL VZVirtualMachine access must happen on vmQueue per Apple's requirements
        let connection: VZVirtioSocketConnection
        do {
            connection = try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                        continuation.resume(throwing: GhostClientError.connectionFailed("No socket device"))
                        return
                    }
                    socketDevice.connect(toPort: port) { result in
                        switch result {
                        case .success(let conn):
                            continuation.resume(returning: conn)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } catch {
            return false
        }

        // Do blocking I/O on background queue - NOT on main thread!
        let fd = connection.fileDescriptor
        let result: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Send HTTP health check using HTTPUtilities
                let requestData = HTTPUtilities.buildRequest(method: "GET", path: "/health")
                requestData.withUnsafeBytes { ptr in
                    _ = Darwin.write(fd, ptr.baseAddress!, requestData.count)
                }
                Darwin.shutdown(fd, SHUT_WR)

                // Read response
                var buffer = [CChar](repeating: 0, count: 1024)
                let bytesRead = Darwin.read(fd, &buffer, buffer.count - 1)
                connection.close()

                if bytesRead > 0 {
                    let response = String(cString: buffer)
                    continuation.resume(returning: response.contains("200"))
                } else {
                    continuation.resume(returning: false)
                }
            }
        }

        if result {
            return true
        }
        return false
    }

    // MARK: - Raw Vsock Connection

    /// Open a raw vsock connection to the guest on the specified port.
    /// Used by persistent services (HealthCheckService, EventStreamService).
    ///
    /// IMPORTANT: The caller must hold the returned connection object alive for the
    /// duration of I/O. Letting it deallocate closes the underlying file descriptor.
    ///
    /// - Parameter port: The vsock port to connect to
    /// - Returns: The connection (use `.fileDescriptor` for I/O)
    public func connectRaw(port: UInt32) async throws -> VZVirtioSocketConnection {
        guard let vm = virtualMachine, let queue = vmQueue else {
            NSLog("connectRaw: not connected (no VM or queue) for port %u", port)
            throw GhostClientError.notConnected
        }

        NSLog("connectRaw: dispatching to vmQueue for port %u", port)

        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    NSLog("connectRaw: no socket device for port %u", port)
                    continuation.resume(throwing: GhostClientError.connectionFailed("No socket device available"))
                    return
                }
                NSLog("connectRaw: calling socketDevice.connect(toPort: %u)", port)
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        NSLog("connectRaw: connected to port %u (fd=%d)", port, conn.fileDescriptor)
                        continuation.resume(returning: conn)
                    case .failure(let error):
                        NSLog("connectRaw: failed to connect to port %u: %@", port, error.localizedDescription)
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        return connection
    }

    // MARK: - TCP Implementation (Development)

    private func getClipboardViaTCP(host: String, port: Int) async throws -> ClipboardGetResponse {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/clipboard")!)
        urlRequest.httpMethod = "GET"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        if httpResponse.statusCode == 204 {
            throw GhostClientError.noContent
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ClipboardGetResponse.self, from: data)
        } catch {
            throw GhostClientError.decodingError
        }
    }

    private func setClipboardViaTCP(host: String, port: Int, request: ClipboardPostRequest) async throws {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/clipboard")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(request) else {
            throw GhostClientError.encodingError
        }
        urlRequest.httpBody = body

        let (_, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }
    }

    private nonisolated func sendFileViaTCP(host: String, port: Int, fileURL: URL, relativePath: String, batchID: String?, isLastInBatch: Bool, permissions: Int?, progressHandler: ((Double) -> Void)?) async throws -> String {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        let data = try Data(contentsOf: fileURL) // TCP version still loads to memory for simplicity

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files/receive")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(relativePath, forHTTPHeaderField: "X-Filename")
        if let batchID = batchID {
            urlRequest.setValue(batchID, forHTTPHeaderField: "X-Batch-ID")
        }
        if isLastInBatch {
            urlRequest.setValue("true", forHTTPHeaderField: "X-Batch-Last")
        }
        if let permissions = permissions {
            urlRequest.setValue(String(permissions, radix: 8), forHTTPHeaderField: "X-Permissions")
        }
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = data

        progressHandler?(0.5)

        let (responseData, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        progressHandler?(1.0)

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileReceiveResponse.self, from: responseData)
        return fileResponse.path
    }

    private func fetchFileViaTCP(host: String, port: Int, path: String) async throws -> (data: Data, filename: String, permissions: Int?) {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        // URL encode the path
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files/\(encodedPath)")!)
        urlRequest.httpMethod = "GET"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        // Extract filename from Content-Disposition header or use path
        var filename = URL(fileURLWithPath: path).lastPathComponent
        if let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
           let filenameMatch = contentDisposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression),
           let match = contentDisposition[filenameMatch].split(separator: "\"").dropFirst().first {
            filename = String(match)
        }

        // Extract permissions from X-Permissions header
        var permissions: Int? = nil
        if let permStr = httpResponse.value(forHTTPHeaderField: "X-Permissions") {
            permissions = Int(permStr, radix: 8)
        }

        return (data, filename, permissions)
    }

    private func listFilesViaTCP(host: String, port: Int) async throws -> [String] {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files")!)
        urlRequest.httpMethod = "GET"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileListResponse.self, from: data)
        return fileResponse.files
    }

    private func clearFileQueueViaTCP(host: String, port: Int) async throws {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/files")!)
        urlRequest.httpMethod = "DELETE"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }
    }

    private func fetchURLsViaTCP(host: String, port: Int) async throws -> [String] {
        guard let session = urlSession else {
            throw GhostClientError.notConnected
        }

        var urlRequest = URLRequest(url: URL(string: "http://\(host):\(port)/api/v1/urls")!)
        urlRequest.httpMethod = "GET"
        if let token = authToken {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GhostClientError.invalidResponse(0)
        }

        guard httpResponse.statusCode == 200 else {
            throw GhostClientError.invalidResponse(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        let urlResponse = try decoder.decode(URLListResponse.self, from: data)
        return urlResponse.urls
    }

    // MARK: - Vsock Implementation (Production)

    private func getClipboardViaVsock(vm: VZVirtualMachine) async throws -> ClipboardGetResponse {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/clipboard",
            body: nil
        )

        // Parse HTTP response
        let (statusCode, body) = try HTTPResponseParser.parse(responseData)

        if statusCode == 204 {
            throw GhostClientError.noContent
        }

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            throw GhostClientError.noContent
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(ClipboardGetResponse.self, from: body)
        } catch {
            throw GhostClientError.decodingError
        }
    }

    private func setClipboardViaVsock(vm: VZVirtualMachine, request: ClipboardPostRequest) async throws {
        let encoder = JSONEncoder()
        guard let body = try? encoder.encode(request) else {
            throw GhostClientError.encodingError
        }

        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "POST",
            path: "/api/v1/clipboard",
            body: body,
            contentType: "application/json"
        )

        let (statusCode, _) = try HTTPResponseParser.parse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }
    }

    private nonisolated func sendFileViaVsock(vm: VZVirtualMachine, fileURL: URL, relativePath: String, batchID: String?, isLastInBatch: Bool, permissions: Int?, progressHandler: ((Double) -> Void)?) async throws -> String {
        // Get file size
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = attributes[.size] as? Int64 else {
            throw GhostClientError.encodingError
        }

        // Open file for reading
        guard let fileHandle = FileHandle(forReadingAtPath: fileURL.path) else {
            throw GhostClientError.connectionFailed("Cannot open file")
        }
        defer { try? fileHandle.close() }

        guard let queue = self.vmQueue else {
            throw GhostClientError.connectionFailed("VM queue not available")
        }

        // Connect - ALL VZVirtualMachine access must happen on vmQueue per Apple's requirements
        let port = self.vsockPort
        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: GhostClientError.connectionFailed("No socket device available"))
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        continuation.resume(returning: conn)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        let fd = connection.fileDescriptor

        // Build HTTP headers using HTTPUtilities - use relativePath to preserve folder structure
        var headers: [String: String] = [
            "Content-Type": "application/octet-stream",
            "X-Filename": relativePath
        ]

        if let batchID = batchID {
            headers["X-Batch-ID"] = batchID
        }
        if isLastInBatch {
            headers["X-Batch-Last"] = "true"
        }
        if let permissions = permissions {
            headers["X-Permissions"] = String(permissions, radix: 8)
        }

        // Note: We manually construct this since HTTPUtilities.buildRequest includes Content-Length
        // but we need to stream the body separately in chunks below
        var httpHeaders = "POST /api/v1/files/receive HTTP/1.1\r\n"
        httpHeaders += "Host: localhost\r\n"
        httpHeaders += "Connection: close\r\n"
        for (key, value) in headers {
            httpHeaders += "\(key): \(value)\r\n"
        }
        httpHeaders += "Content-Length: \(fileSize)\r\n"
        httpHeaders += "\r\n"

        let headerData = Data(httpHeaders.utf8)
        let headerWritten = headerData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, headerData.count)
        }
        if headerWritten < 0 {
            connection.close()
            throw GhostClientError.connectionFailed("Failed to write headers")
        }

        // Stream file in chunks
        let chunkSize = 65536
        var bytesSent: Int64 = 0

        progressHandler?(0.0)

        while bytesSent < fileSize {
            let chunk = fileHandle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }

            var offset = 0
            while offset < chunk.count {
                let written = chunk.withUnsafeBytes { ptr in
                    Darwin.write(fd, ptr.baseAddress! + offset, chunk.count - offset)
                }
                if written < 0 {
                    connection.close()
                    throw GhostClientError.connectionFailed("Write failed: errno \(errno)")
                }
                offset += written
            }

            bytesSent += Int64(chunk.count)
            let progress = Double(bytesSent) / Double(fileSize)
            progressHandler?(progress * 0.95) // Reserve 5% for response
        }

        // Signal end of request
        Darwin.shutdown(fd, SHUT_WR)

        // Read response
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            responseData.append(contentsOf: buffer[0..<bytesRead])
        }

        connection.close()

        let (statusCode, responseBody) = try HTTPResponseParser.parse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let responseBody = responseBody else {
            throw GhostClientError.noContent
        }

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileReceiveResponse.self, from: responseBody)

        progressHandler?(1.0)

        return fileResponse.path
    }

    private func fetchFileViaVsock(vm: VZVirtualMachine, path: String) async throws -> (data: Data, filename: String, permissions: Int?) {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path

        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/files/\(encodedPath)",
            body: nil
        )

        let (statusCode, headers, body) = try HTTPResponseParser.parseBinaryWithHeaders(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            throw GhostClientError.noContent
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        var permissions: Int? = nil
        if let permStr = headers["X-Permissions"] {
            permissions = Int(permStr, radix: 8)
        }
        return (body, filename, permissions)
    }

    private func listFilesViaVsock(vm: VZVirtualMachine) async throws -> [String] {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/files",
            body: nil
        )

        let (statusCode, body) = try HTTPResponseParser.parse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            throw GhostClientError.noContent
        }

        let decoder = JSONDecoder()
        let fileResponse = try decoder.decode(FileListResponse.self, from: body)
        return fileResponse.files
    }

    private func clearFileQueueViaVsock(vm: VZVirtualMachine) async throws {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "DELETE",
            path: "/api/v1/files",
            body: nil
        )

        let (statusCode, _) = try HTTPResponseParser.parse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }
    }

    private func fetchURLsViaVsock(vm: VZVirtualMachine) async throws -> [String] {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/urls",
            body: nil
        )

        let (statusCode, body) = try HTTPResponseParser.parse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            return []
        }

        let decoder = JSONDecoder()
        let urlResponse = try decoder.decode(URLListResponse.self, from: body)
        return urlResponse.urls
    }

    private func fetchLogsViaVsock(vm: VZVirtualMachine) async throws -> [String] {
        let responseData = try await sendHTTPRequest(
            vm: vm,
            method: "GET",
            path: "/api/v1/logs",
            body: nil
        )

        let (statusCode, body) = try HTTPResponseParser.parse(responseData)

        guard statusCode == 200 else {
            throw GhostClientError.invalidResponse(statusCode)
        }

        guard let body = body else {
            return []
        }

        let decoder = JSONDecoder()
        let logResponse = try decoder.decode(LogListResponse.self, from: body)
        return logResponse.logs
    }

    private func sendHTTPRequest(
        vm: VZVirtualMachine,
        method: String,
        path: String,
        body: Data?,
        contentType: String? = nil,
        extraHeaders: [String: String]? = nil
    ) async throws -> Data {
        // Ensure we have the VM queue
        guard let queue = self.vmQueue else {
            throw GhostClientError.connectionFailed("VM queue not available")
        }

        // Connect to the guest on the vsock port
        // ALL VZVirtualMachine access must happen on vmQueue per Apple's requirements
        let port = self.vsockPort
        let connection: VZVirtioSocketConnection = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                    continuation.resume(throwing: GhostClientError.connectionFailed("No socket device available"))
                    return
                }
                socketDevice.connect(toPort: port) { result in
                    switch result {
                    case .success(let conn):
                        continuation.resume(returning: conn)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        // Build HTTP request using HTTPUtilities
        var headers: [String: String] = [:]

        if let token = authToken {
            headers["Authorization"] = "Bearer \(token)"
        }

        if let contentType = contentType {
            headers["Content-Type"] = contentType
        }

        if let extraHeaders = extraHeaders {
            headers.merge(extraHeaders) { _, new in new }
        }

        let requestData = HTTPUtilities.buildRequest(
            method: method,
            path: path,
            headers: headers,
            body: body
        )

        // Get file descriptor
        let fd = connection.fileDescriptor

        // Do all blocking I/O on a background queue - NOT on main actor!
        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Send request in chunks to handle large files
                let chunkSize = 65536 // 64KB chunks
                var offset = 0
                while offset < requestData.count {
                    let end = min(offset + chunkSize, requestData.count)
                    let chunk = requestData[offset..<end]
                    let bytesWritten = chunk.withUnsafeBytes { ptr in
                        Darwin.write(fd, ptr.baseAddress!, chunk.count)
                    }
                    if bytesWritten < 0 {
                        connection.close()
                        continuation.resume(throwing: GhostClientError.connectionFailed("Write failed: errno \(errno)"))
                        return
                    }
                    offset += bytesWritten
                }

                // Shutdown write side to signal end of request
                Darwin.shutdown(fd, SHUT_WR)

                // Read response
                let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                var result = Data()
                while true {
                    let chunk = fileHandle.availableData
                    if chunk.isEmpty {
                        break
                    }
                    result.append(chunk)
                }

                continuation.resume(returning: result)
            }
        }

        connection.close()
        return responseData
    }

    private nonisolated func readAllData(from handle: FileHandle) -> Data {
        var result = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            result.append(chunk)
        }
        return result
    }

    private func withTimeout<T>(seconds: Double, operation: @escaping () -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                return operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw GhostClientError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
