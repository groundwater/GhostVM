import AppKit
import Foundation
import Darwin
import GhostHTTP

private let execOutputQueue = DispatchQueue(label: "GhostTools.Router.execOutput", qos: .userInitiated)
private final class ExecOutputCapture: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
}

/// Router that dispatches HTTP requests to handlers.
///
/// Sync end-to-end. Worker threads call `route(request:, body:)` directly —
/// no Task, no continuation, no event loop. Handlers may block (e.g. on
/// `Process.waitUntilExit()` or on socket writes for streaming responses);
/// each connection has its own thread so head-of-line blocking is per-
/// connection only.
///
/// No authentication — vsock is host-only by construction.
final class Router: @unchecked Sendable {
    init() {}

    private func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    /// Handles one HTTP request. The body reader can be drained synchronously
    /// (small request) or in chunks (large upload). The returned response can
    /// be buffered bytes or a streaming producer.
    func route(request: HTTPRequest, body: BodyReader) throws -> HTTPResponse {
        let fullPath = request.path
        let path = fullPath.components(separatedBy: "?").first ?? fullPath

        if path == "/health" {
            return handleHealth(request)
        }

        if path == "/api/v1/clipboard" {
            return handleClipboard(request: request, body: body)
        } else if path == "/api/v1/files" {
            return handleFileList(request)
        } else if path == "/api/v1/files/receive" {
            return handleFileReceive(request: request, body: body)
        } else if path.hasPrefix("/api/v1/files/") {
            return handleFileSend(request: request)
        } else if path == "/api/v1/urls" {
            return handleURLs(request)
        } else if path == "/api/v1/ports" {
            return handlePorts(request)
        } else if path == "/api/v1/logs" {
            return handleLogs(request)
        } else if path == "/api/v1/open" {
            return handleOpen(request: request, body: body)
        } else if path == "/api/v1/apps/frontmost" {
            return handleFrontmostApp(request)
        } else if path == "/api/v1/apps" || path.hasPrefix("/api/v1/apps/") {
            return handleApps(request: request, body: body)
        } else if path == "/api/v1/fs" || path == "/api/v1/fs/mkdir" || path == "/api/v1/fs/delete" || path == "/api/v1/fs/move" {
            return handleFS(request: request, body: body)
        } else if path == "/api/v1/exec" {
            return handleExec(request: request, body: body)
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

    private func handleClipboard(request: HTTPRequest, body: BodyReader) -> HTTPResponse {
        switch request.method {
        case .GET:
            return getClipboard()
        case .POST:
            return setClipboard(request: request, body: body)
        default:
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
    }

    private func getClipboard() -> HTTPResponse {
        log("[Router] GET /clipboard")
        // ClipboardService is @MainActor. Hop to the main thread and assume
        // isolation so the type system is satisfied in a sync world.
        let result: (data: Data, type: String)? = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                ClipboardService.shared.getClipboardData()
            }
        }
        guard let (data, type) = result else {
            log("[Router] No clipboard content")
            return HTTPResponse(status: .noContent)
        }

        log("[Router] Returning clipboard: type=\(type), \(data.count) bytes")
        let headers: [String: String] = [
            "Content-Type": "application/octet-stream",
            "X-Clipboard-Type": type,
        ]
        return HTTPResponse(status: .ok, headers: headers, body: .bytes(data))
    }

    private func setClipboard(request: HTTPRequest, body: BodyReader) -> HTTPResponse {
        let framing: String
        switch body.framing {
        case .knownLength(let n): framing = "cl=\(n)"
        case .chunked:            framing = "chunked"
        case .eof:                framing = "eof"
        }
        log("[Router] POST /clipboard \(framing)")

        let raw: Data
        do {
            raw = try body.readAll(maxSize: 100 * 1024 * 1024)
        } catch {
            log("[Router] POST /clipboard: body read failed: \(error)")
            return HTTPResponse.error(.badRequest, message: "Failed to read body: \(error)")
        }
        guard !raw.isEmpty else {
            log("[Router] POST /clipboard: empty body — rejecting")
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        let (clipboardBody, type): (Data, String) = {
            let explicitType = request.header("X-Clipboard-Type")
            let contentType = request.header("Content-Type")?.lowercased()

            // Backward compat: older clients posted JSON {"content":..., "type":...}.
            if explicitType == nil,
               contentType?.contains("application/json") == true,
               let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let content = object["content"] as? String {
                let parsedType = (object["type"] as? String) ?? "public.utf8-plain-text"
                return (Data(content.utf8), parsedType)
            }
            return (raw, clipboardType(explicitType: explicitType, contentType: contentType))
        }()

        log("[Router] Setting clipboard: type=\(type), \(clipboardBody.count) bytes")
        let didSet: Bool = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                ClipboardService.shared.setClipboardData(clipboardBody, type: type)
            }
        }
        guard didSet else {
            log("[Router] POST /clipboard: setClipboardData returned false (type=\(type), \(clipboardBody.count) bytes)")
            return HTTPResponse.error(.internalServerError, message: "Failed to set clipboard")
        }
        log("[Router] POST /clipboard: ok")
        return HTTPResponse(status: .ok)
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

    // MARK: - Files (list + clear)

    private func handleFileList(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case .GET:
            let files = FileService.shared.listOutgoingFiles()
            log("[Router] GET /files - \(files.count) outgoing file(s)")
            let response = FileListResponse(files: files)
            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)

        case .DELETE:
            FileService.shared.clearOutgoingFiles()
            log("[Router] DELETE /files - queue cleared")
            return HTTPResponse(status: .ok)

        default:
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
    }

    // MARK: - Files: streaming send  (GET /api/v1/files/{path})

    /// Streams the requested file as the response body. Content-Length set
    /// from `stat`; bytes pulled from disk in 64 KiB chunks and written via
    /// the BlockingServer's StreamingWriter. Scales to arbitrarily-large
    /// files — never buffers more than one chunk in memory.
    private func handleFileSend(request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let prefix = "/api/v1/files/"
        let pathOnly = request.path.components(separatedBy: "?").first ?? request.path
        let encoded = pathOnly.hasPrefix(prefix) ? String(pathOnly.dropFirst(prefix.count)) : pathOnly
        let filePath = encoded.removingPercentEncoding ?? encoded
        guard !filePath.isEmpty else {
            return HTTPResponse.error(.badRequest, message: "Path required")
        }

        let info: (url: URL, size: Int, filename: String, permissions: Int?)
        do {
            info = try FileService.shared.statFile(at: filePath)
        } catch FileServiceError.accessDenied {
            return HTTPResponse.error(.forbidden, message: "Access denied")
        } catch {
            return HTTPResponse.error(.notFound, message: "File not found")
        }

        log("[Router] GET /files/\(info.filename) (\(info.size) bytes) — streaming")

        var headers: [String: String] = [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": "attachment; filename=\"\(escapeContentDispositionFilename(info.filename))\"",
        ]
        if let perms = info.permissions {
            headers["X-Permissions"] = String(perms, radix: 8)
        }

        let url = info.url
        return HTTPResponse(
            status: .ok,
            headers: headers,
            body: .stream(contentLength: info.size) { writer in
                let fh = try FileHandle(forReadingFrom: url)
                defer { try? fh.close() }
                let chunkSize = 64 * 1024
                while true {
                    let chunk = try fh.read(upToCount: chunkSize) ?? Data()
                    if chunk.isEmpty { break }
                    try writer.write(chunk)
                }
            }
        )
    }

    // MARK: - Files: streaming receive  (POST /api/v1/files/receive)

    /// Streams the request body straight to disk in 64 KiB chunks. No
    /// in-memory buffering of the payload. Filename + permissions come from
    /// X-Filename / X-Permissions headers. X-Batch-ID / X-Batch-Last drive
    /// Finder reveal once the final file in a batch arrives.
    private func handleFileReceive(request: HTTPRequest, body: BodyReader) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let rawFilename = request.header("X-Filename") ?? "received_file_\(Int(Date().timeIntervalSince1970))"
        let filename = Router.sanitizeRelativePath(rawFilename)
        // Content-Length: nil when the client streamed without advertising
        // length (EOF-delimited). Either is supported below.
        let expected = body.contentLength

        let baseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("GhostVM")
        let destURL = baseURL.appendingPathComponent(filename)

        log("[Router] POST /files/receive: \(filename) (\(expected.map(String.init) ?? "<eof>") bytes)")

        do {
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return HTTPResponse.error(.internalServerError, message: "Failed to create directory: \(error.localizedDescription)")
        }

        FileManager.default.createFile(atPath: destURL.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: destURL.path) else {
            return HTTPResponse.error(.internalServerError, message: "Could not open destination for writing")
        }

        do {
            defer { try? fh.close() }

            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            var written = 0
            try buf.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) in
                while true {
                    if let expected, written >= expected { break }
                    let cap = expected.map { min(rawPtr.count, $0 - written) } ?? rawPtr.count
                    let slice = UnsafeMutableRawBufferPointer(rebasing: rawPtr[..<cap])
                    let n = try body.read(into: slice)
                    if n == 0 { break }
                    try fh.write(contentsOf: Data(bytes: slice.baseAddress!, count: n))
                    written += n
                }
            }

            if let expected, written != expected {
                throw NSError(domain: "Router", code: 2, userInfo: [NSLocalizedDescriptionKey: "Short receive: \(written) of \(expected) bytes"])
            }
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            return HTTPResponse.error(.internalServerError, message: "Failed to save file: \(error.localizedDescription)")
        }

        // Apply permissions if provided.
        if let permStr = request.header("X-Permissions"),
           let mode = Int(permStr, radix: 8) {
            let sanitizedMode = mode & 0o777
            try? FileManager.default.setAttributes([.posixPermissions: sanitizedMode], ofItemAtPath: destURL.path)
        }

        // Reveal-in-Finder bookkeeping for batch transfers.
        let batchID = request.header("X-Batch-ID")
        let isLastInBatch = request.header("X-Batch-Last") == "true"
        if let batchID {
            RouterBatchTracker.shared.add(url: destURL, batchID: batchID)
            if isLastInBatch {
                let allFiles = RouterBatchTracker.shared.finish(batchID: batchID)
                let topLevel = Router.computeTopLevelItems(allFiles, baseURL: baseURL)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting(topLevel)
                }
            }
        } else {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([destURL])
            }
        }

        let response = FileReceiveResponse(path: destURL.path)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        log("[Router] File saved to: \(destURL.path)")
        return HTTPResponse.json(data)
    }

    // MARK: - Filename / batch helpers

    private static func sanitizeRelativePath(_ path: String) -> String {
        let cleaned = path.replacingOccurrences(of: "\0", with: "_")
        let components = cleaned.components(separatedBy: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map {
                $0
                    .replacingOccurrences(of: "..", with: "_")
                    .replacingOccurrences(of: "\\", with: "_")
                    .replacingOccurrences(of: "\"", with: "_")
            }
        return components.isEmpty ? "unnamed" : components.joined(separator: "/")
    }

    private func escapeContentDispositionFilename(_ filename: String) -> String {
        filename
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func computeTopLevelItems(_ urls: [URL], baseURL: URL) -> [URL] {
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

    // MARK: - Ports / Logs / URLs

    private func handlePorts(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        let ports = PortScanner.shared.getListeningPorts()
        let response = PortListResponse(ports: ports)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    private func handleLogs(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        let logs = LogService.shared.popAll()
        let response = LogListResponse(logs: logs)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    private func handleURLs(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case .GET:
            let urls = URLService.shared.popAllURLs()
            if !urls.isEmpty { log("[Router] GET /urls - \(urls.count) URL(s)") }
            let response = URLListResponse(urls: urls)
            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)

        case .DELETE:
            URLService.shared.clearPendingURLs()
            return HTTPResponse(status: .ok)

        default:
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
    }

    // MARK: - Open

    private func handleOpen(request: HTTPRequest, body: BodyReader) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        let raw: Data
        do { raw = try body.readAll() } catch {
            return HTTPResponse.error(.badRequest, message: "Failed to read body: \(error)")
        }
        guard let openRequest = try? JSONDecoder().decode(OpenRequest.self, from: raw) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = [openRequest.path]
        if let app = openRequest.app { args = ["-b", app, openRequest.path] }
        process.arguments = args
        do {
            try process.run()
            return HTTPResponse(status: .ok)
        } catch {
            return HTTPResponse.error(.internalServerError, message: "Failed to open: \(error.localizedDescription)")
        }
    }

    // MARK: - App Management

    private func handleApps(request: HTTPRequest, body: BodyReader) -> HTTPResponse {
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

        let raw: Data
        do { raw = try body.readAll() } catch {
            return HTTPResponse.error(.badRequest, message: "Failed to read body: \(error)")
        }
        guard let payload = try? JSONDecoder().decode(AppActionRequest.self, from: raw) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON - need bundleId")
        }

        if path == "/api/v1/apps/launch" {
            guard let appURL = onMain({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: payload.bundleId) }) else {
                return HTTPResponse.error(.notFound, message: "App not found")
            }
            let config = NSWorkspace.OpenConfiguration()
            let semaphore = DispatchSemaphore(value: 0)
            let result = LaunchResult()
            onMain {
                NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                    result.success = error == nil
                    semaphore.signal()
                }
            }
            semaphore.wait()
            return result.success ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "Failed to launch")
        }

        if path == "/api/v1/apps/activate" {
            let activated = onMain {
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == payload.bundleId }) else {
                    return false
                }
                return app.activate()
            }
            return activated ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "Failed to activate")
        }

        if path == "/api/v1/apps/quit" {
            let terminated = onMain {
                guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == payload.bundleId }) else {
                    return false
                }
                return app.terminate()
            }
            return terminated ? HTTPResponse(status: .ok) : HTTPResponse.error(.notFound, message: "Failed to quit")
        }

        return HTTPResponse.error(.notFound, message: "Not Found")
    }

    private func listApps() -> [AppInfo] {
        onMain {
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
    }

    // MARK: - File System

    private func handleFS(request: HTTPRequest, body: BodyReader) -> HTTPResponse {
        let path = request.path.components(separatedBy: "?").first ?? request.path

        if path == "/api/v1/fs" && request.method == .GET {
            let queryPath = parseQuery(request.path, key: "path") ?? NSHomeDirectory()
            return listDirectory(at: queryPath)
        }
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let raw: Data
        do { raw = try body.readAll() } catch {
            return HTTPResponse.error(.badRequest, message: "Failed to read body: \(error)")
        }

        if path == "/api/v1/fs/mkdir" {
            guard let payload = try? JSONDecoder().decode(FSPathRequest.self, from: raw) else {
                return HTTPResponse.error(.badRequest, message: "Invalid JSON - need path")
            }
            do {
                try FileManager.default.createDirectory(atPath: payload.path, withIntermediateDirectories: true)
                return HTTPResponse(status: .ok)
            } catch {
                return HTTPResponse.error(.internalServerError, message: "mkdir failed: \(error.localizedDescription)")
            }
        }
        if path == "/api/v1/fs/delete" {
            guard let payload = try? JSONDecoder().decode(FSPathRequest.self, from: raw) else {
                return HTTPResponse.error(.badRequest, message: "Invalid JSON - need path")
            }
            do {
                try FileManager.default.removeItem(atPath: payload.path)
                return HTTPResponse(status: .ok)
            } catch {
                return HTTPResponse.error(.internalServerError, message: "delete failed: \(error.localizedDescription)")
            }
        }
        if path == "/api/v1/fs/move" {
            guard let payload = try? JSONDecoder().decode(FSMoveRequest.self, from: raw) else {
                return HTTPResponse.error(.badRequest, message: "Invalid JSON - need from and to")
            }
            do {
                try FileManager.default.moveItem(atPath: payload.from, toPath: payload.to)
                return HTTPResponse(status: .ok)
            } catch {
                return HTTPResponse.error(.internalServerError, message: "move failed: \(error.localizedDescription)")
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
                return HTTPResponse.error(.internalServerError, message: "encode failed")
            }
            return HTTPResponse.json(data)
        } catch {
            return HTTPResponse.error(.internalServerError, message: "list failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Exec

    private struct ExecRequest: Codable {
        let command: String
        let args: [String]?
        let timeout: Int?
    }

    private struct ExecResponse: Codable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func handleExec(request: HTTPRequest, body: BodyReader) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        let raw: Data
        do { raw = try body.readAll() } catch {
            return HTTPResponse.error(.badRequest, message: "Failed to read body: \(error)")
        }
        guard let payload = try? JSONDecoder().decode(ExecRequest.self, from: raw) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

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
            return HTTPResponse.error(.internalServerError, message: "Launch failed: \(error.localizedDescription)")
        }

        // Drain stdout/stderr concurrently before waiting. Otherwise a child
        // that writes more than the pipe buffer can deadlock before exit.
        let output = ExecOutputCapture()
        let timeout = payload.timeout ?? 30
        let deadline = DispatchTime.now() + .seconds(timeout)
        let group = DispatchGroup()
        group.enter()
        execOutputQueue.async {
            process.waitUntilExit()
            group.leave()
        }
        group.enter()
        execOutputQueue.async {
            output.stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        execOutputQueue.async {
            output.stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if group.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return HTTPResponse.error(.requestTimeout, message: "Process timed out after \(timeout)s")
        }
        let result = ExecResponse(
            exitCode: process.terminationStatus,
            stdout: String(data: output.stdout, encoding: .utf8) ?? "",
            stderr: String(data: output.stderr, encoding: .utf8) ?? ""
        )
        guard let data = try? JSONEncoder().encode(result) else {
            return HTTPResponse.error(.internalServerError, message: "encode failed")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Frontmost App

    private func handleFrontmostApp(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
        let bundleId = onMain { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "" }
        let response: [String: Any] = ["bundleId": bundleId]
        guard let data = try? JSONSerialization.data(withJSONObject: response) else {
            return HTTPResponse.error(.internalServerError, message: "encode failed")
        }
        return HTTPResponse.json(data)
    }

    // MARK: - Query Parsing

    private func parseQuery(_ path: String, key: String) -> String? {
        HTTPQueryParser.parseQuery(path, key: key)
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

// MARK: - Internal helpers

/// Tracks paths per batch ID so Finder reveal happens once when the last
/// file in a batch arrives. Multi-threaded since each connection lives on
/// its own worker thread.
final class RouterBatchTracker: @unchecked Sendable {
    static let shared = RouterBatchTracker()
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

/// Tiny mutable box used to capture an out-param across a Sendable callback
/// (`NSWorkspace.openApplication`'s completion handler crosses concurrency
/// domains, so a captured `var` would warn).
final class LaunchResult: @unchecked Sendable {
    var success: Bool = false
}
