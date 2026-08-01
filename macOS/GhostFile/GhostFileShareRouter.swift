import Foundation
import Darwin
import GhostHTTP

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
    let rootURL: URL
    let shareID: UUID
    let shareName: String
    let accessKey: String
    private let resolvedRootURL: URL

    init(rootURL: URL, shareID: UUID, shareName: String, accessKey: String) {
        self.rootURL = rootURL.standardizedFileURL
        self.shareID = shareID
        self.shareName = shareName
        self.accessKey = accessKey
        self.resolvedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func route(_ request: HTTPRequestHead) -> GhostFileHTTPResponse {
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
            let capabilities = GhostFileCapabilities(
                protocolVersion: GhostFileProtocol.version,
                shareID: shareID,
                name: shareName,
                readOnly: true,
                transports: [GhostFileProtocol.transport],
                maximumReadLength: GhostFileProtocol.maximumReadLength
            )
            return json(capabilities, headers: ["Allow": "OPTIONS, GET, HEAD"])
        }

        let relativePath = components.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
        guard let url = resolvedURL(
            relativePath: relativePath,
            followFinalSymbolicLink: operation != "readlink" && operation != "metadata"
        ) else {
            return responseError(.badRequest, "Invalid or escaping relative path")
        }

        do {
            switch (request.method, operation) {
            case (.GET, "metadata"), (.HEAD, "metadata"):
                let metadata = try fileMetadata(at: url, displayName: relativePath.isEmpty ? shareName : nil)
                if request.method == .HEAD {
                    return GhostFileHTTPResponse(status: .ok, headers: ["ETag": metadata.etag])
                }
                return json(metadata, headers: ["ETag": metadata.etag])

            case (.GET, "directory"):
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                let entries = try names.map { name in
                    try fileMetadata(at: url.appendingPathComponent(name, isDirectory: false))
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
                    let childURL = url.appendingPathComponent(entry.name, isDirectory: false)
                    let data = try Data(contentsOf: childURL, options: .mappedIfSafe)
                    let currentMetadata = try fileMetadata(at: childURL)
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
                let metadata = try fileMetadata(at: url)
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
                return fileResponse(url: url, metadata: metadata, byteRange: byteRange)

            case (.GET, "readlink"):
                var info = stat()
                guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError.current() }
                guard info.st_mode & S_IFMT == S_IFLNK else { throw POSIXError(.EINVAL) }
                return .text(try FileManager.default.destinationOfSymbolicLink(atPath: url.path))

            default:
                return responseError(.methodNotAllowed, "Operation not supported")
            }
        } catch let error as POSIXError {
            switch error.code {
            case .ENOENT: return responseError(.notFound, "Path not found")
            case .EACCES, .EPERM: return responseError(.forbidden, "Access denied")
            default: return responseError(.internalServerError, error.localizedDescription)
            }
        } catch {
            return responseError(.internalServerError, error.localizedDescription)
        }
    }

    private func resolvedURL(relativePath: String, followFinalSymbolicLink: Bool) -> URL? {
        guard let pathComponents = GhostFilePath.validatedComponents(relativePath) else { return nil }
        if pathComponents.isEmpty { return rootURL }
        let candidate = pathComponents.reduce(rootURL) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL

        let containmentCandidate = followFinalSymbolicLink
            ? candidate.resolvingSymlinksInPath().standardizedFileURL
            : candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRootURL.path
        guard containmentCandidate.path == rootPath || containmentCandidate.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return candidate
    }

    private func fileMetadata(at url: URL, displayName: String? = nil) throws -> GhostFileMetadata {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError.current() }

        let type: GhostFileNodeType
        switch info.st_mode & S_IFMT {
        case S_IFREG: type = .file
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symbolicLink
        default: type = .other
        }

        var objectID = UInt64(info.st_ino) ^ (UInt64(info.st_dev) &* 0x9E37_79B9_7F4A_7C15)
        let relativeIdentity = url.path.hasPrefix(rootURL.path)
            ? String(url.path.dropFirst(rootURL.path.count))
            : url.path
        for byte in relativeIdentity.utf8 {
            objectID = (objectID ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        objectID = max(objectID, 3)
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int32(info.st_mtimespec.tv_nsec)
        let etagValue = objectID
            ^ UInt64(max(0, info.st_size))
            ^ UInt64(bitPattern: modifiedSeconds)
            ^ UInt64(bitPattern: Int64(modifiedNanoseconds))

        return GhostFileMetadata(
            name: displayName ?? url.lastPathComponent,
            type: type,
            size: UInt64(max(0, info.st_size)),
            mode: UInt32(info.st_mode),
            uid: info.st_uid,
            gid: info.st_gid,
            objectID: objectID,
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds,
            accessedSeconds: Int64(info.st_atimespec.tv_sec),
            accessedNanoseconds: Int32(info.st_atimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int32(info.st_ctimespec.tv_nsec),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int32(info.st_birthtimespec.tv_nsec),
            etag: "\"node-\(String(etagValue, radix: 16))\""
        )
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
        url: URL,
        metadata: GhostFileMetadata,
        byteRange: GhostFileByteRange
    ) -> GhostFileHTTPResponse {
        let end = byteRange.offset + UInt64(byteRange.length) - 1
        return GhostFileHTTPResponse(
            status: .partialContent,
            headers: [
                "Content-Type": "application/octet-stream",
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(byteRange.offset)-\(end)/\(metadata.size)",
                "ETag": metadata.etag,
            ],
            body: .fileRegion(
                path: url.path,
                identity: metadata.etag,
                offset: byteRange.offset,
                length: byteRange.length
            )
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

    private func responseError(_ status: HTTPStatus, _ message: String) -> GhostFileHTTPResponse {
        let payload = (try? JSONEncoder().encode(GhostFileErrorPayload(error: message))) ?? Data()
        return GhostFileHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: .bytes(payload)
        )
    }
}

private extension POSIXError {
    static func current() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
