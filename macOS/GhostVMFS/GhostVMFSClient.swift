import Foundation
import FSKit

enum GhostVMFileType: String, Codable {
    case file
    case directory
    case symbolicLink
    case other
}

struct GhostVMFileMetadata: Codable {
    let name: String
    let type: GhostVMFileType
    let size: UInt64
    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
    let inode: UInt64
    let device: UInt64
    let linkCount: UInt32
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int32
}

struct GhostVMDirectoryMetadata: Codable {
    let path: String
    let entries: [GhostVMFileMetadata]
}

struct GhostVMFSClient: Sendable {
    private let baseURL: URL
    private let session: URLSession

    init(resourceURL: URL) throws {
        guard
            resourceURL.scheme == "ghostvm",
            resourceURL.host == "127.0.0.1",
            let port = resourceURL.port,
            resourceURL.pathComponents.count == 2,
            let exportID = resourceURL.pathComponents.last,
            !exportID.isEmpty
        else {
            throw fs_errorForPOSIXError(EINVAL)
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/v1/\(exportID)"
        guard let baseURL = components.url else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func metadata(path: String) async throws -> GhostVMFileMetadata {
        try await JSONDecoder().decode(GhostVMFileMetadata.self, from: request(operation: "metadata", path: path))
    }

    func list(path: String) async throws -> GhostVMDirectoryMetadata {
        try await JSONDecoder().decode(GhostVMDirectoryMetadata.self, from: request(operation: "list", path: path))
    }

    func read(path: String, offset: UInt64, length: Int) async throws -> Data {
        try await request(
            operation: "read",
            path: path,
            extraQuery: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "length", value: String(length)),
            ]
        )
    }

    func readSymbolicLink(path: String) async throws -> String {
        let data = try await request(operation: "readlink", path: path)
        guard let target = String(data: data, encoding: .utf8), !target.contains("\0") else {
            throw fs_errorForPOSIXError(EIO)
        }
        return target
    }

    private func request(
        operation: String,
        path: String,
        extraQuery: [URLQueryItem] = []
    ) async throws -> Data {
        let operationURL = baseURL.appendingPathComponent(operation)
        guard var components = URLComponents(url: operationURL, resolvingAgainstBaseURL: false) else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        components.queryItems = [URLQueryItem(name: "path", value: path)] + extraQuery
        guard let url = components.url else { throw fs_errorForPOSIXError(EINVAL) }

        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse else {
                throw fs_errorForPOSIXError(EIO)
            }
            switch response.statusCode {
            case 200:
                return data
            case 400:
                throw fs_errorForPOSIXError(EINVAL)
            case 404:
                throw fs_errorForPOSIXError(ENOENT)
            case 503:
                throw fs_errorForPOSIXError(ENOTCONN)
            default:
                throw fs_errorForPOSIXError(EIO)
            }
        } catch let error as POSIXError {
            throw error
        } catch {
            throw fs_errorForPOSIXError(ENOTCONN)
        }
    }
}
