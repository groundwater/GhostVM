import Darwin
import Dispatch
import Foundation
import GhostHTTP
import Network

@MainActor
final class GhostFileShareServer: ObservableObject {
    typealias RequestDelay = @Sendable (GhostFileHTTPRequest) async -> Void

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var requestCount = 0

    let shareID: UUID
    let shareName: String
    let accessKey: String
    let rootURL: URL

    private let requestDelay: RequestDelay
    private var publicKeyPin = ""
    private var listener: NWListener?
    private var portTask: Task<Void, Never>?
    private var netService: NetService?
    private var identityDirectory: URL?
    private var sessions: [UUID: GhostFileHTTP3ServerSession] = [:]

    init(
        rootURL: URL,
        shareName: String,
        accessKey: String,
        shareID: UUID = UUID(),
        requestDelay: @escaping RequestDelay = { _ in }
    ) {
        self.rootURL = rootURL
        self.shareName = shareName
        self.accessKey = accessKey
        self.shareID = shareID
        self.requestDelay = requestDelay
    }

    var shareURL: URL? {
        guard port != 0 else { return nil }
        var host = ProcessInfo.processInfo.hostName
        if !host.hasSuffix(".local") { host += ".local" }
        var components = URLComponents()
        components.scheme = GhostFileProtocol.urlScheme
        components.host = host
        components.port = Int(port)
        components.path = GhostFileProtocol.shareBasePath(id: shareID)
        components.queryItems = [URLQueryItem(name: "tls_pin", value: publicKeyPin)]
        return components.url
    }

    func start(preferredPort: UInt16 = 0) throws {
        guard listener == nil else { return }
        let router = GhostFileShareRouter(
            rootURL: rootURL,
            shareID: shareID,
            shareName: shareName,
            accessKey: accessKey
        )
        let identity = try GhostFileTLSIdentity.make()
        publicKeyPin = identity.publicKeyPin
        let identityFiles = try Self.writeIdentityFiles(identity)

        let txt: [String: String] = [
            "version": String(GhostFileProtocol.version),
            "id": shareID.uuidString.lowercased(),
            "mode": "ro",
            "transport": GhostFileProtocol.transport,
            "alpn": GhostFileProtocol.alpn,
            "auth": "access-key",
            "tls-pin": publicKeyPin,
        ]
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        let requestedPort = NWEndpoint.Port(rawValue: preferredPort) ?? .any

        do {
            let listener = try NWListener(using: parameters, on: requestedPort)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(
                        connection,
                        router: router,
                        certificatePath: identityFiles.certificate.path,
                        privateKeyPath: identityFiles.privateKey.path
                    )
                }
            }
            self.identityDirectory = identityFiles.directory
            self.listener = listener
            listener.start(queue: DispatchQueue(label: "org.ghostvm.ghostfile.http3.listener"))
            port = listener.port?.rawValue ?? 0
            isRunning = port != 0
            portTask = Task { [weak self, weak listener] in
                for _ in 0..<500 {
                    guard let self, let listener else { return }
                    if let boundPort = listener.port?.rawValue {
                        self.port = boundPort
                        self.isRunning = true
                        self.publishBonjour(port: boundPort, values: txt)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: identityFiles.directory)
            throw error
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        netService?.stop()
        netService = nil
        portTask?.cancel()
        portTask = nil
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        if let identityDirectory { try? FileManager.default.removeItem(at: identityDirectory) }
        identityDirectory = nil
        port = 0
        isRunning = false
    }

    private func accept(
        _ connection: NWConnection,
        router: GhostFileShareRouter,
        certificatePath: String,
        privateKeyPath: String
    ) {
        let id = UUID()
        do {
            let session = try GhostFileHTTP3ServerSession(
                connection: connection,
                certificatePath: certificatePath,
                privateKeyPath: privateKeyPath,
                router: router,
                requestDelay: requestDelay,
                requestCompleted: { [weak self] in
                    Task { @MainActor in self?.requestCount += 1 }
                },
                stopped: { [weak self] in
                    Task { @MainActor in self?.sessions.removeValue(forKey: id) }
                }
            )
            sessions[id] = session
            session.start()
        } catch {
            NSLog("GhostFile HTTP/3 session setup failed: %@", String(describing: error))
            connection.cancel()
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            isRunning = port != 0
            if port != 0 {
                publishBonjour(port: port, values: [
                    "version": String(GhostFileProtocol.version),
                    "id": shareID.uuidString.lowercased(),
                    "mode": "ro",
                    "transport": GhostFileProtocol.transport,
                    "alpn": GhostFileProtocol.alpn,
                    "auth": "access-key",
                    "tls-pin": publicKeyPin,
                ])
            }
        case .failed(let error):
#if DEBUG
            print("GhostFile HTTP/3 listener failed: \(error)")
#endif
            stop()
        case .cancelled:
            port = 0
            isRunning = false
        case .waiting(let error):
#if DEBUG
            print("GhostFile HTTP/3 listener waiting: \(error)")
#endif
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func publishBonjour(port: UInt16, values: [String: String]) {
        guard netService == nil else { return }
        let service = NetService(
            domain: GhostFileProtocol.bonjourDomain,
            type: GhostFileProtocol.bonjourType,
            name: shareName,
            port: Int32(port)
        )
        service.includesPeerToPeer = true
        let dataValues = values.mapValues { Data($0.utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: dataValues))
        netService = service
        service.publish()
    }

    private static func writeIdentityFiles(
        _ identity: GhostFileTLSIdentity
    ) throws -> (directory: URL, certificate: URL, privateKey: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostFileHTTP3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let certificate = directory.appendingPathComponent("certificate.pem")
            let privateKey = directory.appendingPathComponent("private-key.pem")
            try Data(identity.certificatePEM.utf8).write(to: certificate, options: .atomic)
            try Data(identity.privateKeyPEM.utf8).write(to: privateKey, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: certificate.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
            return (directory, certificate, privateKey)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

private actor GhostFileHTTP3ServerSession {
    typealias RequestDelay = GhostFileShareServer.RequestDelay

    private let connection: NWConnection
    private let http3: GhostFileHTTP3Connection
    private let router: GhostFileShareRouter
    private let requestDelay: RequestDelay
    private let requestCompleted: @Sendable () -> Void
    private let stopped: @Sendable () -> Void
    private var timeoutTask: Task<Void, Never>?
    private var isFlushing = false
    private var flushAgain = false
    private var hasStopped = false
    private var responseTasks: [UInt64: Task<Void, Never>] = [:]
    private var terminatedRequestStreams: Set<UInt64> = []
    private var pendingReceivedDatagrams: [Data] = []
    private var isReceiveDrainScheduled = false

    // GhostFile range requests are capped at 1 MiB. One DispatchIO operation per
    // bounded range avoids re-entering the connection actor for artificial file
    // chunks while independent HTTP/3 streams still read concurrently.
    private static let fileReadChunkSize = GhostFileProtocol.maximumReadLength
    private static let routingQueue = DispatchQueue(
        label: "org.ghostvm.ghostfile.http3.routing",
        qos: .userInitiated,
        attributes: .concurrent
    )

    init(
        connection: NWConnection,
        certificatePath: String,
        privateKeyPath: String,
        router: GhostFileShareRouter,
        requestDelay: @escaping RequestDelay,
        requestCompleted: @escaping @Sendable () -> Void,
        stopped: @escaping @Sendable () -> Void
    ) throws {
        self.connection = connection
        self.http3 = try GhostFileHTTP3Connection(
            role: .server(certificatePath: certificatePath, privateKeyPath: privateKeyPath)
        )
        self.router = router
        self.requestDelay = requestDelay
        self.requestCompleted = requestCompleted
        self.stopped = stopped
    }

    nonisolated func start() {
        Task { await startIsolated() }
    }

    nonisolated func stop() {
        Task { await stopIsolated() }
    }

    private func startIsolated() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
#if DEBUG
                print("GhostFile HTTP/3 UDP connection failed: \(error)")
#endif
                Task { await self?.stopIsolated() }
            } else if case .cancelled = state {
                Task { await self?.stopIsolated() }
            }
        }
        connection.start(queue: DispatchQueue(label: "org.ghostvm.ghostfile.http3.session"))
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
        guard !hasStopped else { return }
        guard error == nil, let content else {
            stopIsolated()
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

    private func drainReceivedDatagrams() async {
        while !pendingReceivedDatagrams.isEmpty, !hasStopped {
            let count = min(GhostFileNetworkDatagram.maximumReceiveCount, pendingReceivedDatagrams.count)
            let datagrams = Array(pendingReceivedDatagrams.prefix(count))
            pendingReceivedDatagrams.removeFirst(count)
            do {
                for datagram in datagrams {
                    try http3.receive(datagram)
                }
                drainPeerTerminatedResponses()
                try processEvents()
                drainPeerTerminatedResponses()
                await flushOutgoing()
                resetTimeout()
            } catch {
                NSLog("GhostFile HTTP/3 datagram batch failed: %@", String(describing: error))
                stopIsolated()
            }
        }
        isReceiveDrainScheduled = false
    }

    private func processEvents() throws {
        while let event = try http3.pollEvent() {
            switch event {
            case .headers(let streamID, let fields, _):
                guard let request = Self.httpRequest(fields: fields),
                      let context = Self.requestContext(request) else {
                    Task { await self.sendBadRequest(streamID: streamID) }
                    continue
                }
                let router = self.router
                let delay = self.requestDelay
                Task { [weak self] in
                    await delay(context)
                    let response = await Self.route(request, using: router)
                    await self?.send(response, streamID: streamID)
                }
            case .data(let streamID):
                _ = try http3.receiveBody(streamID: streamID)
            case .reset(let streamID):
                terminatedRequestStreams.insert(streamID)
                cancelResponse(streamID: streamID)
            case .finished:
                break
            }
        }
    }

    private func sendBadRequest(streamID: UInt64) async {
        let body = Data("Malformed HTTP/3 request".utf8)
        do {
            try http3.sendResponse(
                streamID: streamID,
                headers: [(":status", "400"), ("content-length", String(body.count))],
                body: body
            )
            await flushOutgoing()
        } catch { stopIsolated() }
    }

    private func send(_ response: GhostFileHTTPResponse, streamID: UInt64) async {
        guard !hasStopped else { return }
        guard terminatedRequestStreams.remove(streamID) == nil else { return }
        do {
            var headers: [(String, String)] = [
                (":status", String(response.status.rawValue)),
                ("content-length", String(response.body.contentLength)),
            ]
            headers.append(contentsOf: response.headers.all.compactMap { entry in
                let name = entry.name.lowercased()
                guard name != "content-length", !name.hasPrefix(":") else { return nil }
                return (name, entry.value)
            })

            switch response.body {
            case .empty:
                try http3.sendResponse(streamID: streamID, headers: headers, body: Data())
            case .bytes(let body):
                try http3.sendResponse(streamID: streamID, headers: headers, body: body)
            case .fileRegion(let path, let identity, let offset, let length):
                try http3.beginResponse(
                    streamID: streamID,
                    headers: headers,
                    contentLength: length
                )
                startFileResponse(
                    path: path,
                    identity: identity,
                    offset: offset,
                    length: length,
                    streamID: streamID
                )
            }
            requestCompleted()
            await flushOutgoing()
        } catch {
            NSLog("GhostFile HTTP/3 response failed: %@", String(describing: error))
            stopIsolated()
        }
    }

    private func flushOutgoing() async {
        if isFlushing {
            flushAgain = true
            return
        }
        guard !hasStopped else { return }
        isFlushing = true
        defer { isFlushing = false }
        do {
            repeat {
                flushAgain = false
                while true {
                    let produceStartedAt = DispatchTime.now().uptimeNanoseconds
                    var datagrams: [Data] = []
                    datagrams.reserveCapacity(GhostFileNetworkDatagram.maximumSendBatchCount)
                    while datagrams.count < GhostFileNetworkDatagram.maximumSendBatchCount {
                        guard let datagram = try http3.nextDatagram() else { break }
                        datagrams.append(datagram)
                        drainPeerTerminatedResponses()
                    }
                    drainPeerTerminatedResponses()
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
            NSLog("GhostFile HTTP/3 UDP send failed: %@", String(describing: error))
            stopIsolated()
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
        if http3.isClosed { stopIsolated() }
    }

    private func stopIsolated() {
        guard !hasStopped else { return }
        hasStopped = true
        timeoutTask?.cancel()
        for task in responseTasks.values { task.cancel() }
        responseTasks.removeAll()
        connection.cancel()
        stopped()
    }

    private nonisolated static func httpRequest(fields: [(String, String)]) -> HTTPRequestHead? {
        guard let methodValue = fields.first(where: { $0.0 == ":method" })?.1,
              let method = HTTPMethod(rawValue: methodValue),
              let path = fields.first(where: { $0.0 == ":path" })?.1,
              fields.first(where: { $0.0 == ":scheme" })?.1 == "https" else {
            return nil
        }
        let headers = HTTPHeaders(fields.compactMap { name, value in
            guard !name.hasPrefix(":") else { return nil }
            return HTTPHeaders.Entry(name: name, value: value)
        })
        return HTTPRequestHead(method: method, path: path, headers: headers)
    }

    private nonisolated static func requestContext(_ request: HTTPRequestHead) -> GhostFileHTTPRequest? {
        guard let components = URLComponents(string: "https://ghostfile.local\(request.path)") else { return nil }
        let operation = components.path.split(separator: "/").last.map(String.init) ?? ""
        let path = components.queryItems?.first(where: { $0.name == "path" })?.value
        var offset: UInt64?
        var length: Int?
        if let range = request.header("range"), range.hasPrefix("bytes=") {
            let pieces = range.dropFirst(6).split(separator: "-", maxSplits: 1)
            if pieces.count == 2, let start = UInt64(pieces[0]), let end = UInt64(pieces[1]), end >= start {
                offset = start
                length = Int(end - start + 1)
            }
        }
        return GhostFileHTTPRequest(operation: operation, path: path, offset: offset, length: length)
    }

    private nonisolated static func route(
        _ request: HTTPRequestHead,
        using router: GhostFileShareRouter
    ) async -> GhostFileHTTPResponse {
        await withCheckedContinuation { continuation in
            routingQueue.async {
                continuation.resume(returning: router.route(request))
            }
        }
    }

    private func startFileResponse(
        path: String,
        identity: String,
        offset: UInt64,
        length: Int,
        streamID: UInt64
    ) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Self.produceFileResponse(
                    path: path,
                    identity: identity,
                    offset: offset,
                    length: length,
                    sendChunk: { [weak self] data, isFinal in
                        guard let self else { throw CancellationError() }
                        try await self.sendFileChunk(data, isFinal: isFinal, streamID: streamID)
                    }
                )
                await self.fileResponseFinished(streamID: streamID)
            } catch is CancellationError {
                await self.cancelResponse(streamID: streamID)
            } catch {
                await self.fileResponseFailed(error, streamID: streamID)
            }
        }
        responseTasks[streamID] = task
    }

    private nonisolated static func produceFileResponse(
        path: String,
        identity: String,
        offset: UInt64,
        length: Int,
        sendChunk: @escaping @Sendable (Data, Bool) async throws -> Void
    ) async throws {
        guard offset <= UInt64(Int64.max) else { throw POSIXError(.EOVERFLOW) }
        let file = try await GhostFileDispatchIOFile.cached(path: path, identity: identity)

        var currentOffset = offset
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            let requestedLength = min(remaining, fileReadChunkSize)
            let data = try await file.read(offset: currentOffset, length: requestedLength)
            try Task.checkCancellation()
            guard data.count == requestedLength else { throw POSIXError(.EIO) }
            currentOffset += UInt64(data.count)
            remaining -= data.count
            try await sendChunk(data, remaining == 0)
        }
    }

    private func sendFileChunk(_ data: Data, isFinal: Bool, streamID: UInt64) async throws {
        guard !hasStopped, responseTasks[streamID] != nil else { throw CancellationError() }
        try http3.appendResponseBody(streamID: streamID, data: data, isFinal: isFinal)
        await flushOutgoing()
        guard !hasStopped, responseTasks[streamID] != nil else { throw CancellationError() }
    }

    private func fileResponseFinished(streamID: UInt64) {
        responseTasks.removeValue(forKey: streamID)
    }

    private func fileResponseFailed(_ error: Error, streamID: UInt64) async {
        NSLog("GhostFile DispatchIO response failed on stream %llu: %@", streamID, String(describing: error))
        cancelResponse(streamID: streamID, resetTransport: true)
        await flushOutgoing()
    }

    private func cancelResponse(streamID: UInt64, resetTransport: Bool = false) {
        responseTasks.removeValue(forKey: streamID)?.cancel()
        if resetTransport {
            http3.resetResponse(streamID: streamID)
        } else {
            http3.abandonResponse(streamID: streamID)
        }
    }

    private func drainPeerTerminatedResponses() {
        for streamID in http3.takePeerTerminatedResponseStreamIDs() {
            terminatedRequestStreams.insert(streamID)
            cancelResponse(streamID: streamID)
        }
        for streamID in http3.takeFailedResponseStreamIDs() {
            terminatedRequestStreams.insert(streamID)
            cancelResponse(streamID: streamID, resetTransport: true)
        }
    }

}

private final class GhostFileDispatchIOFile: @unchecked Sendable {
    private static let callbackQueue = DispatchQueue(
        label: "org.ghostvm.ghostfile.dispatch-io",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let cacheMissQueue = DispatchQueue(
        label: "org.ghostvm.ghostfile.dispatch-io.cache",
        qos: .userInitiated
    )
    private static let cache: NSCache<NSString, GhostFileDispatchIOFile> = {
        let cache = NSCache<NSString, GhostFileDispatchIOFile>()
        cache.countLimit = 128
        return cache
    }()

    private let channel: DispatchIO
    private let cacheKey: NSString

    static func cached(path: String, identity: String) async throws -> GhostFileDispatchIOFile {
        let cacheKey = path + "\0" + identity
        if let cached = cache.object(forKey: cacheKey as NSString) { return cached }
        return try await withCheckedThrowingContinuation { continuation in
            cacheMissQueue.async {
                let key = cacheKey as NSString
                if let cached = cache.object(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }
                do {
                    let file = try GhostFileDispatchIOFile(path: path, cacheKey: key)
                    cache.setObject(file, forKey: key)
                    continuation.resume(returning: file)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    init(path: String, cacheKey: NSString) throws {
        guard let channel = path.withCString({ pathPointer in
            DispatchIO(
                type: .random,
                path: pathPointer,
                oflag: O_RDONLY,
                mode: 0,
                queue: Self.callbackQueue,
                cleanupHandler: { _ in }
            )
        }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.channel = channel
        self.cacheKey = cacheKey
    }

    func read(offset: UInt64, length: Int) async throws -> Data {
        guard offset <= UInt64(Int64.max), length >= 0 else { throw POSIXError(.EOVERFLOW) }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let operation = GhostFileDispatchIOReadOperation(
                    expectedLength: length,
                    continuation: continuation
                )
                channel.read(
                    offset: off_t(offset),
                    length: length,
                    queue: Self.callbackQueue,
                    ioHandler: operation.receive(done:data:error:)
                )
            }
        } catch {
            if Self.cache.object(forKey: cacheKey) === self {
                Self.cache.removeObject(forKey: cacheKey)
            }
            throw error
        }
    }

    deinit { channel.close(flags: .stop) }
}

private final class GhostFileDispatchIOReadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedLength: Int
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Error>?

    init(expectedLength: Int, continuation: CheckedContinuation<Data, Error>) {
        self.expectedLength = expectedLength
        self.continuation = continuation
        data.reserveCapacity(expectedLength)
    }

    func receive(done: Bool, data dispatchData: DispatchData?, error: Int32) {
        let chunk = dispatchData.map { Data($0) } ?? Data()
        var completion: CheckedContinuation<Data, Error>?
        var result: Result<Data, Error>?

        lock.lock()
        if continuation != nil {
            if error != 0 {
                completion = continuation
                continuation = nil
                result = .failure(POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
            } else {
                if done {
                    completion = continuation
                    continuation = nil
                    if data.isEmpty, chunk.count == expectedLength {
                        result = .success(chunk)
                    } else {
                        data.append(chunk)
                        result = data.count == expectedLength ? .success(data) : .failure(POSIXError(.EIO))
                    }
                } else {
                    data.append(chunk)
                }
            }
        }
        lock.unlock()

        if let completion, let result { completion.resume(with: result) }
    }
}
