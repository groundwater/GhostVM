import CryptoKit
import Dispatch
import Foundation
import FSKit
import GhostHTTP3
import Network
import OSLog
import Security

private let ghostFileHTTP3Logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "org.ghostvm.ghostfilekit",
    category: "HTTP3"
)

private let ghostFileCacheDiagnosticsEnabled =
    ProcessInfo.processInfo.environment["GHOSTFILE_CACHE_DIAGNOSTICS"] == "1"

private func ghostFileCacheDiagnostic(_ operation: String, path: String, result: String) {
    guard ghostFileCacheDiagnosticsEnabled else { return }
    ghostFileHTTP3Logger.notice(
        "GHOSTFILE_CACHE_DIAG operation=\(operation, privacy: .public) result=\(result, privacy: .public) path=\(path, privacy: .private(mask: .hash))"
    )
}

private let ghostFileProcessLogIdentity: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return "version=\(version) build=\(build) pid=\(ProcessInfo.processInfo.processIdentifier)"
}()

private func ghostFileElapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    return now >= startedAt ? (now - startedAt) / 1_000_000 : 0
}

struct GhostFileHTTP3Client: Sendable {
    private let transport: GhostFileHTTP3TransportPool
    private let cache: GhostFileResponseCache
    private let healthReporter: GhostFileMountHealthReporter?

    init(
        resourceURL: URL,
        connectionTimeout: Duration = .seconds(8),
        requestTimeout: Duration = .seconds(5)
    ) throws {
        guard resourceURL.scheme == GhostFileProtocol.urlScheme,
              let host = resourceURL.host,
              let portNumber = resourceURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let components = URLComponents(url: resourceURL, resolvingAgainstBaseURL: false),
              let accessKey = components.queryItems?.first(where: { $0.name == "access_key" })?.value,
              !accessKey.isEmpty,
              let peerPin = GhostFileProtocol.peerPin(from: resourceURL) else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        let cacheTTLSeconds: UInt64
        if let rawTTL = components.queryItems?.first(where: {
            $0.name == GhostFileProtocol.cacheTTLQueryName
        })?.value {
            guard let parsedTTL = UInt64(rawTTL),
                  parsedTTL <= GhostFileProtocol.maximumCacheTTLSeconds else {
                throw fs_errorForPOSIXError(EINVAL)
            }
            cacheTTLSeconds = parsedTTL
        } else {
            cacheTTLSeconds = GhostFileProtocol.defaultCacheTTLSeconds
        }
        cache = GhostFileResponseCache(lifetimeSeconds: cacheTTLSeconds)
        transport = try GhostFileHTTP3TransportPool(
            host: host,
            port: port,
            accessKey: accessKey,
            peerPin: peerPin,
            resourceBasePath: resourceURL.path,
            connectionTimeout: connectionTimeout,
            requestTimeout: requestTimeout
        )
        healthReporter = GhostFileProtocol.mountInstanceID(from: resourceURL).map {
            GhostFileMountHealthReporter(mountID: $0)
        }
    }

    func startHealthMonitoring() async {
        await healthReporter?.start(transport: transport)
    }

    func stopHealthMonitoring() async {
        await healthReporter?.stop()
    }

    func capabilities() async throws -> GhostFileCapabilities {
        try await decode(GhostFileCapabilities.self, operation: "capabilities", relativePath: nil)
    }

    func metadata(path: String) async throws -> GhostFileMetadata {
        if let cached = await cache.metadata(path: path) {
            ghostFileCacheDiagnostic("metadata", path: path, result: "hit")
            return cached
        }
        ghostFileCacheDiagnostic("metadata", path: path, result: "miss")
        let metadata = try await decode(GhostFileMetadata.self, operation: "metadata", relativePath: path)
        await cache.store(metadata: metadata, path: path)
        return metadata
    }

    func directory(path: String) async throws -> GhostFileDirectoryListing {
        if let cached = await cache.directory(path: path) {
            ghostFileCacheDiagnostic("directory", path: path, result: "hit")
            return cached
        }
        ghostFileCacheDiagnostic("directory", path: path, result: "miss")
        let listing = try await decode(
            GhostFileDirectoryListing.self,
            operation: "directory",
            relativePath: path
        )
        await cache.store(listing: listing, path: path)
        return listing
    }

    func read(path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length >= 0, length <= GhostFileProtocol.maximumReadLength else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        if let cached = await cache.content(path: path, offset: offset, length: length) {
            ghostFileCacheDiagnostic("content", path: path, result: "hit")
            return cached
        }
        ghostFileCacheDiagnostic("content", path: path, result: "miss")
        let data = try await request(operation: "content", relativePath: path, offset: offset, length: length)
        await cache.storeRead(data: data, path: path, offset: offset)
        return data
    }

    func readSymbolicLink(path: String) async throws -> String {
        let data = try await request(operation: "readlink", relativePath: path)
        guard let value = String(data: data, encoding: .utf8), !value.contains("\0") else {
            throw fs_errorForPOSIXError(EIO)
        }
        return value
    }

    func create(path: String, type: GhostFileCreateType, mode: UInt32) async throws -> GhostFileMetadata {
        let payload = try encode(GhostFileCreateRequest(type: type, mode: mode))
        let metadata = try await decodeMutation(
            operation: "create",
            relativePath: path,
            method: "POST",
            body: payload
        )
        await cache.invalidateAll()
        return metadata
    }

    func createSymbolicLink(path: String, destination: String) async throws -> GhostFileMetadata {
        let payload = try encode(GhostFileSymbolicLinkRequest(destination: destination))
        let metadata = try await decodeMutation(
            operation: "symlink",
            relativePath: path,
            method: "POST",
            body: payload
        )
        await cache.invalidateAll()
        return metadata
    }

    func write(path: String, offset: UInt64, data: Data) async throws -> GhostFileMetadata {
        var currentOffset = offset
        var cursor = 0
        var latestMetadata: GhostFileMetadata?
        while cursor < data.count {
            let end = min(data.count, cursor + GhostFileProtocol.maximumWriteLength)
            let chunk = data.subdata(in: cursor..<end)
            let response = try await request(
                operation: "content",
                relativePath: path,
                method: "PATCH",
                body: chunk,
                headers: [("x-ghostfile-offset", String(currentOffset))]
            )
            latestMetadata = try decodeResponse(GhostFileMetadata.self, data: response)
            cursor = end
            currentOffset += UInt64(chunk.count)
        }
        await cache.invalidateAll()
        if let latestMetadata { return latestMetadata }
        return try await metadata(path: path)
    }

    func setAttributes(
        path: String,
        attributes: GhostFileSetAttributesRequest
    ) async throws -> GhostFileMetadata {
        let metadata = try await decodeMutation(
            operation: "attributes",
            relativePath: path,
            method: "PATCH",
            body: try encode(attributes)
        )
        await cache.invalidateAll()
        return metadata
    }

    func remove(path: String) async throws {
        _ = try await request(operation: "remove", relativePath: path, method: "DELETE")
        await cache.invalidateAll()
    }

    func rename(path: String, destinationPath: String) async throws -> GhostFileMetadata {
        let metadata = try await decodeMutation(
            operation: "rename",
            relativePath: path,
            method: "POST",
            body: try encode(GhostFileRenameRequest(destinationPath: destinationPath))
        )
        await cache.invalidateAll()
        return metadata
    }

    func invalidateTransportForTesting() async {
        await transport.invalidateCurrentTransportForTesting()
    }

    func transportLogIDForTesting() async -> String? {
        await transport.currentTransportLogIDForTesting()
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        operation: String,
        relativePath: String?
    ) async throws -> T {
        let data = try await request(operation: operation, relativePath: relativePath)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw fs_errorForPOSIXError(EIO)
        }
    }

    private func decodeMutation(
        operation: String,
        relativePath: String,
        method: String,
        body: Data
    ) async throws -> GhostFileMetadata {
        let data = try await request(
            operation: operation,
            relativePath: relativePath,
            method: method,
            body: body
        )
        return try decodeResponse(GhostFileMetadata.self, data: data)
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw fs_errorForPOSIXError(EIO)
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw fs_errorForPOSIXError(EINVAL)
        }
    }

    private func request(
        operation: String,
        relativePath: String?,
        offset: UInt64? = nil,
        length: Int? = nil,
        method: String = "GET",
        body: Data = Data(),
        headers: [(String, String)] = []
    ) async throws -> Data {
        let response: GhostFileHTTP3Transport.Response
        do {
            response = try await transport.request(
                operation: operation,
                relativePath: relativePath,
                offset: offset,
                length: length,
                method: method,
                body: body,
                headers: headers
            )
            await healthReporter?.record(.operationSucceeded)
        } catch {
            await healthReporter?.record(
                ghostFileIsExplicitPeerClose(error) ? .peerClosed : .operationFailed,
                detail: String(describing: error)
            )
            ghostFileHTTP3Logger.error(
                "Request failed operation=\(operation, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw fs_errorForPOSIXError(ENOTCONN)
        }
        if ![200, 201, 204, 206].contains(response.status),
           let payload = try? JSONDecoder().decode(GhostFileErrorPayload.self, from: response.body),
           let rawErrno = payload.errno {
            throw fs_errorForPOSIXError(rawErrno)
        }
        switch response.status {
        case 200, 201, 204, 206:
            return response.body
        case 400, 416:
            throw fs_errorForPOSIXError(EINVAL)
        case 401, 403:
            await healthReporter?.record(.operationFailed, detail: "The share rejected its access key")
            throw fs_errorForPOSIXError(EACCES)
        case 405:
            throw fs_errorForPOSIXError(EROFS)
        case 409:
            throw fs_errorForPOSIXError(EEXIST)
        case 507:
            throw fs_errorForPOSIXError(ENOSPC)
        case 404:
            throw fs_errorForPOSIXError(ENOENT)
        case 502, 503, 504:
            await healthReporter?.record(.operationFailed, detail: "The share reported a transport failure")
            throw fs_errorForPOSIXError(ENOTCONN)
        default:
            await healthReporter?.record(.operationFailed, detail: "The share returned HTTP \(response.status)")
            throw fs_errorForPOSIXError(EIO)
        }
    }
}

private func ghostFileIsExplicitPeerClose(_ error: Error) -> Bool {
    guard let transportError = error as? GhostFileHTTP3Transport.TransportError else { return false }
    if case .peerClosed = transportError { return true }
    return false
}

private actor GhostFileMountHealthReporter {
    private let mountID: UUID
    private let fileURL: URL
    private var snapshot: GhostFileMountHealthSnapshot
    private var heartbeatTask: Task<Void, Never>?

    init(mountID: UUID) {
        self.mountID = mountID
        fileURL = GhostFileMountHealthStorage.writerURL(for: mountID)
        snapshot = GhostFileMountHealthSnapshot(
            mountID: mountID,
            state: .online,
            detail: nil,
            updatedAt: .distantPast
        )
    }

    func start(transport: GhostFileHTTP3TransportPool) {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: GhostFileProtocol.heartbeatInterval)
                    guard !Task.isCancelled else { return }
                    do {
                        let response = try await transport.request(
                            operation: "health",
                            relativePath: nil,
                            offset: nil,
                            length: nil
                        )
                        if response.status == 200 {
                            await self?.record(.heartbeatSucceeded)
                        } else {
                            await self?.record(
                                .heartbeatMissed,
                                detail: "Heartbeat returned HTTP \(response.status)"
                            )
                        }
                    } catch {
                        await self?.record(
                            ghostFileIsExplicitPeerClose(error) ? .peerClosed : .heartbeatMissed,
                            detail: String(describing: error)
                        )
                    }
                } catch {
                    return
                }
            }
        }
    }

    func record(_ event: GhostFileMountHealthEvent, detail: String? = nil) {
        snapshot = snapshot.applying(event, detail: detail)
        persist()
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            ghostFileHTTP3Logger.error(
                "Unable to persist mount health mount=\(self.mountID.uuidString.lowercased(), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}

private actor GhostFileHTTP3TransportPool {
    private let host: String
    private let port: NWEndpoint.Port
    private let accessKey: String
    private let peerPin: GhostFilePeerPin
    private let resourceBasePath: String
    private let connectionTimeout: Duration
    private let requestTimeout: Duration
    private var current: GhostFileHTTP3Transport?
    private var mutationInFlight = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        host: String,
        port: NWEndpoint.Port,
        accessKey: String,
        peerPin: GhostFilePeerPin,
        resourceBasePath: String,
        connectionTimeout: Duration,
        requestTimeout: Duration
    ) throws {
        self.host = host
        self.port = port
        self.accessKey = accessKey
        self.peerPin = peerPin
        self.resourceBasePath = resourceBasePath
        self.connectionTimeout = connectionTimeout
        self.requestTimeout = requestTimeout
        current = try Self.makeTransport(
            host: host,
            port: port,
            accessKey: accessKey,
            peerPin: peerPin,
            resourceBasePath: resourceBasePath,
            connectionTimeout: connectionTimeout,
            requestTimeout: requestTimeout
        )
    }

    func request(
        operation: String,
        relativePath: String?,
        offset: UInt64?,
        length: Int?,
        method: String = "GET",
        body: Data = Data(),
        headers: [(String, String)] = []
    ) async throws -> GhostFileHTTP3Transport.Response {
        let isMutation = method != "GET" && method != "HEAD"
        if isMutation { await acquireMutationSlot() }
        defer {
            if isMutation { releaseMutationSlot() }
        }
        let requestID = Self.makeLogID()
        let pathTag = Self.pathTag(relativePath)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var lastError: Error?
        for attempt in 0...1 {
            let candidate = try transport()
            ghostFileHTTP3Logger.info(
                "Request attempt request=\(requestID, privacy: .public) transport=\(candidate.logID, privacy: .public) attempt=\(attempt + 1, privacy: .public) operation=\(operation, privacy: .public) pathTag=\(pathTag, privacy: .public) offset=\(String(describing: offset), privacy: .public) length=\(String(describing: length), privacy: .public)"
            )
            do {
                let response = try await candidate.request(
                    requestID: requestID,
                    operation: operation,
                    relativePath: relativePath,
                    offset: offset,
                    length: length,
                    method: method,
                    body: body,
                    additionalHeaders: headers
                )
                ghostFileHTTP3Logger.info(
                    "Request succeeded request=\(requestID, privacy: .public) transport=\(candidate.logID, privacy: .public) attempt=\(attempt + 1, privacy: .public) operation=\(operation, privacy: .public) status=\(response.status, privacy: .public) bytes=\(response.body.count, privacy: .public) totalMs=\(ghostFileElapsedMilliseconds(since: startedAt), privacy: .public)"
                )
                return response
            } catch {
                lastError = error
                let terminal = await candidate.isTerminal
                let requestTimedOut = Self.isRequestTimeout(error)
                let peerClosed = Self.isCleanPeerClose(error)
                ghostFileHTTP3Logger.error(
                    "Request attempt failed request=\(requestID, privacy: .public) transport=\(candidate.logID, privacy: .public) attempt=\(attempt + 1, privacy: .public) operation=\(operation, privacy: .public) error=\(String(describing: error), privacy: .public) terminal=\(terminal, privacy: .public) totalMs=\(ghostFileElapsedMilliseconds(since: startedAt), privacy: .public)"
                )
                if requestTimedOut, !terminal {
                    // A request deadline belongs to one HTTP/3 stream, not to
                    // the QUIC connection. requestDeadlineExpired has already
                    // reset that stream; keep the established transport for
                    // sibling and subsequent requests.
                    ghostFileHTTP3Logger.notice(
                        "Request stream failed; transport retained request=\(requestID, privacy: .public) transport=\(candidate.logID, privacy: .public) operation=\(operation, privacy: .public) reason=requestTimedOut"
                    )
                    throw error
                }
                guard terminal else { throw error }
                if current === candidate { current = nil }
                guard !peerClosed else { throw error }
                // A terminal failure can happen after the server committed a
                // mutation but before its response reached us. Retrying a
                // create, rename, delete, or write could apply it twice.
                guard method == "GET" || method == "HEAD" else { throw error }
                guard attempt == 0 else { throw error }
                ghostFileHTTP3Logger.notice(
                    "Request retry scheduled request=\(requestID, privacy: .public) retiredTransport=\(candidate.logID, privacy: .public) operation=\(operation, privacy: .public) reason=\(String(describing: error), privacy: .public) delayMs=100"
                )
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? GhostFileHTTP3Transport.TransportError.closed
    }

    private func acquireMutationSlot() async {
        if !mutationInFlight {
            mutationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationSlot() {
        if mutationWaiters.isEmpty {
            mutationInFlight = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    func invalidateCurrentTransportForTesting() async {
        await current?.invalidateForTesting()
    }

    func currentTransportLogIDForTesting() -> String? {
        current?.logID
    }

    private func transport() throws -> GhostFileHTTP3Transport {
        if let current { return current }
        let replacement = try Self.makeTransport(
            host: host,
            port: port,
            accessKey: accessKey,
            peerPin: peerPin,
            resourceBasePath: resourceBasePath,
            connectionTimeout: connectionTimeout,
            requestTimeout: requestTimeout
        )
        current = replacement
        ghostFileHTTP3Logger.notice(
            "Transport pool installed transport=\(replacement.logID, privacy: .public) host=\(self.host, privacy: .public) port=\(self.port.rawValue, privacy: .public)"
        )
        return replacement
    }

    private nonisolated static func makeLogID() -> String {
        String(UUID().uuidString.prefix(12)).lowercased()
    }

    private nonisolated static func pathTag(_ path: String?) -> String {
        guard let path else { return "none" }
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func makeTransport(
        host: String,
        port: NWEndpoint.Port,
        accessKey: String,
        peerPin: GhostFilePeerPin,
        resourceBasePath: String,
        connectionTimeout: Duration,
        requestTimeout: Duration
    ) throws -> GhostFileHTTP3Transport {
        try GhostFileHTTP3Transport(
            host: host,
            port: port,
            accessKey: accessKey,
            peerPin: peerPin,
            resourceBasePath: resourceBasePath,
            connectionTimeout: connectionTimeout,
            requestTimeout: requestTimeout
        )
    }

    private nonisolated static func isRequestTimeout(_ error: Error) -> Bool {
        guard let transportError = error as? GhostFileHTTP3Transport.TransportError else {
            return false
        }
        if case .requestTimedOut = transportError { return true }
        return false
    }

    private nonisolated static func isCleanPeerClose(_ error: Error) -> Bool {
        guard let transportError = error as? GhostFileHTTP3Transport.TransportError else {
            return false
        }
        if case .peerClosed = transportError { return true }
        return false
    }
}

private actor GhostFileResponseCache {
    private struct Entry<Value: Sendable>: Sendable {
        let value: Value
        let storedAt: UInt64
    }

    private struct CachedContent: Sendable {
        let data: Data
        let etag: String
    }

    private static let maximumMetadataCount = 32_768
    private static let maximumDirectoryCount = 2_048
    private static let maximumContentBytes = 64 * 1024 * 1024

    private var metadataEntries: [String: Entry<GhostFileMetadata>] = [:]
    private var directoryEntries: [String: Entry<GhostFileDirectoryListing>] = [:]
    private var contentEntries: [String: Entry<CachedContent>] = [:]
    private var contentBytes = 0
    private let lifetime: UInt64

    init(lifetimeSeconds: UInt64) {
        lifetime = lifetimeSeconds * 1_000_000_000
    }

    func metadata(path: String) -> GhostFileMetadata? {
        fresh(metadataEntries[path])?.value
    }

    func directory(path: String) -> GhostFileDirectoryListing? {
        fresh(directoryEntries[path])?.value
    }

    func content(path: String, offset: UInt64, length: Int) -> Data? {
        guard let entry = fresh(contentEntries[path]) else {
            removeContent(path: path)
            return nil
        }
        if let metadata = fresh(metadataEntries[path])?.value,
           metadata.etag != entry.value.etag {
            removeContent(path: path)
            return nil
        }
        guard offset <= UInt64(entry.value.data.count) else { return nil }
        let start = Int(offset)
        let end = min(entry.value.data.count, start + length)
        return entry.value.data.subdata(in: start..<end)
    }

    func store(metadata: GhostFileMetadata, path: String) {
        let now = Self.now
        metadataEntries[path] = Entry(value: metadata, storedAt: now)
        trimMetadataIfNeeded()
    }

    func store(listing: GhostFileDirectoryListing, path: String) {
        let now = Self.now
        directoryEntries[path] = Entry(value: listing, storedAt: now)
        for metadata in listing.entries {
            let childPath = path.isEmpty ? metadata.name : "\(path)/\(metadata.name)"
            metadataEntries[childPath] = Entry(value: metadata, storedAt: now)
        }
        for inline in listing.inlineContents ?? [] {
            guard inline.data.count <= GhostFileProtocol.maximumInlineFileLength else { continue }
            let childPath = path.isEmpty ? inline.name : "\(path)/\(inline.name)"
            guard metadataEntries[childPath]?.value.etag == inline.etag else { continue }
            storeContent(inline.data, etag: inline.etag, path: childPath, storedAt: now)
        }
        trimMetadataIfNeeded()
        trimDirectoriesIfNeeded()
        trimContentIfNeeded()
    }

    func storeRead(data: Data, path: String, offset: UInt64) {
        guard offset == 0,
              data.count <= GhostFileProtocol.maximumInlineFileLength,
              let metadata = fresh(metadataEntries[path])?.value,
              metadata.size == UInt64(data.count) else { return }
        storeContent(data, etag: metadata.etag, path: path, storedAt: Self.now)
        trimContentIfNeeded()
    }

    func invalidateAll() {
        metadataEntries.removeAll(keepingCapacity: true)
        directoryEntries.removeAll(keepingCapacity: true)
        contentEntries.removeAll(keepingCapacity: true)
        contentBytes = 0
    }

    private func fresh<Value: Sendable>(_ entry: Entry<Value>?) -> Entry<Value>? {
        guard lifetime > 0, let entry, Self.now &- entry.storedAt <= lifetime else { return nil }
        return entry
    }

    private func storeContent(_ data: Data, etag: String, path: String, storedAt: UInt64) {
        if let previous = contentEntries[path] { contentBytes -= previous.value.data.count }
        contentEntries[path] = Entry(value: CachedContent(data: data, etag: etag), storedAt: storedAt)
        contentBytes += data.count
    }

    private func removeContent(path: String) {
        if let removed = contentEntries.removeValue(forKey: path) {
            contentBytes -= removed.value.data.count
        }
    }

    private func trimMetadataIfNeeded() {
        guard metadataEntries.count > Self.maximumMetadataCount else { return }
        removeOldest(from: &metadataEntries, count: metadataEntries.count - Self.maximumMetadataCount)
    }

    private func trimDirectoriesIfNeeded() {
        guard directoryEntries.count > Self.maximumDirectoryCount else { return }
        removeOldest(from: &directoryEntries, count: directoryEntries.count - Self.maximumDirectoryCount)
    }

    private func trimContentIfNeeded() {
        guard contentBytes > Self.maximumContentBytes else { return }
        for (path, _) in contentEntries.sorted(by: { $0.value.storedAt < $1.value.storedAt }) {
            removeContent(path: path)
            if contentBytes <= Self.maximumContentBytes { break }
        }
    }

    private func removeOldest<Value: Sendable>(from entries: inout [String: Entry<Value>], count: Int) {
        for key in entries.sorted(by: { $0.value.storedAt < $1.value.storedAt }).prefix(count).map(\.key) {
            entries.removeValue(forKey: key)
        }
    }

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

actor GhostFileHTTP3Transport {
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    private let accessKey: String
    private let host: String
    private let resourceBasePath: String
    private let expectedPeerPin: GhostFilePeerPin
    private let connectionTimeout: Duration
    private let requestTimeout: Duration
    private let connection: NWConnection
    private let http3: GhostFileHTTP3Connection
    nonisolated let logID = String(UUID().uuidString.prefix(12)).lowercased()
    private let createdAt = DispatchTime.now().uptimeNanoseconds
    private var timeoutTask: Task<Void, Never>?
    private var connectionDeadlineTask: Task<Void, Never>?
    private var hasStarted = false
    private var isNetworkReady = false
    private var hasValidatedPeer = false
    private var terminalError: Error?
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var handshakeWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pending: [UInt64: PendingResponse] = [:]
    private var streamCreditWaiters: [PendingStreamCredit] = []
    private var reservedStreamCredits: UInt64 = 0
    private var isFlushing = false
    private var flushAgain = false
    private var pendingReceivedDatagrams: [Data] = []
    private var pendingScheduledDatagram: GhostFileScheduledDatagram?
    private var isReceiveDrainScheduled = false
    private var receivedDatagramCount = 0
    private var receivedByteCount = 0
    private var sentDatagramCount = 0
    private var sentByteCount = 0

    var isTerminal: Bool { terminalError != nil }

    init(
        host: String,
        port: NWEndpoint.Port,
        accessKey: String,
        peerPin: GhostFilePeerPin,
        resourceBasePath: String = "/",
        connectionTimeout: Duration = .seconds(8),
        requestTimeout: Duration = .seconds(15)
    ) throws {
        self.accessKey = accessKey
        self.host = host
        self.resourceBasePath = resourceBasePath
        self.expectedPeerPin = peerPin
        self.connectionTimeout = connectionTimeout
        self.requestTimeout = requestTimeout
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        http3 = try GhostFileHTTP3Connection(role: .client(serverName: host))
        ghostFileHTTP3Logger.notice(
            "Transport created transport=\(self.logID, privacy: .public) \(ghostFileProcessLogIdentity, privacy: .public) host=\(host, privacy: .public) port=\(port.rawValue, privacy: .public) connectionTimeout=\(String(describing: connectionTimeout), privacy: .public) requestTimeout=\(String(describing: requestTimeout), privacy: .public)"
        )
    }

    init(
        host: String,
        port: NWEndpoint.Port,
        accessKey: String,
        publicKeyPin: String,
        resourceBasePath: String = "/",
        connectionTimeout: Duration = .seconds(8),
        requestTimeout: Duration = .seconds(15)
    ) throws {
        try self.init(
            host: host,
            port: port,
            accessKey: accessKey,
            peerPin: .publicKey(publicKeyPin),
            resourceBasePath: resourceBasePath,
            connectionTimeout: connectionTimeout,
            requestTimeout: requestTimeout
        )
    }

    func request(
        requestID: String = String(UUID().uuidString.prefix(12)).lowercased(),
        operation: String,
        relativePath: String?,
        offset: UInt64?,
        length: Int?,
        method: String = "GET",
        body: Data = Data(),
        additionalHeaders: [(String, String)] = []
    ) async throws -> Response {
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
        ghostFileHTTP3Logger.info(
            "Transport request begin request=\(requestID, privacy: .public) transport=\(self.logID, privacy: .public) operation=\(operation, privacy: .public) started=\(self.hasStarted, privacy: .public) networkReady=\(self.isNetworkReady, privacy: .public) peerValidated=\(self.hasValidatedPeer, privacy: .public) pending=\(self.pending.count, privacy: .public)"
        )
        try await ensureHTTP3Ready()
        try await acquireRequestStreamCredit(requestID: requestID, operation: operation)
        do {
            try Task.checkCancellation()
            if let terminalError { throw terminalError }
        } catch {
            releaseReservedStreamCredit()
            throw error
        }
        ghostFileHTTP3Logger.info(
            "Transport request ready request=\(requestID, privacy: .public) transport=\(self.logID, privacy: .public) operation=\(operation, privacy: .public) readyMs=\(ghostFileElapsedMilliseconds(since: requestStartedAt), privacy: .public)"
        )
        var components = URLComponents()
        components.path = operationPath(operation)
        if let relativePath {
            components.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        }
        let path = components.string ?? components.path
        var headers: [(String, String)] = [
            (":method", method),
            (":scheme", "https"),
            (":authority", host),
            (":path", path),
            ("authorization", "Bearer \(accessKey)"),
            ("accept", "application/json, application/octet-stream"),
            ("x-ghostfile-request-id", requestID),
        ]
        if !body.isEmpty {
            headers.append(("content-length", String(body.count)))
            headers.append(("content-type", "application/octet-stream"))
        }
        headers.append(contentsOf: additionalHeaders)
        if let offset, let length, length > 0 {
            headers.append(("range", "bytes=\(offset)-\(offset + UInt64(length) - 1)"))
        }
        let streamID: UInt64
        do {
            streamID = try http3.sendRequest(headers: headers, body: body)
            releaseReservedStreamCredit()
        } catch {
            releaseReservedStreamCredit()
            grantAvailableStreamCredits()
            throw error
        }
        ghostFileHTTP3Logger.info(
            "HTTP/3 stream opened request=\(requestID, privacy: .public) transport=\(self.logID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(operation, privacy: .public) openMs=\(ghostFileElapsedMilliseconds(since: requestStartedAt), privacy: .public)"
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { [weak self, requestTimeout] in
                    do {
                        try await Task.sleep(for: requestTimeout)
                        guard !Task.isCancelled else { return }
                        await self?.requestDeadlineExpired(streamID: streamID)
                    } catch {}
                }
                pending[streamID] = PendingResponse(
                    requestID: requestID,
                    operation: operation,
                    startedAt: requestStartedAt,
                    continuation: continuation,
                    deadlineTask: deadlineTask
                )
                Task { await self.flushOutgoing() }
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(streamID: streamID) }
        }
    }

    private func operationPath(_ operation: String) -> String {
        // The share UUID is already part of the mount URL path. The server
        // validates it, so retain it when translating an FSKit operation.
        // `host` is intentionally not involved in HTTP routing.
        return resourceBasePath + "/" + operation
    }

    private func ensureHTTP3Ready() async throws {
        try Task.checkCancellation()
        if let terminalError { throw terminalError }
        if !hasStarted { start() }
        try await waitForNetworkReady()
        try Task.checkCancellation()
        try await waitForValidatedPeer()
    }

    private func waitForNetworkReady() async throws {
        guard !isNetworkReady else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelNetworkReadyWaiter(id: waiterID) }
        }
    }

    private func waitForValidatedPeer() async throws {
        guard !hasValidatedPeer else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handshakeWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelHandshakeWaiter(id: waiterID) }
        }
    }

    private func cancelNetworkReadyWaiter(id: UUID) {
        readyWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func cancelHandshakeWaiter(id: UUID) {
        handshakeWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func start() {
        guard !hasStarted else { return }
        hasStarted = true
        ghostFileHTTP3Logger.notice(
            "UDP connection starting transport=\(self.logID, privacy: .public) host=\(self.host, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public)"
        )
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.connectionStateChanged(state) }
        }
        connection.start(queue: DispatchQueue(label: "org.ghostvm.ghostfile.http3.client"))
        connectionDeadlineTask = Task { [weak self, connectionTimeout] in
            do {
                try await Task.sleep(for: connectionTimeout)
                guard !Task.isCancelled else { return }
                await self?.connectionDeadlineExpired()
            } catch {}
        }
        connection.batch {
            for _ in 0..<GhostFileNetworkDatagram.maximumReceiveCount {
                receiveNextDatagram()
            }
        }
    }

    private func receiveNextDatagram() {
        connection.receiveMessage { [weak self] content, _, _, error in
            Task { await self?.receiveCompleted(content, error: error) }
        }
    }

    private func receiveCompleted(_ content: Data?, error: NWError?) async {
        guard terminalError == nil else { return }
        if let error {
            fail(error)
            return
        }
        guard let content else {
            fail(TransportError.closed)
            return
        }
        receivedDatagramCount += 1
        receivedByteCount += content.count
        if receivedDatagramCount == 1 {
            ghostFileHTTP3Logger.notice(
                "First UDP datagram received transport=\(self.logID, privacy: .public) bytes=\(content.count, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
        }
        receiveNextDatagram()
        pendingReceivedDatagrams.append(content)
        guard !isReceiveDrainScheduled else { return }
        isReceiveDrainScheduled = true
        Task { [weak self] in
            await Task.yield()
            await self?.drainReceivedDatagrams()
        }
    }

    private func connectionStateChanged(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            isNetworkReady = true
            ghostFileHTTP3Logger.notice(
                "UDP connection ready transport=\(self.logID, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.values.forEach { $0.resume() }
            await flushOutgoing()
        case .failed(let error):
            fail(error)
        case .cancelled:
            fail(TransportError.closed)
        case .waiting(let error):
            ghostFileHTTP3Logger.notice(
                "UDP connection waiting transport=\(self.logID, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        default:
            break
        }
    }

    private func drainReceivedDatagrams() async {
        while !pendingReceivedDatagrams.isEmpty, terminalError == nil {
            let count = min(GhostFileNetworkDatagram.maximumReceiveCount, pendingReceivedDatagrams.count)
            let datagrams = Array(pendingReceivedDatagrams.prefix(count))
            pendingReceivedDatagrams.removeFirst(count)
            do {
                for datagram in datagrams {
                    try http3.receive(datagram)
                    if http3.isClosedOrDraining {
                        if let peerError = http3.peerConnectionError,
                           peerError.isApplication,
                           peerError.code == GhostFileHTTP3Connection.h3NoError {
                            throw TransportError.peerClosed
                        }
                        throw TransportError.closed
                    }
                }
                if http3.isEstablished && !hasValidatedPeer {
                    guard let certificate = http3.peerCertificateDER(),
                          Self.matches(certificate: certificate, expectedPin: expectedPeerPin) else {
                        throw TransportError.certificatePinMismatch
                    }
                    hasValidatedPeer = true
                    ghostFileHTTP3Logger.notice(
                        "QUIC handshake validated transport=\(self.logID, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public)"
                    )
                    connectionDeadlineTask?.cancel()
                    connectionDeadlineTask = nil
                    let waiters = handshakeWaiters
                    handshakeWaiters.removeAll()
                    waiters.values.forEach { $0.resume() }
                }
                try processEvents()
                grantAvailableStreamCredits()
                await flushOutgoing()
                resetTimeout()
            } catch {
                fail(error)
            }
        }
        isReceiveDrainScheduled = false
    }

    private func processEvents() throws {
        while let event = try http3.pollEvent() {
            switch event {
            case .headers(let streamID, let fields, _):
                guard let response = pending[streamID] else { continue }
                guard let statusValue = fields.first(where: { $0.0 == ":status" })?.1,
                      let status = Int(statusValue) else {
                    throw TransportError.invalidResponse
                }
                response.status = status
                if response.headersAt == nil {
                    response.headersAt = DispatchTime.now().uptimeNanoseconds
                    ghostFileHTTP3Logger.info(
                        "Response headers request=\(response.requestID, privacy: .public) transport=\(self.logID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(response.operation, privacy: .public) status=\(status, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: response.startedAt), privacy: .public)"
                    )
                }
                if let value = fields.first(where: { $0.0 == "content-length" })?.1,
                   let contentLength = Int(value),
                   (0...(GhostFileProtocol.maximumReadLength + 1024 * 1024)).contains(contentLength) {
                    response.body.reserveCapacity(contentLength)
                }
            case .data(let streamID):
                guard let response = pending[streamID] else { continue }
                let previousCount = response.body.count
                try http3.receiveBody(streamID: streamID, into: &response.body)
                if response.firstDataAt == nil, response.body.count > previousCount {
                    response.firstDataAt = DispatchTime.now().uptimeNanoseconds
                    ghostFileHTTP3Logger.info(
                        "Response first data request=\(response.requestID, privacy: .public) transport=\(self.logID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(response.operation, privacy: .public) bytes=\(response.body.count - previousCount, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: response.startedAt), privacy: .public)"
                    )
                }
                guard response.body.count <= GhostFileProtocol.maximumReadLength + 1024 * 1024 else {
                    throw TransportError.invalidResponse
                }
            case .finished(let streamID):
                guard let response = pending.removeValue(forKey: streamID) else { continue }
                guard let status = response.status else {
                    throw TransportError.invalidResponse
                }
                response.deadlineTask.cancel()
                ghostFileHTTP3Logger.info(
                    "Response finished request=\(response.requestID, privacy: .public) transport=\(self.logID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(response.operation, privacy: .public) status=\(status, privacy: .public) bytes=\(response.body.count, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: response.startedAt), privacy: .public)"
                )
                response.continuation.resume(returning: Response(status: status, body: response.body))
            case .reset(let streamID):
                if let response = pending.removeValue(forKey: streamID) {
                    response.deadlineTask.cancel()
                    ghostFileHTTP3Logger.error(
                        "Response reset request=\(response.requestID, privacy: .public) transport=\(self.logID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(response.operation, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: response.startedAt), privacy: .public)"
                    )
                    response.continuation.resume(throwing: TransportError.streamReset)
                }
            }
        }
    }

    private func acquireRequestStreamCredit(requestID: String, operation: String) async throws {
        if unreservedStreamCreditCount > 0 {
            reservedStreamCredits += 1
            return
        }

        let waiterID = UUID()
        ghostFileHTTP3Logger.notice(
            "HTTP/3 stream credit wait request=\(requestID, privacy: .public) transport=\(self.logID, privacy: .public) operation=\(operation, privacy: .public) waiters=\(self.streamCreditWaiters.count + 1, privacy: .public)"
        )
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { [weak self, requestTimeout] in
                    do {
                        try await Task.sleep(for: requestTimeout)
                        guard !Task.isCancelled else { return }
                        await self?.streamCreditWaiterExpired(id: waiterID)
                    } catch {}
                }
                streamCreditWaiters.append(PendingStreamCredit(
                    id: waiterID,
                    requestID: requestID,
                    operation: operation,
                    continuation: continuation,
                    deadlineTask: deadlineTask
                ))
                grantAvailableStreamCredits()
            }
        } onCancel: {
            Task { await self.cancelStreamCreditWaiter(id: waiterID) }
        }
    }

    private var unreservedStreamCreditCount: UInt64 {
        let available = http3.availableRequestStreamCount
        return available > reservedStreamCredits ? available - reservedStreamCredits : 0
    }

    private func grantAvailableStreamCredits() {
        while !streamCreditWaiters.isEmpty, unreservedStreamCreditCount > 0 {
            let waiter = streamCreditWaiters.removeFirst()
            reservedStreamCredits += 1
            waiter.deadlineTask.cancel()
            ghostFileHTTP3Logger.notice(
                "HTTP/3 stream credit granted request=\(waiter.requestID, privacy: .public) transport=\(self.logID, privacy: .public) operation=\(waiter.operation, privacy: .public) remainingWaiters=\(self.streamCreditWaiters.count, privacy: .public)"
            )
            waiter.continuation.resume()
        }
    }

    private func releaseReservedStreamCredit() {
        precondition(reservedStreamCredits > 0, "Released HTTP/3 stream credit without a reservation")
        reservedStreamCredits -= 1
    }

    private func cancelStreamCreditWaiter(id: UUID) {
        guard let index = streamCreditWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = streamCreditWaiters.remove(at: index)
        waiter.deadlineTask.cancel()
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func streamCreditWaiterExpired(id: UUID) {
        guard let index = streamCreditWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = streamCreditWaiters.remove(at: index)
        ghostFileHTTP3Logger.error(
            "HTTP/3 stream credit deadline expired request=\(waiter.requestID, privacy: .public) transport=\(self.logID, privacy: .public) operation=\(waiter.operation, privacy: .public) waiters=\(self.streamCreditWaiters.count + 1, privacy: .public)"
        )
        waiter.continuation.resume(throwing: TransportError.requestTimedOut)
    }

    private func connectionDeadlineExpired() {
        guard !hasValidatedPeer, terminalError == nil else { return }
        ghostFileHTTP3Logger.error(
            "QUIC handshake deadline expired transport=\(self.logID, privacy: .public) networkReady=\(self.isNetworkReady, privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) receivedBytes=\(self.receivedByteCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) sentBytes=\(self.sentByteCount, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public)"
        )
        fail(TransportError.connectionTimedOut)
    }

    private func requestDeadlineExpired(streamID: UInt64) async {
        guard let response = pending.removeValue(forKey: streamID), terminalError == nil else { return }
        ghostFileHTTP3Logger.error(
            "Request deadline expired request=\(response.requestID, privacy: .public) transport=\(self.logID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(response.operation, privacy: .public) status=\(String(describing: response.status), privacy: .public) bodyBytes=\(response.body.count, privacy: .public) networkReady=\(self.isNetworkReady, privacy: .public) peerValidated=\(self.hasValidatedPeer, privacy: .public) pending=\(self.pending.count + 1, privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: response.startedAt), privacy: .public)"
        )
        http3.cancelRequest(streamID: streamID)
        response.continuation.resume(throwing: TransportError.requestTimedOut)
        await flushOutgoing()
    }

    private func cancelPendingRequest(streamID: UInt64) async {
        guard let response = pending.removeValue(forKey: streamID) else { return }
        response.deadlineTask.cancel()
        ghostFileHTTP3Logger.notice(
            "Request cancelled request=\(response.requestID, privacy: .public) transport=\(self.logID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(response.operation, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: response.startedAt), privacy: .public)"
        )
        http3.cancelRequest(streamID: streamID)
        response.continuation.resume(throwing: CancellationError())
        await flushOutgoing()
    }

    private func flushOutgoing() async {
        if isFlushing {
            flushAgain = true
            return
        }
        guard isNetworkReady, terminalError == nil else { return }
        isFlushing = true
        defer { isFlushing = false }
        do {
            repeat {
                flushAgain = false
                while true {
                    let produceStartedAt = DispatchTime.now().uptimeNanoseconds
                    var datagrams: [Data] = []
                    datagrams.reserveCapacity(GhostFileNetworkDatagram.maximumSendBatchCount)
                    var transportDrained = false
                    while datagrams.count < GhostFileNetworkDatagram.maximumSendBatchCount {
                        let scheduled: GhostFileScheduledDatagram
                        if let pendingScheduledDatagram {
                            scheduled = pendingScheduledDatagram
                        } else if let next = try http3.nextScheduledDatagram() {
                            scheduled = next
                        } else {
                            transportDrained = true
                            break
                        }
                        let now = ghostFileMonotonicNanoseconds()
                        guard scheduled.sendAtNanoseconds <= now else {
                            pendingScheduledDatagram = scheduled
                            break
                        }
                        pendingScheduledDatagram = nil
                        datagrams.append(scheduled.data)
                    }
                    if datagrams.isEmpty {
                        if transportDrained { break }
                        guard let pendingScheduledDatagram else { break }
                        let now = ghostFileMonotonicNanoseconds()
                        if pendingScheduledDatagram.sendAtNanoseconds > now {
                            try await Task.sleep(
                                nanoseconds: pendingScheduledDatagram.sendAtNanoseconds - now
                            )
                        }
                        continue
                    }
                    let produceFinishedAt = DispatchTime.now().uptimeNanoseconds
                    try await connection.sendGhostFileDatagrams(datagrams)
                    let sendFinishedAt = DispatchTime.now().uptimeNanoseconds
                    sentDatagramCount += datagrams.count
                    sentByteCount += datagrams.reduce(into: 0) { $0 += $1.count }
                    http3.recordSendBatch(
                        packetCount: datagrams.count,
                        produceNanoseconds: produceFinishedAt - produceStartedAt,
                        networkNanoseconds: sendFinishedAt - produceFinishedAt
                    )
                }
            } while flushAgain
            resetTimeout()
        } catch {
            fail(error)
        }
    }

    private func resetTimeout() {
        timeoutTask?.cancel()
        guard let nanoseconds = http3.timeoutNanoseconds else { return }
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: max(1_000_000, nanoseconds))
                guard !Task.isCancelled else { return }
                await self?.timeoutFired()
            } catch {}
        }
    }

    private func timeoutFired() async {
        http3.handleTimeout()
        await flushOutgoing()
        if http3.isClosed {
            ghostFileHTTP3Logger.error(
                "QUIC timeout closed transport transport=\(self.logID, privacy: .public) pending=\(self.pending.count, privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
            fail(TransportError.closed)
        }
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        ghostFileHTTP3Logger.error(
            "Transport failed transport=\(self.logID, privacy: .public) error=\(String(describing: error), privacy: .public) networkReady=\(self.isNetworkReady, privacy: .public) peerValidated=\(self.hasValidatedPeer, privacy: .public) pending=\(self.pending.count, privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) receivedBytes=\(self.receivedByteCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) sentBytes=\(self.sentByteCount, privacy: .public) elapsedMs=\(ghostFileElapsedMilliseconds(since: self.createdAt), privacy: .public)"
        )
        terminalError = error
        readyWaiters.values.forEach { $0.resume(throwing: error) }
        handshakeWaiters.values.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
        handshakeWaiters.removeAll()
        for response in pending.values { response.continuation.resume(throwing: error) }
        pending.removeAll()
        for waiter in streamCreditWaiters {
            waiter.deadlineTask.cancel()
            waiter.continuation.resume(throwing: error)
        }
        streamCreditWaiters.removeAll()
        timeoutTask?.cancel()
        connectionDeadlineTask?.cancel()
        pendingScheduledDatagram = nil
        connection.cancel()
    }

    func invalidateForTesting() {
        fail(TransportError.closed)
    }

    private nonisolated static func matches(
        certificate: Data,
        expectedPin: GhostFilePeerPin
    ) -> Bool {
        switch expectedPin {
        case .publicKey(let expected):
            return publicKeyPin(forCertificate: certificate) == expected
        case .legacyCertificate(let expected):
            return certificatePin(for: certificate) == expected
        }
    }

    private nonisolated static func certificatePin(for bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func publicKeyPin(forCertificate bytes: Data) -> String? {
        guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let publicKeyBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        let digest = SHA256.hash(data: publicKeyBytes)
        return "p256-sha256-" + Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private final class PendingResponse {
        let requestID: String
        let operation: String
        let startedAt: UInt64
        let continuation: CheckedContinuation<Response, Error>
        let deadlineTask: Task<Void, Never>
        var status: Int?
        var body = Data()
        var headersAt: UInt64?
        var firstDataAt: UInt64?

        init(
            requestID: String,
            operation: String,
            startedAt: UInt64,
            continuation: CheckedContinuation<Response, Error>,
            deadlineTask: Task<Void, Never>
        ) {
            self.requestID = requestID
            self.operation = operation
            self.startedAt = startedAt
            self.continuation = continuation
            self.deadlineTask = deadlineTask
        }
    }

    private struct PendingStreamCredit {
        let id: UUID
        let requestID: String
        let operation: String
        let continuation: CheckedContinuation<Void, Error>
        let deadlineTask: Task<Void, Never>
    }

    enum TransportError: Error {
        case invalidResponse
        case certificatePinMismatch
        case streamReset
        case connectionTimedOut
        case requestTimedOut
        case peerClosed
        case closed
    }
}
