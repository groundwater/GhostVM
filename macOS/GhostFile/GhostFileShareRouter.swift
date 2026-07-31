import Foundation
import Darwin
import GhostHTTP

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

    func route(_ request: HTTPRequestHead) -> HTTPResponse {
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
                    return HTTPResponse(status: .ok, headers: ["ETag": metadata.etag])
                }
                return json(metadata, headers: ["ETag": metadata.etag])

            case (.GET, "directory"):
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                let entries = try names.map { name in
                    try fileMetadata(at: url.appendingPathComponent(name, isDirectory: false))
                }
                let listing = GhostFileDirectoryListing(
                    path: relativePath,
                    verifier: directoryVerifier(entries),
                    entries: entries
                )
                return json(listing, headers: ["ETag": "\"dir-\(String(listing.verifier, radix: 16))\""])

            case (.GET, "content"):
                let metadata = try fileMetadata(at: url)
                guard metadata.type == .file else {
                    return responseError(.badRequest, "Path is not a regular file")
                }
                guard metadata.size > 0 else {
                    return HTTPResponse(
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
                    return HTTPResponse(
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
    ) -> HTTPResponse {
        let end = byteRange.offset + UInt64(byteRange.length) - 1
        return HTTPResponse(
            status: .partialContent,
            headers: [
                "Content-Type": "application/octet-stream",
                "Accept-Ranges": "bytes",
                "Content-Range": "bytes \(byteRange.offset)-\(end)/\(metadata.size)",
                "ETag": metadata.etag,
            ],
            body: .stream(contentLength: byteRange.length) { writer in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: byteRange.offset)
                var remaining = byteRange.length
                while remaining > 0 {
                    let data = try handle.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
                    guard !data.isEmpty else { throw POSIXError(.EIO) }
                    try writer.write(data)
                    remaining -= data.count
                }
            }
        )
    }

    private func json<T: Encodable>(_ value: T, headers: [String: String] = [:]) -> HTTPResponse {
        do {
            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/json"
            return HTTPResponse(
                status: .ok,
                headers: responseHeaders,
                body: .bytes(try JSONEncoder().encode(value))
            )
        } catch {
            return responseError(.internalServerError, "Failed to encode response")
        }
    }

    private func responseError(_ status: HTTPStatus, _ message: String) -> HTTPResponse {
        let payload = (try? JSONEncoder().encode(GhostFileErrorPayload(error: message))) ?? Data()
        return HTTPResponse(
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
