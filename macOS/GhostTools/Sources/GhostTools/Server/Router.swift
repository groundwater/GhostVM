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
        } else if path == "/api/v1/exec" {
            return await handleExec(request)
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
        guard let (data, type) = ClipboardService.shared.getClipboardData() else {
            log("[Router] No clipboard content")
            return HTTPResponse(status: .noContent)
        }

        log("[Router] Returning clipboard: type=\(type), \(data.count) bytes")
        let headers: [String: String] = [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(data.count)",
            "X-Clipboard-Type": type,
        ]
        return HTTPResponse(status: .ok, headers: headers, body: data)
    }

    private func setClipboard(_ request: HTTPRequest) -> HTTPResponse {
        log("[Router] POST /clipboard")
        guard let body = request.body, !body.isEmpty else {
            log("[Router] No request body")
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        let (clipboardBody, type): (Data, String) = {
            let explicitType = request.header("X-Clipboard-Type")
            let contentType = request.header("Content-Type")?.lowercased()

            // Backward compatibility: older clients POSTed JSON like
            // {"content":"...","type":"public.utf8-plain-text"}.
            if explicitType == nil,
               contentType?.contains("application/json") == true,
               let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let content = object["content"] as? String {
                let parsedType = (object["type"] as? String) ?? "public.utf8-plain-text"
                return (Data(content.utf8), parsedType)
            }

            return (body, explicitType ?? "public.utf8-plain-text")
        }()

        log("[Router] Setting clipboard: type=\(type), \(clipboardBody.count) bytes")
        guard ClipboardService.shared.setClipboardData(clipboardBody, type: type) else {
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
            let apps = listApps()
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

        if path.hasPrefix("/api/v1/apps/launch") {
            log("[Router] POST /apps/launch: \(payload.bundleId)")
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: payload.bundleId) else {
                return HTTPResponse.error(.notFound, message: "App not found or failed to launch")
            }
            let config = NSWorkspace.OpenConfiguration()
            let semaphore = DispatchSemaphore(value: 0)
            var success = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                success = error == nil
                semaphore.signal()
            }
            semaphore.wait()
            return success ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "App not found or failed to launch")
        }

        if path.hasPrefix("/api/v1/apps/activate") {
            log("[Router] POST /apps/activate: \(payload.bundleId)")
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == payload.bundleId }) else {
                return HTTPResponse.error(.notFound, message: "App not found or not running")
            }
            let ok = app.activate()
            return ok ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "App not found or not running")
        }

        if path.hasPrefix("/api/v1/apps/quit") {
            log("[Router] POST /apps/quit: \(payload.bundleId)")
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == payload.bundleId }) else {
                return HTTPResponse.error(.notFound, message: "App not found or not running")
            }
            let ok = app.terminate()
            return ok ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "App not found or not running")
        }

        return HTTPResponse.error(.notFound, message: "Not Found")
    }

    /// List running GUI apps (those with a Dock icon)
    private func listApps() -> [AppInfo] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                AppInfo(
                    name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    bundleId: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    isActive: app.processIdentifier == frontmost
                )
            }
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

struct AppInfo: Codable {
    let name: String
    let bundleId: String
    let pid: Int32
    let isActive: Bool
}

struct AppListResponse: Codable {
    let apps: [AppInfo]
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
