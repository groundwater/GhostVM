import Foundation
import GhostHTTP
#if !GHOSTFILEKIT_BUILD
import GhostFileKit
#endif

struct GhostFileHTTPResponse: Sendable {
    var status: HTTPStatus
    var headers: HTTPHeaders
    var body: GhostFileHTTPResponseBody

    init(
        status: HTTPStatus,
        headers: HTTPHeaders = HTTPHeaders(),
        body: GhostFileHTTPResponseBody = .empty
    ) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    init(
        status: HTTPStatus,
        headers: [String: String],
        body: GhostFileHTTPResponseBody = .empty
    ) {
        self.init(status: status, headers: HTTPHeaders(headers), body: body)
    }

    static func text(_ string: String, status: HTTPStatus = .ok) -> GhostFileHTTPResponse {
        GhostFileHTTPResponse(
            status: status,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: .bytes(Data(string.utf8))
        )
    }
}

enum GhostFileHTTPResponseBody: Sendable {
    case empty
    case bytes(Data)
    case fileRegion(path: String, identity: String, offset: UInt64, length: Int)

    var contentLength: Int {
        switch self {
        case .empty:
            return 0
        case .bytes(let data):
            return data.count
        case .fileRegion(_, _, _, let length):
            return length
        }
    }
}

final class GhostFileShareRouter: @unchecked Sendable {
    let shareID: UUID
    let shareName: String
    let accessKey: String
    private let provider: any GhostFileProvider
    private let policyLock = NSLock()
    private var storedReadOnly: Bool

    init(rootURL: URL, shareID: UUID, shareName: String, accessKey: String, readOnly: Bool = true) {
        self.provider = LocalFolderProvider(rootURL: rootURL)
        self.shareID = shareID
        self.shareName = shareName
        self.accessKey = accessKey
        self.storedReadOnly = readOnly
    }

    init(
        provider: any GhostFileProvider,
        shareID: UUID,
        shareName: String,
        accessKey: String,
        readOnly: Bool = true
    ) {
        self.provider = provider
        self.shareID = shareID
        self.shareName = shareName
        self.accessKey = accessKey
        self.storedReadOnly = readOnly
    }

    var readOnly: Bool { policyLock.withLock { storedReadOnly } }

    func setReadOnly(_ readOnly: Bool) {
        policyLock.withLock { storedReadOnly = readOnly }
    }

    func route(_ request: HTTPRequestHead, body: Data = Data()) async -> GhostFileHTTPResponse {
        guard request.header("authorization") == "Bearer \(accessKey)" else {
            return responseError(.unauthorized, "A valid GhostFile access key is required")
        }
        guard let components = URLComponents(string: "http://ghostfile.local\(request.path)") else {
            return responseError(.badRequest, "Malformed request URL")
        }
        let basePath = GhostFileProtocol.shareBasePath(id: shareID)
        guard components.path.hasPrefix(basePath + "/") || components.path == basePath else {
            return responseError(.notFound, "Share not found")
        }

        let operation = String(components.path.dropFirst(basePath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if operation == "capabilities", request.method == .GET || request.method == .OPTIONS {
            let isReadOnly = readOnly
            let capabilities = GhostFileCapabilities(
                protocolVersion: GhostFileProtocol.version,
                shareID: shareID,
                name: shareName,
                readOnly: isReadOnly,
                transports: [GhostFileProtocol.transport],
                maximumReadLength: GhostFileProtocol.maximumReadLength
            )
            return json(capabilities, headers: [
                "Allow": isReadOnly
                    ? "OPTIONS, GET, HEAD"
                    : "OPTIONS, GET, HEAD, POST, PATCH, DELETE",
            ])
        }
        if operation == "health", request.method == .GET || request.method == .HEAD {
            return GhostFileHTTPResponse(
                status: .ok,
                headers: ["Cache-Control": "no-store"],
                body: request.method == .HEAD ? .empty : .bytes(Data("ok".utf8))
            )
        }

        let relativePath = components.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
        guard GhostFilePath.validatedComponents(relativePath) != nil else {
            return responseError(.badRequest, "Invalid or escaping relative path")
        }

        do {
            let isMutation = request.method == .POST || request.method == .PATCH || request.method == .DELETE
            if isMutation && readOnly {
                return responseError(.methodNotAllowed, "This share is read-only")
            }
            switch (request.method, operation) {
            case (.GET, "metadata"), (.HEAD, "metadata"):
                let metadata = try await metadata(path: relativePath, displayName: relativePath.isEmpty ? shareName : nil)
                if request.method == .HEAD {
                    return GhostFileHTTPResponse(status: .ok, headers: ["ETag": metadata.etag])
                }
                return json(metadata, headers: ["ETag": metadata.etag])

            case (.GET, "directory"):
                let entries = try await provider.contentsOfDirectory(path: relativePath).map {
                    metadata($0)
                }
                var inlineContents: [GhostFileInlineContent] = []
                var inlineByteCount = 0
                for entry in entries where entry.type == .file
                    && entry.size <= UInt64(GhostFileProtocol.maximumInlineFileLength) {
                    guard inlineContents.count < GhostFileProtocol.maximumInlineDirectoryFileCount else {
                        break
                    }
                    let length = Int(entry.size)
                    guard inlineByteCount + length <= GhostFileProtocol.maximumInlineDirectoryLength else {
                        continue
                    }
                    let childPath = relativePath.isEmpty ? entry.name : "\(relativePath)/\(entry.name)"
                    let data = try await data(from: provider.read(path: childPath, offset: 0, length: length))
                    let currentMetadata = try await metadata(path: childPath)
                    guard data.count == length, currentMetadata.etag == entry.etag else { continue }
                    inlineContents.append(GhostFileInlineContent(
                        name: entry.name,
                        etag: entry.etag,
                        data: data
                    ))
                    inlineByteCount += data.count
                }
                let listing = GhostFileDirectoryListing(
                    path: relativePath,
                    verifier: directoryVerifier(entries),
                    entries: entries,
                    inlineContents: inlineContents.isEmpty ? nil : inlineContents
                )
                return json(listing, headers: [
                    "Cache-Control": "private, max-age=5",
                    "ETag": "\"dir-\(String(listing.verifier, radix: 16))\"",
                ])

            case (.GET, "content"):
                let metadata = try await metadata(path: relativePath)
                guard metadata.type == .file else {
                    return responseError(.badRequest, "Path is not a regular file")
                }
                guard metadata.size > 0 else {
                    return GhostFileHTTPResponse(
                        status: .ok,
                        headers: ["Accept-Ranges": "bytes", "ETag": metadata.etag],
                        body: .bytes(Data())
                    )
                }
                guard let byteRange = GhostFileByteRange.parse(
                    request.header("range"),
                    fileSize: metadata.size,
                    maximumLength: GhostFileProtocol.maximumReadLength
                ) else {
                    return GhostFileHTTPResponse(
                        status: .rangeNotSatisfiable,
                        headers: ["Content-Range": "bytes */\(metadata.size)"]
                    )
                }
                return try await fileResponse(path: relativePath, metadata: metadata, byteRange: byteRange)

            case (.GET, "readlink"):
                return .text(try await provider.readSymbolicLink(path: relativePath))

            case (.POST, "create"):
                guard !relativePath.isEmpty,
                      let create = try? JSONDecoder().decode(GhostFileCreateRequest.self, from: body) else {
                    return responseError(.badRequest, "A valid create request is required")
                }
                let type: GhostFileProviderCreateType = create.type == .file ? .file : .directory
                return json(metadata(try await provider.create(
                    path: relativePath,
                    type: type,
                    mode: create.mode
                )))

            case (.POST, "symlink"):
                guard !relativePath.isEmpty,
                      let link = try? JSONDecoder().decode(GhostFileSymbolicLinkRequest.self, from: body),
                      !link.destination.contains("\0") else {
                    return responseError(.badRequest, "A valid symbolic-link request is required")
                }
                return json(metadata(try await provider.createSymbolicLink(
                    path: relativePath,
                    destination: link.destination
                )))

            case (.PATCH, "content"):
                guard body.count <= GhostFileProtocol.maximumWriteLength,
                      let offsetValue = request.header("x-ghostfile-offset"),
                      let offset = UInt64(offsetValue), offset <= UInt64(Int64.max) else {
                    return responseError(.badRequest, "A valid write offset and bounded body are required")
                }
                let updated = try await provider.write(path: relativePath, offset: offset, data: body)
                return json(metadata(updated), headers: [
                    "X-GhostFile-Bytes-Written": String(body.count),
                ])

            case (.PATCH, "attributes"):
                guard let attributes = try? JSONDecoder().decode(
                    GhostFileSetAttributesRequest.self,
                    from: body
                ) else {
                    return responseError(.badRequest, "A valid attribute request is required")
                }
                let updated = try await provider.setAttributes(
                    path: relativePath,
                    attributes: GhostFileProviderAttributes(
                        mode: attributes.mode,
                        size: attributes.size,
                        modifiedSeconds: attributes.modifiedSeconds,
                        modifiedNanoseconds: attributes.modifiedNanoseconds,
                        accessedSeconds: attributes.accessedSeconds,
                        accessedNanoseconds: attributes.accessedNanoseconds
                    )
                )
                return json(metadata(updated))

            case (.DELETE, "remove"):
                guard !relativePath.isEmpty else {
                    return responseError(.badRequest, "The share root cannot be removed")
                }
                try await provider.remove(path: relativePath)
                return GhostFileHTTPResponse(status: .noContent)

            case (.POST, "rename"):
                guard !relativePath.isEmpty,
                      let rename = try? JSONDecoder().decode(GhostFileRenameRequest.self, from: body),
                      !rename.destinationPath.isEmpty,
                      GhostFilePath.validatedComponents(rename.destinationPath) != nil else {
                    return responseError(.badRequest, "A valid contained rename destination is required")
                }
                return json(metadata(try await provider.rename(
                    path: relativePath,
                    destinationPath: rename.destinationPath
                )))

            default:
                return responseError(.methodNotAllowed, "Operation not supported")
            }
        } catch let error as POSIXError {
            switch error.code {
            case .ENOENT: return responseError(.notFound, "Path not found", errno: error.code.rawValue)
            case .EACCES, .EPERM: return responseError(.forbidden, "Access denied", errno: error.code.rawValue)
            case .EEXIST, .ENOTEMPTY: return responseError(.conflict, error.localizedDescription, errno: error.code.rawValue)
            case .ENOSPC: return responseError(.insufficientStorage, error.localizedDescription, errno: error.code.rawValue)
            case .EINVAL, .EISDIR, .ENOTDIR: return responseError(.badRequest, error.localizedDescription, errno: error.code.rawValue)
            default: return responseError(.internalServerError, error.localizedDescription, errno: error.code.rawValue)
            }
        } catch {
            return responseError(.internalServerError, error.localizedDescription)
        }
    }

    private func metadata(path: String, displayName: String? = nil) async throws -> GhostFileMetadata {
        metadata(try await provider.metadata(path: path), displayName: displayName)
    }

    private func metadata(
        _ value: GhostFileProviderMetadata,
        displayName: String? = nil
    ) -> GhostFileMetadata {
        let type: GhostFileNodeType
        switch value.type {
        case .file: type = .file
        case .directory: type = .directory
        case .symbolicLink: type = .symbolicLink
        case .other: type = .other
        }
        return GhostFileMetadata(
            name: displayName ?? value.name,
            type: type,
            size: value.size,
            mode: value.mode,
            uid: value.uid,
            gid: value.gid,
            objectID: value.objectID,
            modifiedSeconds: value.modifiedSeconds,
            modifiedNanoseconds: value.modifiedNanoseconds,
            accessedSeconds: value.accessedSeconds,
            accessedNanoseconds: value.accessedNanoseconds,
            changedSeconds: value.changedSeconds,
            changedNanoseconds: value.changedNanoseconds,
            birthSeconds: value.birthSeconds,
            birthNanoseconds: value.birthNanoseconds,
            etag: value.etag
        )
    }

    private func data(from read: GhostFileProviderRead) async throws -> Data {
        switch read {
        case .data(let data):
            return data
        case .fileRegion(let path, _, let offset, let length):
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length) ?? Data()
        }
    }

    private func directoryVerifier(_ entries: [GhostFileMetadata]) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for entry in entries {
            for byte in (entry.name + "\0" + entry.etag).utf8 {
                value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return max(value, 1)
    }

    private func fileResponse(
        path: String,
        metadata: GhostFileMetadata,
        byteRange: GhostFileByteRange
    ) async throws -> GhostFileHTTPResponse {
        let end = byteRange.offset + UInt64(byteRange.length) - 1
        let read = try await provider.read(
            path: path,
            offset: byteRange.offset,
            length: byteRange.length
        )
        let body: GhostFileHTTPResponseBody
        switch read {
        case .data(let data):
            guard data.count == byteRange.length else { throw POSIXError(.EIO) }
            body = .bytes(data)
        case .fileRegion(let path, let identity, let offset, let length):
            body = .fileRegion(path: path, identity: identity, offset: offset, length: length)
        }
        return GhostFileHTTPResponse(
            status: .partialContent,
            headers: [
                "Content-Type": "application/octet-stream",
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(byteRange.offset)-\(end)/\(metadata.size)",
                "ETag": metadata.etag,
            ],
            body: body
        )
    }

    private func json<T: Encodable>(
        _ value: T,
        headers: [String: String] = [:]
    ) -> GhostFileHTTPResponse {
        do {
            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json"
            return GhostFileHTTPResponse(
                status: .ok,
                headers: responseHeaders,
                body: .bytes(try JSONEncoder().encode(value))
            )
        } catch {
            return responseError(.internalServerError, "Failed to encode response")
        }
    }

    private func responseError(
        _ status: HTTPStatus,
        _ message: String,
        errno: Int32? = nil
    ) -> GhostFileHTTPResponse {
        let payload = (try? JSONEncoder().encode(GhostFileErrorPayload(error: message, errno: errno))) ?? Data()
        return GhostFileHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: .bytes(payload)
        )
    }
}
