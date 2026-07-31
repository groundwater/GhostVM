import Foundation
import GhostVMKit

/// Loopback bridge used by the sandboxed FSKit extension. A random export ID is
/// the capability for one guest directory; callers never provide guest roots.
@MainActor
final class GuestFileSystemBridgeService {
    struct RegisteredExport: Sendable {
        let id: String
        let resourceURL: URL
    }

    private struct Export {
        let root: String
        let readOnly: Bool
    }

    private weak var client: GhostClient?
    private var exports: [String: Export] = [:]
    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private(set) var port: UInt16 = 0

    func start(client: GhostClient) throws {
        guard serverFD < 0 else { return }
        self.client = client

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socket(errno) }

        var reuse: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw BridgeError.bind(errno)
        }
        guard Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw BridgeError.listen(errno)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw BridgeError.socketName(errno)
        }

        serverFD = fd
        port = UInt16(bigEndian: boundAddress.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                let connection = Darwin.accept(fd, nil, nil)
                guard connection >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                Task { @MainActor [weak self] in
                    await self?.handle(connection)
                }
            }
        }
        source.resume()
        acceptSource = source
        NSLog("GuestFileSystemBridgeService: Listening on 127.0.0.1:\(port)")
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        port = 0
        exports.removeAll()
        client = nil
    }

    func registerExport(guestPath: String, readOnly: Bool = true) throws -> RegisteredExport {
        guard port != 0 else { throw BridgeError.notRunning }
        guard guestPath.hasPrefix("/"), !guestPath.contains("\0") else {
            throw BridgeError.invalidGuestPath
        }
        guard exports.count < 32 else { throw BridgeError.tooManyExports }

        let id = UUID().uuidString.lowercased()
        exports[id] = Export(root: guestPath, readOnly: readOnly)
        var components = URLComponents()
        components.scheme = "ghostvm"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/\(id)"
        components.queryItems = [URLQueryItem(name: "mode", value: readOnly ? "ro" : "rw")]
        guard let url = components.url else { throw BridgeError.invalidResourceURL }
        return RegisteredExport(id: id, resourceURL: url)
    }

    func unregisterExport(id: String) {
        exports.removeValue(forKey: id)
    }

    private func handle(_ fd: Int32) async {
        defer { Darwin.close(fd) }
        let request = await Task.detached(priority: .userInitiated) {
            Self.readRequest(fd)
        }.value
        guard let request else {
            Self.writeResponse(fd, status: 400, contentType: "application/json", body: Self.errorBody("Malformed request"))
            return
        }

        let response = await route(request)
        await Task.detached(priority: .userInitiated) {
            Self.writeResponse(fd, status: response.status, contentType: response.contentType, body: response.body)
        }.value
    }

    private func route(_ request: Request) async -> Response {
        guard request.method == "GET" else { return .error(405, "Method not allowed") }
        guard let components = URLComponents(string: "http://localhost\(request.target)") else {
            return .error(400, "Malformed target")
        }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[0] == "v1", let export = exports[parts[1]] else {
            return .error(404, "Export not found")
        }
        let relativePath = components.queryItems?.first(where: { $0.name == "path" })?.value ?? ""
        guard let guestPath = resolve(relativePath: relativePath, within: export.root) else {
            return .error(400, "Invalid relative path")
        }
        guard let client else { return .error(503, "Guest is unavailable") }

        do {
            switch parts[2] {
            case "metadata":
                let metadata = try await client.fileMetadata(path: guestPath)
                return .json(try JSONEncoder().encode(metadata))
            case "list":
                let listing = try await client.listDirectoryMetadata(path: guestPath)
                return .json(try JSONEncoder().encode(listing))
            case "read":
                let offset = UInt64(components.queryItems?.first(where: { $0.name == "offset" })?.value ?? "")
                let length = Int(components.queryItems?.first(where: { $0.name == "length" })?.value ?? "")
                guard let offset, let length, length >= 0, length <= 1024 * 1024 else {
                    return .error(400, "Invalid read range")
                }
                return .binary(try await client.readFile(path: guestPath, offset: offset, length: length))
            case "readlink":
                return .text(try await client.readSymbolicLink(path: guestPath))
            default:
                return .error(404, "Operation not found")
            }
        } catch {
            return .error(502, error.localizedDescription)
        }
    }

    private func resolve(relativePath: String, within root: String) -> String? {
        guard !relativePath.contains("\0"), !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return components.reduce(root) { ($0 as NSString).appendingPathComponent(String($1)) }
    }

    private struct Request {
        let method: String
        let target: String
    }

    private struct Response {
        let status: Int
        let contentType: String
        let body: Data

        static func json(_ data: Data) -> Self { .init(status: 200, contentType: "application/json", body: data) }
        static func binary(_ data: Data) -> Self { .init(status: 200, contentType: "application/octet-stream", body: data) }
        static func text(_ value: String) -> Self { .init(status: 200, contentType: "text/plain; charset=utf-8", body: Data(value.utf8)) }
        static func error(_ status: Int, _ message: String) -> Self {
            .init(status: status, contentType: "application/json", body: GuestFileSystemBridgeService.errorBody(message))
        }
    }

    nonisolated private static func readRequest(_ fd: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while data.count <= 16 * 1024 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer[..<count])
            if data.range(of: terminator) != nil { break }
        }
        guard
            data.count <= 16 * 1024,
            let lineEnd = data.range(of: Data("\r\n".utf8))?.lowerBound,
            let line = String(data: data[..<lineEnd], encoding: .utf8)
        else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        return Request(method: parts[0], target: parts[1])
    }

    nonisolated private static func writeResponse(_ fd: Int32, status: Int, contentType: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        response.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                guard written > 0 else { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }

    nonisolated private static func errorBody(_ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
    }

    enum BridgeError: Error, LocalizedError {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
        case socketName(Int32)
        case notRunning
        case invalidGuestPath
        case tooManyExports
        case invalidResourceURL

        var errorDescription: String? {
            switch self {
            case .socket(let code): return "filesystem bridge socket failed: errno \(code)"
            case .bind(let code): return "filesystem bridge bind failed: errno \(code)"
            case .listen(let code): return "filesystem bridge listen failed: errno \(code)"
            case .socketName(let code): return "filesystem bridge getsockname failed: errno \(code)"
            case .notRunning: return "filesystem bridge is not running"
            case .invalidGuestPath: return "guest export path must be absolute"
            case .tooManyExports: return "filesystem export limit reached"
            case .invalidResourceURL: return "failed to create FSKit resource URL"
            }
        }
    }
}
