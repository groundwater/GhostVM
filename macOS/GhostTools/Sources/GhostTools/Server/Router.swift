import AppKit
import Foundation

/// Router that dispatches HTTP requests to handlers
/// Note: No authentication required - vsock provides host-only access
final class Router: @unchecked Sendable {
    init() {}

    /// Handles an HTTP request and returns a response
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let fullPath = request.path
        let path = fullPath.components(separatedBy: "?").first ?? fullPath

        // Health check
        if path == "/health" {
            return handleHealth(request)
        }

        // Note: Authentication disabled - vsock provides host-only access
        // The host VM is the only entity that can connect via vsock

        // Route to appropriate handler
        if path == "/api/v1/clipboard" {
            return await handleClipboard(request)
        } else if path == "/api/v1/files" {
            return handleFileList(request)
        } else if path == "/api/v1/files/receive" {
            return handleFileReceive(request)
        } else if path.hasPrefix("/api/v1/files/") {
            return handleFileGet(request)
        } else if path == "/api/v1/urls" {
            return handleURLs(request)
        } else if path == "/api/v1/ports" {
            return handlePorts(request)
        } else if path == "/api/v1/port-forwards" {
            return handlePortForwards(request)
        } else if path == "/api/v1/logs" {
            return handleLogs(request)
        } else if path == "/api/v1/open" {
            return handleOpen(request)
        } else if path == "/api/v1/apps/frontmost" {
            return handleFrontmostApp(request)
        } else if path == "/api/v1/apps" || path.hasPrefix("/api/v1/apps/") {
            return handleApps(request)
        } else if path == "/api/v1/fs" || path == "/api/v1/fs/mkdir" || path == "/api/v1/fs/delete" || path == "/api/v1/fs/move" {
            return handleFS(request)
        } else if path == "/api/v1/accessibility" {
            return handleAccessibility(request)
        } else if path == "/api/v1/accessibility/action" {
            return handleAccessibilityAction(request)
        } else if path == "/api/v1/accessibility/menu" {
            return handleAccessibilityMenu(request)
        } else if path == "/api/v1/accessibility/type" {
            return handleAccessibilityType(request)
        } else if path == "/api/v1/accessibility/focused" {
            return handleAccessibilityFocused(request)
        } else if path == "/api/v1/pointer" {
            return await handlePointer(request)
        } else if path == "/api/v1/input" {
            return await handleKeyboardInput(request)
        } else if path == "/api/v1/exec" {
            return await handleExec(request)
        } else if path == "/vm/screenshot" {
            return handleScreenshot(request)
        } else if path == "/vm/screenshot/annotated" {
            return await handleAnnotatedScreenshot(request)
        } else if path == "/api/v1/batch" {
            return await handleBatch(request)
        } else if path == "/api/v1/permissions" {
            return handlePermissions(request)
        } else if path == "/api/v1/elements" {
            return handleElements(request)
        } else if path == "/api/v1/overlay/wait-show" {
            return handleOverlayWaitShow(request)
        } else if path == "/api/v1/overlay/wait-hide" {
            return handleOverlayWaitHide(request)
        }

        return HTTPResponse.error(.notFound, message: "Not Found")
    }

    // MARK: - Health

    private func handleHealth(_ request: HTTPRequest) -> HTTPResponse {
        let response = HealthResponse(status: "ok", version: "1.0.0")
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Clipboard

    private func handleClipboard(_ request: HTTPRequest) async -> HTTPResponse {
        switch request.method {
        case .GET:
            return getClipboard()
        case .POST:
            return setClipboard(request)
        default:
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
    }

    private func getClipboard() -> HTTPResponse {
        log("[Router] GET /clipboard")
        guard let content = ClipboardService.shared.getClipboardContents() else {
            log("[Router] No clipboard content")
            return HTTPResponse(status: .noContent)
        }

        log("[Router] Returning clipboard: \(content.prefix(50))...")
        let response = ClipboardResponse(content: content)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    private func setClipboard(_ request: HTTPRequest) -> HTTPResponse {
        log("[Router] POST /clipboard")
        guard let body = request.body else {
            log("[Router] No request body")
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        guard let clipboardRequest = try? JSONDecoder().decode(ClipboardRequest.self, from: body) else {
            log("[Router] Invalid JSON in request body")
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        log("[Router] Setting clipboard: \(clipboardRequest.content.prefix(50))...")
        guard ClipboardService.shared.setClipboardContents(clipboardRequest.content) else {
            log("[Router] Failed to set clipboard")
            return HTTPResponse.error(.internalServerError, message: "Failed to set clipboard")
        }

        log("[Router] Clipboard set successfully")
        return HTTPResponse(status: .ok)
    }

    // MARK: - Files

    private func handleFileList(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case .GET:
            // Return outgoing files (queued for host to fetch)
            let files = FileService.shared.listOutgoingFiles()
            log("[Router] GET /files - returning \(files.count) outgoing file(s)")
            let response = FileListResponse(files: files)

            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)

        case .DELETE:
            // Clear the outgoing file queue
            FileService.shared.clearOutgoingFiles()
            log("[Router] DELETE /files - queue cleared")
            return HTTPResponse(status: .ok)

        default:
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
    }

    private func handleFileReceive(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard let body = request.body, !body.isEmpty else {
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        // Get filename from header or generate one
        let filename = request.header("X-Filename") ?? "received_file_\(Int(Date().timeIntervalSince1970))"

        log("[Router] Receiving file: \(filename) (\(body.count) bytes)")

        do {
            let savedURL = try FileService.shared.receiveFile(data: body, filename: filename)

            // Apply permissions if provided
            if let permStr = request.header("X-Permissions"),
               let mode = Int(permStr, radix: 8) {
                try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: savedURL.path)
            }

            let response = FileReceiveResponse(path: savedURL.path)

            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            log("[Router] File saved to: \(savedURL.path)")
            return HTTPResponse.json(data)
        } catch {
            log("[Router] Failed to save file: \(error)")
            return HTTPResponse.error(.internalServerError, message: "Failed to save file: \(error.localizedDescription)")
        }
    }

    private func handleFileGet(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        // Extract path after /api/v1/files/
        let prefix = "/api/v1/files/"
        guard request.path.hasPrefix(prefix) else {
            return HTTPResponse.error(.badRequest, message: "Invalid path")
        }

        let filePath = String(request.path.dropFirst(prefix.count))
        guard !filePath.isEmpty else {
            return HTTPResponse.error(.badRequest, message: "Path required")
        }

        // URL decode the path
        let decodedPath = filePath.removingPercentEncoding ?? filePath

        do {
            let (data, filename, permissions) = try FileService.shared.readFile(at: decodedPath)
            var headers: [String: String] = [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=\"\(filename)\"",
                "Content-Length": "\(data.count)"
            ]
            if let permissions = permissions {
                headers["X-Permissions"] = String(permissions, radix: 8)
            }
            return HTTPResponse(status: .ok, headers: headers, body: data)
        } catch FileServiceError.accessDenied {
            return HTTPResponse.error(.forbidden, message: "Access denied")
        } catch {
            return HTTPResponse.error(.notFound, message: "File not found")
        }
    }

    // MARK: - Ports

    private func handlePorts(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let ports = PortScanner.shared.getListeningPorts()
        log("[Router] GET /ports - returning \(ports.count) listening port(s)")

        let response = PortListResponse(ports: ports)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Port Forwards

    private func handlePortForwards(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        // Pop and clear the requested ports
        let ports = PortForwardRequestService.shared.popRequests()
        if !ports.isEmpty {
            log("[Router] GET /port-forwards - returning \(ports.count) requested port(s)")
        }

        let response = PortForwardResponse(ports: ports)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Logs

    private func handleLogs(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        // Pop and return buffered logs
        let logs = LogService.shared.popAll()

        let response = LogListResponse(logs: logs)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - URLs

    private func handleURLs(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case .GET:
            // Get and clear pending URLs atomically
            let urls = URLService.shared.popAllURLs()
            if !urls.isEmpty {
                log("[Router] GET /urls - returning \(urls.count) URL(s)")
            }
            let response = URLListResponse(urls: urls)

            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)

        case .DELETE:
            // Clear the URL queue (without returning them)
            URLService.shared.clearPendingURLs()
            log("[Router] DELETE /urls - queue cleared")
            return HTTPResponse(status: .ok)

        default:
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
    }

    // MARK: - Open

    private func handleOpen(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard let body = request.body else {
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        guard let openRequest = try? JSONDecoder().decode(OpenRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        log("[Router] POST /open: \(openRequest.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = [openRequest.path]
        if let app = openRequest.app {
            args = ["-b", app, openRequest.path]
        }
        process.arguments = args

        do {
            try process.run()
            return HTTPResponse(status: .ok)
        } catch {
            log("[Router] Failed to open: \(error)")
            return HTTPResponse.error(.internalServerError, message: "Failed to open: \(error.localizedDescription)")
        }
    }

    // MARK: - App Management

    private func handleApps(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path.components(separatedBy: "?").first ?? request.path

        if path == "/api/v1/apps" && request.method == .GET {
            let apps = AppManagementService.shared.listApps()
            let response = AppListResponse(apps: apps)
            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)
        }

        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard let body = request.body,
              let payload = try? JSONDecoder().decode(AppActionRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON - need bundleId")
        }

        // Launch and quit default to navigation mode (can be overridden with ?expect=none)
        let expect = parseExpectChange(request.path)
        let defaultExpect: AccessibilityService.ExpectChange = (path.contains("/quit")) ? .navigation : .navigation
        let finalExpect = (expect == .none && request.path.contains("expect=")) ? .none : defaultExpect

        if path.hasPrefix("/api/v1/apps/launch") {
            log("[Router] POST /apps/launch: \(payload.bundleId) expect=\(finalExpect)")
            let before = AccessibilityService.shared.createSnapshot()
            let ok = AppManagementService.shared.launchApp(bundleId: payload.bundleId)

            if ok {
                switch finalExpect {
                case .navigation:
                    AccessibilityService.shared.waitForLargeChange(before: before)
                    AccessibilityService.shared.waitForStabilization()
                case .update:
                    AccessibilityService.shared.waitForAnyChange(before: before)
                case .none:
                    break
                }
            }

            return ok ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "App not found or failed to launch")
        }

        if path.hasPrefix("/api/v1/apps/activate") {
            log("[Router] POST /apps/activate: \(payload.bundleId) expect=\(finalExpect)")
            let before = AccessibilityService.shared.createSnapshot()
            let ok = AppManagementService.shared.activateApp(bundleId: payload.bundleId)

            if ok && finalExpect != .none {
                switch finalExpect {
                case .navigation:
                    AccessibilityService.shared.waitForLargeChange(before: before, timeout: 3.0)
                    AccessibilityService.shared.waitForStabilization(timeout: 3.0)
                case .update:
                    AccessibilityService.shared.waitForAnyChange(before: before)
                case .none:
                    break
                }
            }

            return ok ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "App not found or not running")
        }

        if path.hasPrefix("/api/v1/apps/quit") {
            log("[Router] POST /apps/quit: \(payload.bundleId) expect=\(finalExpect)")
            let before = AccessibilityService.shared.createSnapshot()
            let ok = AppManagementService.shared.quitApp(bundleId: payload.bundleId)

            if ok && finalExpect != .none {
                // Quit: wait for app to disappear
                Thread.sleep(forTimeInterval: 1.0)
            }

            return ok ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "App not found or not running")
        }

        return HTTPResponse.error(.notFound, message: "Not Found")
    }

    // MARK: - File System

    private func handleFS(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path.components(separatedBy: "?").first ?? request.path

        if path == "/api/v1/fs" && request.method == .GET {
            // List directory contents
            let queryPath = parseQuery(request.path, key: "path") ?? NSHomeDirectory()
            return listDirectory(at: queryPath)
        }

        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        if path == "/api/v1/fs/mkdir" {
            guard let body = request.body,
                  let payload = try? JSONDecoder().decode(FSPathRequest.self, from: body) else {
                return HTTPResponse.error(.badRequest, message: "Invalid JSON - need path")
            }
            log("[Router] POST /fs/mkdir: \(payload.path)")
            do {
                try FileManager.default.createDirectory(atPath: payload.path, withIntermediateDirectories: true)
                return HTTPResponse(status: .ok)
            } catch {
                return HTTPResponse.error(.internalServerError, message: "Failed to create directory: \(error.localizedDescription)")
            }
        }

        if path == "/api/v1/fs/delete" {
            guard let body = request.body,
                  let payload = try? JSONDecoder().decode(FSPathRequest.self, from: body) else {
                return HTTPResponse.error(.badRequest, message: "Invalid JSON - need path")
            }
            log("[Router] POST /fs/delete: \(payload.path)")
            do {
                try FileManager.default.removeItem(atPath: payload.path)
                return HTTPResponse(status: .ok)
            } catch {
                return HTTPResponse.error(.internalServerError, message: "Failed to delete: \(error.localizedDescription)")
            }
        }

        if path == "/api/v1/fs/move" {
            guard let body = request.body,
                  let payload = try? JSONDecoder().decode(FSMoveRequest.self, from: body) else {
                return HTTPResponse.error(.badRequest, message: "Invalid JSON - need from and to")
            }
            log("[Router] POST /fs/move: \(payload.from) -> \(payload.to)")
            do {
                try FileManager.default.moveItem(atPath: payload.from, toPath: payload.to)
                return HTTPResponse(status: .ok)
            } catch {
                return HTTPResponse.error(.internalServerError, message: "Failed to move: \(error.localizedDescription)")
            }
        }

        return HTTPResponse.error(.notFound, message: "Not Found")
    }

    private func listDirectory(at path: String) -> HTTPResponse {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            return HTTPResponse.error(.notFound, message: "Path not found")
        }

        do {
            let contents = try fm.contentsOfDirectory(atPath: path)
            var entries: [FSEntry] = []
            for name in contents {
                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                let attrs = try? fm.attributesOfItem(atPath: fullPath)
                let size = attrs?[.size] as? Int64 ?? 0
                let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                entries.append(FSEntry(name: name, isDir: isDir.boolValue, size: size, modified: modified))
            }
            let response = FSListResponse(path: path, entries: entries)
            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)
        } catch {
            return HTTPResponse.error(.internalServerError, message: "Failed to list directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Accessibility

    /// Parse target query param into AXTarget. Defaults to .front for backward compat.
    private func parseAXTarget(_ path: String) -> AccessibilityService.AXTarget {
        guard let value = parseQuery(path, key: "target") else { return .front }
        return AccessibilityService.AXTarget(queryValue: value) ?? .front
    }

    private func parseExpectChange(_ path: String) -> AccessibilityService.ExpectChange {
        guard let value = parseQuery(path, key: "expect") else { return .none }
        switch value.lowercased() {
        case "navigation", "nav": return .navigation
        case "update", "upd": return .update
        case "none": return .none
        default: return .none
        }
    }

    private func handleAccessibility(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let depthStr = parseQuery(request.path, key: "depth")
        let depth = depthStr.flatMap { Int($0) } ?? 5
        let target = parseAXTarget(request.path)

        do {
            let trees = try AccessibilityService.shared.getTree(maxDepth: depth, target: target)
            if target.isMulti {
                guard let data = try? JSONEncoder().encode(trees) else {
                    return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
                }
                return HTTPResponse.json(data)
            } else {
                guard let first = trees.first else {
                    return HTTPResponse.error(.internalServerError, message: "No tree returned")
                }
                guard let data = try? JSONEncoder().encode(first) else {
                    return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
                }
                return HTTPResponse.json(data)
            }
        } catch AccessibilityService.AXServiceError.permissionDenied {
            return HTTPResponse.error(.forbidden, message: "Accessibility permission required. Grant access in System Preferences > Privacy & Security > Accessibility.")
        } catch {
            return axErrorResponse(error)
        }
    }

    // MARK: - Accessibility Actions

    private func handleAccessibilityAction(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        guard let body = request.body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        let label = payload["label"] as? String
        let role = payload["role"] as? String
        let action = payload["action"] as? String ?? "AXPress"
        let target = parseAXTarget(request.path)

        do {
            try AccessibilityService.shared.performAction(label: label, role: role, action: action, target: target)
            return HTTPResponse.json(try! JSONEncoder().encode(AccessibilityService.ActionResult(ok: true, message: nil)))
        } catch {
            return axErrorResponse(error)
        }
    }

    private func handleAccessibilityMenu(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        guard let body = request.body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let path = payload["path"] as? [String] else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON — need {\"path\": [\"Menu\", \"Item\"]}")
        }

        let target = parseAXTarget(request.path)

        do {
            try AccessibilityService.shared.triggerMenuItem(path: path, target: target)
            return HTTPResponse.json(try! JSONEncoder().encode(AccessibilityService.ActionResult(ok: true, message: nil)))
        } catch {
            return axErrorResponse(error)
        }
    }

    private func handleAccessibilityType(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        guard let body = request.body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = payload["value"] as? String else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON — need {\"value\": \"text\"}")
        }

        let label = payload["label"] as? String
        let role = payload["role"] as? String
        let target = parseAXTarget(request.path)

        do {
            try AccessibilityService.shared.setValue(value, label: label, role: role, target: target)
            return HTTPResponse.json(try! JSONEncoder().encode(AccessibilityService.ActionResult(ok: true, message: nil)))
        } catch {
            return axErrorResponse(error)
        }
    }

    private func handleAccessibilityFocused(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        let target = parseAXTarget(request.path)
        do {
            let info = try AccessibilityService.shared.getFocusedElement(target: target)
            guard let data = try? JSONSerialization.data(withJSONObject: info) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)
        } catch {
            return axErrorResponse(error)
        }
    }

    private func axErrorResponse(_ error: Error) -> HTTPResponse {
        if case AccessibilityService.AXServiceError.permissionDenied = error {
            return HTTPResponse.error(.forbidden, message: "Accessibility permission required")
        }
        if case AccessibilityService.AXServiceError.elementNotFound(let label) = error {
            return HTTPResponse.error(.notFound, message: "Element not found: \(label)")
        }
        if case AccessibilityService.AXServiceError.menuNotFound(let path) = error {
            return HTTPResponse.error(.notFound, message: "Menu not found: \(path)")
        }
        if case AccessibilityService.AXServiceError.appNotFound(let id) = error {
            return HTTPResponse.error(.notFound, message: "Application not found: \(id)")
        }
        if case AccessibilityService.AXServiceError.actionFailed(let detail) = error {
            return HTTPResponse.error(.internalServerError, message: "Action failed: \(detail)")
        }
        if case AccessibilityService.AXServiceError.multiTargetNotAllowed = error {
            return HTTPResponse.error(.badRequest, message: "Multi-target (--all/--visible) not allowed for actions")
        }
        return HTTPResponse.error(.internalServerError, message: "\(error)")
    }

    // MARK: - Pointer

    private func handlePointer(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard let body = request.body,
              let payload = try? JSONDecoder().decode(PointerService.PointerRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        let expect = parseExpectChange(request.path)
        log("[Router] POST /pointer: action=\(payload.action) expect=\(expect)")

        // Take snapshot before action if waiting is needed
        let before = (expect != .none) ? AccessibilityService.shared.createSnapshot() : nil

        do {
            let diag = try PointerService.shared.sendEvent(
                action: payload.action,
                x: payload.x,
                y: payload.y,
                button: payload.button,
                label: payload.label,
                endX: payload.endX,
                endY: payload.endY,
                deltaX: payload.deltaX,
                deltaY: payload.deltaY
            )

            // Wait based on expect parameter
            if let before = before {
                switch expect {
                case .navigation:
                    AccessibilityService.shared.waitForLargeChange(before: before)
                    AccessibilityService.shared.waitForStabilization()
                case .update:
                    AccessibilityService.shared.waitForAnyChange(before: before)
                case .none:
                    break
                }
            }

            guard let data = try? JSONSerialization.data(withJSONObject: diag.dict) else {
                return HTTPResponse(status: .ok)
            }
            return HTTPResponse.json(data)
        } catch PointerService.PointerError.labelNotFound(let label) {
            return HTTPResponse.error(.notFound, message: "Element with label '\(label)' not found")
        } catch PointerService.PointerError.permissionDenied {
            return HTTPResponse.error(.forbidden, message: "Accessibility permission required. Grant to GhostTools in System Settings > Privacy & Security > Accessibility.")
        } catch {
            return HTTPResponse.error(.internalServerError, message: "Pointer event failed: \(error)")
        }
    }

    // MARK: - Keyboard Input

    private func handleKeyboardInput(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard let body = request.body,
              let payload = try? JSONDecoder().decode(KeyboardService.KeyboardRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        let expect = parseExpectChange(request.path)
        log("[Router] POST /input expect=\(expect)")

        // Take snapshot before action if waiting is needed
        let before = (expect != .none) ? AccessibilityService.shared.createSnapshot() : nil

        do {
            try KeyboardService.shared.sendInput(
                text: payload.text,
                keys: payload.keys,
                modifiers: payload.modifiers,
                rate: payload.rate
            )

            // Wait based on expect parameter
            if let before = before {
                switch expect {
                case .navigation:
                    AccessibilityService.shared.waitForLargeChange(before: before)
                    AccessibilityService.shared.waitForStabilization()
                case .update:
                    AccessibilityService.shared.waitForAnyChange(before: before)
                case .none:
                    break
                }
            }

            return HTTPResponse(status: .ok)
        } catch KeyboardService.KeyboardError.permissionDenied {
            return HTTPResponse.error(.forbidden, message: "Accessibility permission required for keyboard input")
        } catch {
            return HTTPResponse.error(.internalServerError, message: "Keyboard input failed: \(error)")
        }
    }

    // MARK: - Shell Exec

    private struct ExecRequest: Codable {
        let command: String
        let args: [String]?
        let timeout: Int?  // seconds, default 30
    }

    private struct ExecResponse: Codable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func handleExec(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard let body = request.body,
              let payload = try? JSONDecoder().decode(ExecRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON — need {\"command\": \"...\", \"args\": [...]}")
        }

        log("[Router] POST /exec: \(payload.command)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: payload.command)
        process.arguments = payload.args ?? []

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return HTTPResponse.error(.internalServerError, message: "Failed to launch: \(error.localizedDescription)")
        }

        let timeout = payload.timeout ?? 30
        let deadline = DispatchTime.now() + .seconds(timeout)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return HTTPResponse.error(.requestTimeout, message: "Process timed out after \(timeout)s")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let result = ExecResponse(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )

        guard let responseData = try? JSONEncoder().encode(result) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode result")
        }
        return HTTPResponse.json(responseData)
    }

    // MARK: - Permissions

    private func handlePermissions(_ request: HTTPRequest) -> HTTPResponse {
        let screenCaptureGranted = CGPreflightScreenCaptureAccess()

        if request.method == .POST {
            // POST: prompt for permissions (shows macOS dialogs)
            let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            let axTrusted = AXIsProcessTrustedWithOptions(axOptions)
            if !screenCaptureGranted {
                _ = CGRequestScreenCaptureAccess()
            }

            let result: [String: Any] = [
                "accessibility": axTrusted,
                "screenRecording": CGPreflightScreenCaptureAccess(),
                "prompted": true
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: result) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode")
            }
            return HTTPResponse.json(data)
        }

        // GET: check current permission status without prompting
        let axTrusted = AXIsProcessTrusted()
        let result: [String: Any] = [
            "accessibility": axTrusted,
            "screenRecording": screenCaptureGranted
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Screenshot

    private func handleScreenshot(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let format = (parseQuery(request.path, key: "format") ?? "png").lowercased()
        let scale = Double(parseQuery(request.path, key: "scale") ?? "1.0") ?? 1.0

        do {
            if format == "jpeg" || format == "jpg" {
                let quality = Double(parseQuery(request.path, key: "quality") ?? "0.8") ?? 0.8
                let data = try ScreenshotService.shared.captureJPEG(scale: scale, quality: quality)
                return HTTPResponse(
                    status: .ok,
                    headers: ["Content-Type": "image/jpeg", "Content-Length": "\(data.count)"],
                    body: data
                )
            }

            let data = try ScreenshotService.shared.capturePNG()
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "image/png", "Content-Length": "\(data.count)"],
                body: data
            )
        } catch ScreenshotService.CaptureError.screenRecordingDenied {
            return HTTPResponse.error(.forbidden, message: "Screen Recording permission required. Grant to GhostTools in System Settings > Privacy & Security > Screen Recording.")
        } catch {
            return HTTPResponse.error(.internalServerError, message: "Capture failed: \(error.localizedDescription)")
        }
    }

    private func handleAnnotatedScreenshot(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard CGPreflightScreenCaptureAccess() else {
            return HTTPResponse.error(.forbidden, message: "Screen Recording permission required. Grant to GhostTools in System Settings > Privacy & Security > Screen Recording.")
        }

        let scale = Double(parseQuery(request.path, key: "scale") ?? "0.5") ?? 0.5
        let annotated = await BatchAutomationService.shared.captureAnnotatedScreenshot(scale: scale)

        var payload: [String: Any] = [
            "elements": annotated.elements,
            "display": annotated.display
        ]
        if let image = annotated.imageBase64 {
            payload["screenshot"] = image
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Batch

    private func handleBatch(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        guard let body = request.body else {
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }
        guard let batchRequest = try? JSONDecoder().decode(GuestBatchRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        let result = await BatchAutomationService.shared.execute(request: batchRequest)
        guard let data = try? JSONEncoder().encode(result) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Elements (A11y overlay + JSON, no screenshot)

    private func handleElements(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let result = AccessibilityService.shared.getInteractiveElements()
        let elements = result.elements
        let scrollState = result.scrollState

        // Track element changes for recency coloring
        let changeAges = ElementChangeTracker.shared.track(elements)

        // Show live overlay of discovered elements in the guest framebuffer
        if !elements.isEmpty {
            A11yElementOverlay.shared.showElements(elements, changeAges: changeAges)
        }

        // Build elements array for JSON
        let elementsJSON: [[String: Any]] = elements.map { elem in
            var dict: [String: Any] = [
                "id": elem.id,
                "role": elem.role,
                "frame": [
                    "x": Int(elem.frame.x),
                    "y": Int(elem.frame.y),
                    "w": Int(elem.frame.width),
                    "h": Int(elem.frame.height)
                ],
                "changeAge": changeAges[elem.id] ?? 0
            ]
            if let label = elem.label { dict["label"] = label }
            if let title = elem.title { dict["title"] = title }
            if let value = elem.value { dict["value"] = value }
            return dict
        }

        let displayJSON: [String: Any] = [
            "scroll": [
                "up": scrollState.canScrollUp,
                "down": scrollState.canScrollDown,
                "left": scrollState.canScrollLeft,
                "right": scrollState.canScrollRight
            ]
        ]

        let response: [String: Any] = [
            "elements": elementsJSON,
            "display": displayJSON
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Overlay Controls

    private func handleOverlayWaitShow(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        WaitIndicatorOverlay.shared.show()
        return HTTPResponse(status: .ok)
    }

    private func handleOverlayWaitHide(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        WaitIndicatorOverlay.shared.hide()
        return HTTPResponse(status: .ok)
    }

    // MARK: - Frontmost App

    private func handleFrontmostApp(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let response: [String: Any] = ["bundleId": bundleId]
        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Query Parsing

    private func parseQuery(_ path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        for pair in query.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 && parts[0] == key {
                return parts[1].removingPercentEncoding ?? parts[1]
            }
        }
        return nil
    }

    private func parseBoolQuery(_ path: String, key: String) -> Bool? {
        guard let value = parseQuery(path, key: key)?.lowercased() else { return nil }
        if value == "1" || value == "true" || value == "yes" { return true }
        if value == "0" || value == "false" || value == "no" { return false }
        return nil
    }
}

// MARK: - Request/Response Types

struct HealthResponse: Codable {
    let status: String
    let version: String
}

struct ClipboardRequest: Codable {
    let content: String
}

struct ClipboardResponse: Codable {
    let content: String
}


struct FileReceiveResponse: Codable {
    let path: String
}

struct FileListResponse: Codable {
    let files: [String]
}

struct URLListResponse: Codable {
    let urls: [String]
}

struct LogListResponse: Codable {
    let logs: [String]
}

struct OpenRequest: Codable {
    let path: String
    let app: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        app = try container.decodeIfPresent(String.self, forKey: .app)
    }
}

// MARK: - App Management Types

struct AppListResponse: Codable {
    let apps: [AppManagementService.AppInfo]
}

struct AppActionRequest: Codable {
    let bundleId: String
}

// MARK: - File System Types

struct FSEntry: Codable {
    let name: String
    let isDir: Bool
    let size: Int64
    let modified: Double
}

struct FSListResponse: Codable {
    let path: String
    let entries: [FSEntry]
}

struct FSPathRequest: Codable {
    let path: String
}

struct FSMoveRequest: Codable {
    let from: String
    let to: String
}
