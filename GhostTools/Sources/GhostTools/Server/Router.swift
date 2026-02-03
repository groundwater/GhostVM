import Foundation

/// Router that dispatches HTTP requests to handlers
final class Router: @unchecked Sendable {
    private let tokenAuth: TokenAuth

    init(tokenAuth: TokenAuth = TokenAuth.shared) {
        self.tokenAuth = tokenAuth
    }

    /// Handles an HTTP request and returns a response
    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let path = request.path

        // Health check - no auth required
        if path == "/health" {
            return handleHealth(request)
        }

        // All other routes require authentication
        guard await tokenAuth.validateToken(request.header("Authorization")) else {
            return HTTPResponse.error(.unauthorized, message: "Unauthorized")
        }

        // Route to appropriate handler
        if path == "/api/v1/clipboard" {
            return await handleClipboard(request)
        } else if path == "/api/v1/files" {
            return handleFileList(request)
        } else if path == "/api/v1/files/receive" {
            return handleFileReceive(request)
        } else if path.hasPrefix("/api/v1/files/") {
            return handleFileGet(request)
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
        guard let content = ClipboardService.shared.getClipboardContents() else {
            return HTTPResponse(status: .noContent)
        }

        let response = ClipboardResponse(content: content)
        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    private func setClipboard(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body else {
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        guard let clipboardRequest = try? JSONDecoder().decode(ClipboardRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        guard ClipboardService.shared.setClipboardContents(clipboardRequest.content) else {
            return HTTPResponse.error(.forbidden, message: "Clipboard sync disabled for this direction")
        }

        return HTTPResponse(status: .ok)
    }

    // MARK: - Files

    private func handleFileList(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .GET else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        let files = FileService.shared.listReceivedFiles()
        let response = FileListResponse(files: files)

        guard let data = try? JSONEncoder().encode(response) else {
            return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
        }
        return HTTPResponse.json(data)
    }

    private func handleFileReceive(_ request: HTTPRequest) -> HTTPResponse {
        guard request.method == .POST else {
            return HTTPResponse.error(.methodNotAllowed, message: "Method not allowed")
        }

        guard let body = request.body else {
            return HTTPResponse.error(.badRequest, message: "Request body required")
        }

        guard let fileRequest = try? JSONDecoder().decode(FileReceiveRequest.self, from: body) else {
            return HTTPResponse.error(.badRequest, message: "Invalid JSON")
        }

        guard let content = Data(base64Encoded: fileRequest.content) else {
            return HTTPResponse.error(.badRequest, message: "Invalid base64 content")
        }

        do {
            let savedURL = try FileService.shared.receiveFile(data: content, filename: fileRequest.filename)
            let response = FileReceiveResponse(path: savedURL.path)

            guard let data = try? JSONEncoder().encode(response) else {
                return HTTPResponse.error(.internalServerError, message: "Failed to encode response")
            }
            return HTTPResponse.json(data)
        } catch {
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

struct FileReceiveRequest: Codable {
    let filename: String
    let content: String // base64 encoded
}

struct FileReceiveResponse: Codable {
    let path: String
}

struct FileListResponse: Codable {
    let files: [String]
}
