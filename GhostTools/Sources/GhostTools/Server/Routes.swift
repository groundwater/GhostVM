import Foundation
import Hummingbird

/// Configures all API routes for the GhostTools server
func configureRoutes(_ router: Router<BasicRequestContext>) {
    // Health check - no auth required
    router.get("/health") { _, _ in
        HealthResponse(status: "ok", version: "1.0.0")
    }

    // API v1 routes - auth required (handled by middleware)
    let api = router.group("/api/v1")

    // Clipboard endpoints
    api.get("/clipboard") { _, _ -> Response in
        guard let content = ClipboardService.shared.getClipboardContents() else {
            return Response(status: .noContent)
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(ClipboardResponse(content: content))
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: .init(data: data))
        )
    }

    api.post("/clipboard") { request, context -> Response in
        let body = try await request.decode(as: ClipboardRequest.self, context: context)

        guard ClipboardService.shared.setClipboardContents(body.content) else {
            return Response(
                status: .forbidden,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: #"{"error":"Clipboard sync disabled for this direction"}"#))
            )
        }

        return Response(status: .ok)
    }

    // File endpoints
    api.post("/files/receive") { request, context -> Response in
        // For now, expect JSON with base64 encoded content
        let body = try await request.decode(as: FileReceiveRequest.self, context: context)

        guard let data = Data(base64Encoded: body.content) else {
            return Response(
                status: .badRequest,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: #"{"error":"Invalid base64 content"}"#))
            )
        }

        do {
            let savedURL = try FileService.shared.receiveFile(data: data, filename: body.filename)
            let encoder = JSONEncoder()
            let responseData = try encoder.encode(FileReceiveResponse(path: savedURL.path))
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(data: responseData))
            )
        } catch {
            return Response(
                status: .internalServerError,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: #"{"error":"Failed to save file: \#(error.localizedDescription)"}"#))
            )
        }
    }

    api.get("/files/{path+}") { _, context -> Response in
        // Get the path from route parameters
        guard let path = context.parameters.get("path") else {
            return Response(
                status: .badRequest,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: #"{"error":"Path required"}"#))
            )
        }

        do {
            let (data, filename) = try FileService.shared.readFile(at: path)
            return Response(
                status: .ok,
                headers: [
                    .contentType: "application/octet-stream",
                    .contentDisposition: "attachment; filename=\"\(filename)\""
                ],
                body: .init(byteBuffer: .init(data: data))
            )
        } catch FileServiceError.accessDenied {
            return Response(
                status: .forbidden,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: #"{"error":"Access denied"}"#))
            )
        } catch {
            return Response(
                status: .notFound,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: #"{"error":"File not found"}"#))
            )
        }
    }

    // List received files
    api.get("/files") { _, _ in
        let files = FileService.shared.listReceivedFiles()
        return FileListResponse(files: files)
    }
}

// MARK: - Request/Response Types

struct HealthResponse: ResponseCodable {
    let status: String
    let version: String
}

struct ClipboardRequest: Decodable {
    let content: String
}

struct ClipboardResponse: Codable {
    let content: String
}

struct FileReceiveRequest: Decodable {
    let filename: String
    let content: String // base64 encoded
}

struct FileReceiveResponse: Codable {
    let path: String
}

struct FileListResponse: ResponseCodable {
    let files: [String]
}
