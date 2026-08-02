import CryptoKit
import Dispatch
import Foundation
import FSKit
import GhostHTTP3
import Network

struct GhostFileHTTP3Client: Sendable {
    private let transport: GhostFileHTTP3Transport
    private let cache = GhostFileResponseCache()

    init(resourceURL: URL) throws {
        guard resourceURL.scheme == GhostFileProtocol.urlScheme,
              let host = resourceURL.host,
              let portNumber = resourceURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let components = URLComponents(url: resourceURL, resolvingAgainstBaseURL: false),
              let accessKey = components.queryItems?.first(where: { $0.name == "access_key" })?.value,
              !accessKey.isEmpty,
              let publicKeyPin = components.queryItems?.first(where: { $0.name == "tls_pin" })?.value,
              !publicKeyPin.isEmpty else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        transport = try GhostFileHTTP3Transport(
            host: host,
            port: port,
            accessKey: accessKey,
            publicKeyPin: publicKeyPin,
            resourceBasePath: resourceURL.path
        )
    }

    func capabilities() async throws -> GhostFileCapabilities {
        try await decode(GhostFileCapabilities.self, operation: "capabilities", relativePath: nil)
    }

    func metadata(path: String) async throws -> GhostFileMetadata {
        if let cached = await cache.metadata(path: path) { return cached }
        let metadata = try await decode(GhostFileMetadata.self, operation: "metadata", relativePath: path)
        await cache.store(metadata: metadata, path: path)
        return metadata
    }

    func directory(path: String) async throws -> GhostFileDirectoryListing {
        if let cached = await cache.directory(path: path) { return cached }
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
            return cached
        }
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

    private func request(
        operation: String,
        relativePath: String?,
        offset: UInt64? = nil,
        length: Int? = nil
    ) async throws -> Data {
        let response: GhostFileHTTP3Transport.Response
        do {
            response = try await transport.request(
                operation: operation,
                relativePath: relativePath,
                offset: offset,
                length: length
            )
        } catch {
            NSLog("GhostFile HTTP/3 request failed: %@", String(describing: error))
            throw fs_errorForPOSIXError(ENOTCONN)
        }
        switch response.status {
        case 200, 206:
            return response.body
        case 400, 416:
            throw fs_errorForPOSIXError(EINVAL)
        case 401, 403:
            throw fs_errorForPOSIXError(EACCES)
        case 404:
            throw fs_errorForPOSIXError(ENOENT)
        case 502, 503, 504:
            throw fs_errorForPOSIXError(ENOTCONN)
        default:
            throw fs_errorForPOSIXError(EIO)
        }
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

    private static let metadataLifetime: UInt64 = 5_000_000_000
    private static let directoryLifetime: UInt64 = 5_000_000_000
    private static let contentLifetime: UInt64 = 5_000_000_000
    private static let maximumMetadataCount = 32_768
    private static let maximumDirectoryCount = 2_048
    private static let maximumContentBytes = 64 * 1024 * 1024

    private var metadataEntries: [String: Entry<GhostFileMetadata>] = [:]
    private var directoryEntries: [String: Entry<GhostFileDirectoryListing>] = [:]
    private var contentEntries: [String: Entry<CachedContent>] = [:]
    private var contentBytes = 0

    func metadata(path: String) -> GhostFileMetadata? {
        fresh(metadataEntries[path], lifetime: Self.metadataLifetime)?.value
    }

    func directory(path: String) -> GhostFileDirectoryListing? {
        fresh(directoryEntries[path], lifetime: Self.directoryLifetime)?.value
    }

    func content(path: String, offset: UInt64, length: Int) -> Data? {
        guard let entry = fresh(contentEntries[path], lifetime: Self.contentLifetime) else {
            removeContent(path: path)
            return nil
        }
        if let metadata = fresh(metadataEntries[path], lifetime: Self.metadataLifetime)?.value,
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
              let metadata = fresh(metadataEntries[path], lifetime: Self.metadataLifetime)?.value,
              metadata.size == UInt64(data.count) else { return }
        storeContent(data, etag: metadata.etag, path: path, storedAt: Self.now)
        trimContentIfNeeded()
    }

    private func fresh<Value: Sendable>(_ entry: Entry<Value>?, lifetime: UInt64) -> Entry<Value>? {
        guard let entry, Self.now &- entry.storedAt <= lifetime else { return nil }
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
    private let expectedCertificatePin: String
    private let connection: NWConnection
    private let http3: GhostFileHTTP3Connection
    private var timeoutTask: Task<Void, Never>?
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
    private var isReceiveDrainScheduled = false

    init(
        host: String,
        port: NWEndpoint.Port,
        accessKey: String,
        publicKeyPin: String,
        resourceBasePath: String = "/"
    ) throws {
        self.accessKey = accessKey
        self.host = host
        self.resourceBasePath = resourceBasePath
        self.expectedCertificatePin = publicKeyPin
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        http3 = try GhostFileHTTP3Connection(role: .client(serverName: host))
    }

    func request(
        operation: String,
        relativePath: String?,
        offset: UInt64?,
        length: Int?
    ) async throws -> Response {
        try await ensureHTTP3Ready()
        try await acquireRequestStreamCredit()
        do {
            try Task.checkCancellation()
            if let terminalError { throw terminalError }
        } catch {
            releaseReservedStreamCredit()
            throw error
        }
        var components = URLComponents()
        components.path = operationPath(operation)
        if let relativePath {
            components.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        }
        let path = components.string ?? components.path
        var headers: [(String, String)] = [
            (":method", "GET"),
            (":scheme", "https"),
            (":authority", host),
            (":path", path),
            ("authorization", "Bearer \(accessKey)"),
            ("accept", "application/json, application/octet-stream"),
        ]
        if let offset, let length, length > 0 {
            headers.append(("range", "bytes=\(offset)-\(offset + UInt64(length) - 1)"))
        }
        let streamID: UInt64
        do {
            streamID = try http3.sendRequest(headers: headers)
            releaseReservedStreamCredit()
        } catch {
            releaseReservedStreamCredit()
            grantAvailableStreamCredits()
            throw error
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[streamID] = PendingResponse(continuation: continuation)
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
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.connectionStateChanged(state) }
        }
        connection.start(queue: DispatchQueue(label: "org.ghostvm.ghostfile.http3.client"))
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
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.values.forEach { $0.resume() }
            await flushOutgoing()
        case .failed(let error):
            fail(error)
        case .cancelled:
            fail(TransportError.closed)
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
                }
                if http3.isEstablished && !hasValidatedPeer {
                    guard let certificate = http3.peerCertificateDER(),
                          Self.pin(for: certificate) == expectedCertificatePin else {
                        throw TransportError.certificatePinMismatch
                    }
                    hasValidatedPeer = true
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
                guard var response = pending[streamID],
                      let statusValue = fields.first(where: { $0.0 == ":status" })?.1,
                      let status = Int(statusValue) else {
                    throw TransportError.invalidResponse
                }
                response.status = status
                pending[streamID] = response
            case .data(let streamID):
                guard var response = pending[streamID] else { continue }
                response.body.append(try http3.receiveBody(streamID: streamID))
                guard response.body.count <= GhostFileProtocol.maximumReadLength + 1024 * 1024 else {
                    throw TransportError.invalidResponse
                }
                pending[streamID] = response
            case .finished(let streamID):
                guard let response = pending.removeValue(forKey: streamID),
                      let status = response.status else {
                    throw TransportError.invalidResponse
                }
                response.continuation.resume(returning: Response(status: status, body: response.body))
            case .reset(let streamID):
                pending.removeValue(forKey: streamID)?.continuation.resume(throwing: TransportError.streamReset)
            }
        }
    }

    private func acquireRequestStreamCredit() async throws {
        if unreservedStreamCreditCount > 0 {
            reservedStreamCredits += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadlineTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled else { return }
                        await self?.streamCreditWaiterExpired(id: waiterID)
                    } catch {}
                }
                streamCreditWaiters.append(PendingStreamCredit(
                    id: waiterID,
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
        waiter.continuation.resume(throwing: TransportError.streamCreditTimedOut)
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
                    while datagrams.count < GhostFileNetworkDatagram.maximumSendBatchCount,
                          let datagram = try http3.nextDatagram() {
                        datagrams.append(datagram)
                    }
                    guard !datagrams.isEmpty else { break }
                    let produceFinishedAt = DispatchTime.now().uptimeNanoseconds
                    try await connection.sendGhostFileDatagrams(datagrams)
                    let sendFinishedAt = DispatchTime.now().uptimeNanoseconds
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
        if http3.isClosed { fail(TransportError.closed) }
    }

    private func cancelPendingRequest(streamID: UInt64) async {
        guard let response = pending.removeValue(forKey: streamID) else { return }
        http3.cancelRequest(streamID: streamID)
        response.continuation.resume(throwing: CancellationError())
        await flushOutgoing()
    }

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        NSLog("GhostFile HTTP/3 transport failed: %@", String(describing: error))
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
        connection.cancel()
    }

    func invalidateForTesting() {
        fail(TransportError.closed)
    }

    private nonisolated static func pin(for bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct PendingResponse {
        let continuation: CheckedContinuation<Response, Error>
        var status: Int?
        var body = Data()
    }

    private struct PendingStreamCredit {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let deadlineTask: Task<Void, Never>
    }

    private enum TransportError: Error {
        case invalidResponse
        case certificatePinMismatch
        case streamReset
        case streamCreditTimedOut
        case closed
    }
}
