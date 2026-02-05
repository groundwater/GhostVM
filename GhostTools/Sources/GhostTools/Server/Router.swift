import Foundation

/// Router that dispatches HTTP requests to handlers
/// Note: No authentication required - vsock provides host-only access
final class Router: @unchecked Sendable {
    init() {}

    /// Handles an HTTP request and returns a response
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path

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
        print("[Router] GET /clipboard")
        guard let content = ClipboardService.shared.getClipboardContents() else {
            print("[Router] No clipboard content")
            return HTTPResponse(status: .noContent)
        }

        print("[Router] Returning clipboard: \(content.prefix(50))...")
        let response = ClipboardResponse(content: content)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    private func setClipboard(_ request: HTTPRequest) -> HTTPResponse {
        print("[Router] POST /clipboard")
        guard let body = request.body else {
            print("[Router] No request body")
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        guard let clipboardRequest = try? JSONDecoder().decode(ClipboardRequest.self, from: body) else {
            print("[Router] Invalid JSON in request body")
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        print("[Router] Setting clipboard: \(clipboardRequest.content.prefix(50))...")
        guard ClipboardService.shared.setClipboardContents(clipboardRequest.content) else {
            print("[Router] Failed to set clipboard")
            return HTTPResponse.error(.internalServerError, message: "Failed to set clipboard")
        }

        print("[Router] Clipboard set successfully")
        return HTTPResponse(status: .ok)
    }

    // MARK: - Files

    private func handleFileList(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case .GET:
            // Return outgoing files (queued for host to fetch)
            let files = FileService.shared.listOutgoingFiles()
            print("[Router] GET /files - returning \(files.count) outgoing file(s)")
            let response = FileListResponse(files: files)

            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)

        case .DELETE:
            // Clear the outgoing file queue
            FileService.shared.clearOutgoingFiles()
            print("[Router] DELETE /files - queue cleared")
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

        print("[Router] Receiving file: \(filename) (\(body.count) bytes)")

        do {
            let savedURL = try FileService.shared.receiveFile(data: body, filename: filename)
            let response = FileReceiveResponse(path: savedURL.path)

            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            print("[Router] File saved to: \(savedURL.path)")
            return HTTPResponse.json(data)
        } catch {
            print("[Router] Failed to save file: \(error)")
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
            let (data, filename) = try FileService.shared.readFile(at: decodedPath)
            let headers: [String: String] = [
                "Content-Type": "application/octet-stream",
                "Content-Disposition": "attachment; filename=\"\(filename)\"",
                "Content-Length": "\(data.count)"
            ]
            return HTTPResponse(status: .ok, headers: headers, body: data)
        } catch FileServiceError.accessDenied {
            return HTTPResponse.error(.forbidden, message: "Access denied")
        } catch {
            return HTTPResponse.error(.notFound, message: "File not found")
        }
    }

    // MARK: - URLs

    private func handleURLs(_ request: HTTPRequest) -> HTTPResponse {
        switch request.method {
        case .GET:
            // Get and clear pending URLs atomically
            let urls = URLService.shared.popAllURLs()
            if !urls.isEmpty {
                print("[Router] GET /urls - returning \(urls.count) URL(s)")
            }
            let response = URLListResponse(urls: urls)

            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)

        case .DELETE:
            // Clear the URL queue (without returning them)
            URLService.shared.clearPendingURLs()
            print("[Router] DELETE /urls - queue cleared")
            return HTTPResponse(status: .ok)

        default:
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }
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
