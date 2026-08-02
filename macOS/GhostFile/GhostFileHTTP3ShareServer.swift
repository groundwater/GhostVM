import Darwin
import Dispatch
import Foundation
import GhostHTTP
import Network
import OSLog

private let ghostFileHTTP3ServerLogger = Logger(
    subsystem: "org.ghostvm.ghostfile",
    category: "HTTP3Server"
)

private let ghostFileServerProcessLogIdentity: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    return "version=\(version) build=\(build) pid=\(ProcessInfo.processInfo.processIdentifier)"
}()

private func ghostFileServerElapsedMilliseconds(since startedAt: UInt64) -> UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    return now >= startedAt ? (now - startedAt) / 1_000_000 : 0
}

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
    private var heartbeatTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var netService: NetService?
    private var bonjourResolver: GhostFileBonjourSelfResolver?
    @Published private var resolvedShareHost: String?
    private var identityDirectory: URL?
    private var sessions: [UUID: GhostFileHTTP3ServerSession] = [:]
    private var bonjourValues: [String: String] = [:]
    private var bonjourHeartbeat: UInt64 = 0
    private var isStopping = false

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
        guard port != 0, let host = resolvedShareHost else { return nil }
        return resourceURL(host: host)
    }

#if DEBUG
    var loopbackShareURLForTesting: URL? {
        guard port != 0 else { return nil }
        return resourceURL(host: "127.0.0.1")
    }
#endif

    private func resourceURL(host: String) -> URL? {
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
        ghostFileHTTP3ServerLogger.notice(
            "Share listener starting share=\(self.shareID.uuidString.lowercased(), privacy: .public) \(ghostFileServerProcessLogIdentity, privacy: .public) preferredPort=\(preferredPort, privacy: .public) name=\(self.shareName, privacy: .private(mask: .hash)) root=\(self.rootURL.path, privacy: .private(mask: .hash))"
        )
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
            "state": "ready",
            "ttl": String(Int(GhostFileBonjourLease.advertisedTTL)),
        ]
        bonjourValues = txt
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
                    // NWListener can transiently report `.any` (raw value 0)
                    // before the kernel assigns its real ephemeral port. Never
                    // publish that placeholder: `publishBonjour` is one-shot,
                    // so doing so would permanently advertise an unusable SRV
                    // endpoint for this share instance.
                    if let boundPort = listener.port?.rawValue, boundPort != 0 {
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
        guard listener != nil else {
            finishStop()
            return
        }
        guard !isStopping else { return }
        isStopping = true
        ghostFileHTTP3ServerLogger.notice(
            "Share stop requested share=\(self.shareID.uuidString.lowercased(), privacy: .public) port=\(self.port, privacy: .public) sessions=\(self.sessions.count, privacy: .public) requests=\(self.requestCount, privacy: .public)"
        )
        isRunning = false
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Tell mount clients to detach before closing their backing transport.
        // This prevents a forced unmount from waiting on an already-dead share.
        if let netService {
            var stoppingValues = bonjourValues
            stoppingValues["state"] = "stopping"
            let dataValues = stoppingValues.mapValues { Data($0.utf8) }
            netService.setTXTRecord(NetService.data(fromTXTRecord: dataValues))
            stopTask = Task { [self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                finishStop()
            }
        } else {
            finishStop()
        }
    }

    private func finishStop() {
        ghostFileHTTP3ServerLogger.notice(
            "Share stopping share=\(self.shareID.uuidString.lowercased(), privacy: .public) port=\(self.port, privacy: .public) sessions=\(self.sessions.count, privacy: .public) requests=\(self.requestCount, privacy: .public)"
        )
        stopTask?.cancel()
        stopTask = nil
        listener?.cancel()
        listener = nil
        netService?.stop()
        netService = nil
        bonjourResolver?.stop()
        bonjourResolver = nil
        resolvedShareHost = nil
        portTask?.cancel()
        portTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        if let identityDirectory { try? FileManager.default.removeItem(at: identityDirectory) }
        identityDirectory = nil
        bonjourValues = [:]
        bonjourHeartbeat = 0
        port = 0
        isRunning = false
        isStopping = false
    }

    private func accept(
        _ connection: NWConnection,
        router: GhostFileShareRouter,
        certificatePath: String,
        privateKeyPath: String
    ) {
        let id = UUID()
        let sessionID = String(id.uuidString.prefix(12)).lowercased()
        do {
            let session = try GhostFileHTTP3ServerSession(
                sessionID: sessionID,
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
            ghostFileHTTP3ServerLogger.notice(
                "Session accepted share=\(self.shareID.uuidString.lowercased(), privacy: .public) session=\(sessionID, privacy: .public) endpoint=\(String(describing: connection.endpoint), privacy: .public) activeSessions=\(self.sessions.count, privacy: .public)"
            )
            session.start()
        } catch {
            ghostFileHTTP3ServerLogger.error(
                "Session setup failed share=\(self.shareID.uuidString.lowercased(), privacy: .public) session=\(sessionID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            connection.cancel()
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue ?? 0
            isRunning = port != 0
            if port != 0 {
                ghostFileHTTP3ServerLogger.notice(
                    "Share listener ready share=\(self.shareID.uuidString.lowercased(), privacy: .public) port=\(self.port, privacy: .public)"
                )
                publishBonjour(port: port, values: [
                    "version": String(GhostFileProtocol.version),
                    "id": shareID.uuidString.lowercased(),
                    "mode": "ro",
                    "transport": GhostFileProtocol.transport,
                    "alpn": GhostFileProtocol.alpn,
                    "auth": "access-key",
                    "tls-pin": publicKeyPin,
                    "state": "ready",
                    "ttl": String(Int(GhostFileBonjourLease.advertisedTTL)),
                ])
            }
        case .failed(let error):
            ghostFileHTTP3ServerLogger.error(
                "Share listener failed share=\(self.shareID.uuidString.lowercased(), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            finishStop()
        case .cancelled:
            ghostFileHTTP3ServerLogger.notice(
                "Share listener cancelled share=\(self.shareID.uuidString.lowercased(), privacy: .public)"
            )
            port = 0
            isRunning = false
        case .waiting(let error):
            ghostFileHTTP3ServerLogger.notice(
                "Share listener waiting share=\(self.shareID.uuidString.lowercased(), privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func publishBonjour(port: UInt16, values: [String: String]) {
        guard netService == nil else { return }
        guard port != 0 else {
            ghostFileHTTP3ServerLogger.error(
                "Refusing Bonjour publication with zero port share=\(self.shareID.uuidString.lowercased(), privacy: .public)"
            )
            return
        }
        ghostFileHTTP3ServerLogger.notice(
            "Bonjour publish starting share=\(self.shareID.uuidString.lowercased(), privacy: .public) port=\(port, privacy: .public) ttl=\(values["ttl"] ?? "unknown", privacy: .public)"
        )
        bonjourValues = values
        bonjourHeartbeat = 0
        let service = NetService(
            domain: GhostFileProtocol.bonjourDomain,
            type: GhostFileProtocol.bonjourType,
            name: shareName,
            port: Int32(port)
        )
        service.includesPeerToPeer = true
        var initialValues = values
        initialValues["heartbeat"] = String(bonjourHeartbeat)
        let dataValues = initialValues.mapValues { Data($0.utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: dataValues))
        netService = service
        let resolver = GhostFileBonjourSelfResolver { [weak self, weak service] host in
            Task { @MainActor in
                guard let self, let service, self.netService === service else { return }
                self.resolvedShareHost = host
                ghostFileHTTP3ServerLogger.notice(
                    "Bonjour self-resolution ready share=\(self.shareID.uuidString.lowercased(), privacy: .public) host=\(host, privacy: .public) port=\(self.port, privacy: .public)"
                )
            }
        }
        bonjourResolver = resolver
        resolver.publish(service)
        heartbeatTask = Task { [weak self, weak service] in
            while !Task.isCancelled {
                try? await Task.sleep(for: GhostFileBonjourLease.heartbeatInterval)
                guard !Task.isCancelled, let self, let service else { return }
                guard self.netService === service, self.isRunning, !self.isStopping else { return }
                self.bonjourHeartbeat &+= 1
                var heartbeatValues = self.bonjourValues
                heartbeatValues["heartbeat"] = String(self.bonjourHeartbeat)
                let dataValues = heartbeatValues.mapValues { Data($0.utf8) }
                service.setTXTRecord(NetService.data(fromTXTRecord: dataValues))
            }
        }
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

    private struct RequestLogContext {
        let requestID: String
        let operation: String
        let startedAt: UInt64
    }

    private let sessionID: String
    private let connection: NWConnection
    private let http3: GhostFileHTTP3Connection
    private let router: GhostFileShareRouter
    private let requestDelay: RequestDelay
    private let requestCompleted: @Sendable () -> Void
    private let stopped: @Sendable () -> Void
    private var timeoutTask: Task<Void, Never>?
    private var isFlushing = false
    private var flushAgain = false
    private var isStopping = false
    private var hasStopped = false
    private var routingTasks: [UInt64: Task<Void, Never>] = [:]
    private var responseTasks: [UInt64: Task<Void, Never>] = [:]
    private var requestLogs: [UInt64: RequestLogContext] = [:]
    private var terminatedRequestStreams: Set<UInt64> = []
    private var pendingReceivedDatagrams: [Data] = []
    private var pendingScheduledDatagram: GhostFileScheduledDatagram?
    private var isReceiveDrainScheduled = false
    private let createdAt = DispatchTime.now().uptimeNanoseconds
    private var didLogHandshake = false
    private var receivedDatagramCount = 0
    private var receivedByteCount = 0
    private var sentDatagramCount = 0
    private var sentByteCount = 0

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
        sessionID: String,
        connection: NWConnection,
        certificatePath: String,
        privateKeyPath: String,
        router: GhostFileShareRouter,
        requestDelay: @escaping RequestDelay,
        requestCompleted: @escaping @Sendable () -> Void,
        stopped: @escaping @Sendable () -> Void
    ) throws {
        self.sessionID = sessionID
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
        ghostFileHTTP3ServerLogger.notice(
            "Session starting session=\(self.sessionID, privacy: .public) endpoint=\(String(describing: self.connection.endpoint), privacy: .public)"
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.connectionStateChanged(state) }
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
        guard !hasStopped, !isStopping else { return }
        guard error == nil, let content else {
            ghostFileHTTP3ServerLogger.error(
                "Session receive failed session=\(self.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
            await stopIsolated(reason: "receiveFailed")
            return
        }
        receivedDatagramCount += 1
        receivedByteCount += content.count
        if receivedDatagramCount == 1 {
            ghostFileHTTP3ServerLogger.notice(
                "Session first UDP datagram session=\(self.sessionID, privacy: .public) bytes=\(content.count, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
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

    private func drainReceivedDatagrams() async {
        while !pendingReceivedDatagrams.isEmpty, !hasStopped, !isStopping {
            let count = min(GhostFileNetworkDatagram.maximumReceiveCount, pendingReceivedDatagrams.count)
            let datagrams = Array(pendingReceivedDatagrams.prefix(count))
            pendingReceivedDatagrams.removeFirst(count)
            do {
                for datagram in datagrams {
                    try http3.receive(datagram)
                }
                if http3.isEstablished && !didLogHandshake {
                    didLogHandshake = true
                    ghostFileHTTP3ServerLogger.notice(
                        "Session QUIC handshake established session=\(self.sessionID, privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
                    )
                }
                drainPeerTerminatedResponses()
                try processEvents()
                drainPeerTerminatedResponses()
                await flushOutgoing()
                resetTimeout()
            } catch {
                ghostFileHTTP3ServerLogger.error(
                    "Session datagram processing failed session=\(self.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
                )
                await stopIsolated(reason: "datagramProcessingFailed")
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
                let requestID = request.header("x-ghostfile-request-id")
                    ?? "peer-\(self.sessionID)-\(streamID)"
                let logContext = RequestLogContext(
                    requestID: requestID,
                    operation: context.operation,
                    startedAt: DispatchTime.now().uptimeNanoseconds
                )
                requestLogs[streamID] = logContext
                ghostFileHTTP3ServerLogger.info(
                    "Request received request=\(requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) offset=\(String(describing: context.offset), privacy: .public) length=\(String(describing: context.length), privacy: .public) path=\(String(describing: context.path), privacy: .private(mask: .hash))"
                )
                let router = self.router
                let delay = self.requestDelay
                let task = Task { [weak self] in
                    let started = ContinuousClock.now
                    await delay(context)
                    guard !Task.isCancelled else {
                        await self?.routingCancelled(streamID: streamID)
                        return
                    }
                    let response = await Self.route(request, using: router)
                    guard !Task.isCancelled else {
                        await self?.routingCancelled(streamID: streamID)
                        return
                    }
                    let elapsed = started.duration(to: .now)
                    ghostFileHTTP3ServerLogger.info(
                        "Request routed request=\(requestID, privacy: .public) session=\(self?.sessionID ?? "gone", privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) status=\(response.status.rawValue, privacy: .public) bytes=\(response.body.contentLength, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
                    )
                    await self?.routingFinished(
                        response,
                        streamID: streamID,
                        context: logContext
                    )
                }
                routingTasks[streamID] = task
            case .data(let streamID):
                try http3.discardReceivedBody(streamID: streamID)
            case .reset(let streamID):
                terminatedRequestStreams.insert(streamID)
                if let context = requestLogs.removeValue(forKey: streamID) {
                    ghostFileHTTP3ServerLogger.error(
                        "Request reset by client request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
                    )
                }
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
        } catch { await stopIsolated(reason: "badRequestSendFailed") }
    }

    private func send(
        _ response: GhostFileHTTPResponse,
        streamID: UInt64,
        context: RequestLogContext
    ) async {
        guard !hasStopped else { return }
        guard terminatedRequestStreams.remove(streamID) == nil else {
            requestLogs.removeValue(forKey: streamID)
            return
        }
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

            let completesImmediately: Bool
            switch response.body {
            case .empty:
                try http3.sendResponse(streamID: streamID, headers: headers, body: Data())
                completesImmediately = true
            case .bytes(let body):
                try http3.sendResponse(streamID: streamID, headers: headers, body: body)
                completesImmediately = true
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
                completesImmediately = false
            }
            ghostFileHTTP3ServerLogger.info(
                "Response queued request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) status=\(response.status.rawValue, privacy: .public) bytes=\(response.body.contentLength, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
            )
            if completesImmediately {
                requestLogs.removeValue(forKey: streamID)
                requestCompleted()
            }
            await flushOutgoing()
        } catch {
            ghostFileHTTP3ServerLogger.error(
                "Response failed request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) error=\(String(describing: error), privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
            )
            await stopIsolated(reason: "responseFailed")
        }
    }

    private func flushOutgoing() async {
        guard !hasStopped, !isStopping else { return }
        if isFlushing {
            flushAgain = true
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        do {
            repeat {
                flushAgain = false
                while !isStopping {
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
                        drainPeerTerminatedResponses()
                    }
                    drainPeerTerminatedResponses()
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
            ghostFileHTTP3ServerLogger.error(
                "Session UDP send failed session=\(self.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
            await stopIsolated(reason: "sendFailed")
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
            ghostFileHTTP3ServerLogger.error(
                "Session QUIC timeout closed connection session=\(self.sessionID, privacy: .public) activeRequests=\(self.requestLogs.count, privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
            await stopIsolated(reason: "quicTimeoutClosed")
        }
    }

    private func connectionStateChanged(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            ghostFileHTTP3ServerLogger.notice(
                "Session UDP ready session=\(self.sessionID, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
        case .waiting(let error):
            ghostFileHTTP3ServerLogger.notice(
                "Session UDP waiting session=\(self.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
        case .failed(let error):
            ghostFileHTTP3ServerLogger.error(
                "Session UDP failed session=\(self.sessionID, privacy: .public) error=\(String(describing: error), privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
            )
            await stopIsolated(reason: "networkFailed")
        case .cancelled:
            await stopIsolated(reason: "networkCancelled")
        default:
            break
        }
    }

    private func stopIsolated(reason: String = "requested") async {
        guard !hasStopped, !isStopping else { return }
        isStopping = true
        ghostFileHTTP3ServerLogger.notice(
            "Session stopping session=\(self.sessionID, privacy: .public) reason=\(reason, privacy: .public) activeRequests=\(self.requestLogs.count, privacy: .public) receivedDatagrams=\(self.receivedDatagramCount, privacy: .public) receivedBytes=\(self.receivedByteCount, privacy: .public) sentDatagrams=\(self.sentDatagramCount, privacy: .public) sentBytes=\(self.sentByteCount, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: self.createdAt), privacy: .public)"
        )
        timeoutTask?.cancel()
        for task in routingTasks.values { task.cancel() }
        routingTasks.removeAll()
        for task in responseTasks.values { task.cancel() }
        responseTasks.removeAll()
        requestLogs.removeAll()
        pendingScheduledDatagram = nil
        while isFlushing {
            await Task.yield()
        }
        let applicationErrorCode = reason == "requested"
            ? GhostFileHTTP3Connection.h3NoError
            : GhostFileHTTP3Connection.h3InternalError
        await sendConnectionClose(reason: reason, applicationErrorCode: applicationErrorCode)
        hasStopped = true
        connection.cancel()
        stopped()
    }

    private func sendConnectionClose(reason: String, applicationErrorCode: UInt64) async {
        do {
            try http3.close(applicationErrorCode: applicationErrorCode, reason: reason)
            while let datagram = try http3.nextScheduledDatagram() {
                let now = ghostFileMonotonicNanoseconds()
                if datagram.sendAtNanoseconds > now {
                    try await Task.sleep(nanoseconds: datagram.sendAtNanoseconds - now)
                }
                try await connection.sendGhostFileDatagrams([datagram.data])
                sentDatagramCount += 1
                sentByteCount += datagram.data.count
            }
        } catch {
            ghostFileHTTP3ServerLogger.error(
                "Session close notification failed session=\(self.sessionID, privacy: .public) reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
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
        if let context = requestLogs[streamID] {
            ghostFileHTTP3ServerLogger.info(
                "File response started request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) offset=\(offset, privacy: .public) bytes=\(length, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
            )
        }
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

    private func routingCancelled(streamID: UInt64) {
        routingTasks.removeValue(forKey: streamID)
        terminatedRequestStreams.remove(streamID)
    }

    private func routingFinished(
        _ response: GhostFileHTTPResponse,
        streamID: UInt64,
        context: RequestLogContext
    ) async {
        guard routingTasks.removeValue(forKey: streamID) != nil,
              !hasStopped,
              !terminatedRequestStreams.contains(streamID) else { return }
        await send(response, streamID: streamID, context: context)
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
        requestCompleted()
        if let context = requestLogs.removeValue(forKey: streamID) {
            ghostFileHTTP3ServerLogger.info(
                "File response completed request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
            )
        }
    }

    private func fileResponseFailed(_ error: Error, streamID: UInt64) async {
        if let context = requestLogs.removeValue(forKey: streamID) {
            ghostFileHTTP3ServerLogger.error(
                "File response failed request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) error=\(String(describing: error), privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
            )
        }
        cancelResponse(streamID: streamID, resetTransport: true)
        await flushOutgoing()
    }

    private func cancelResponse(streamID: UInt64, resetTransport: Bool = false) {
        routingTasks.removeValue(forKey: streamID)?.cancel()
        responseTasks.removeValue(forKey: streamID)?.cancel()
        if resetTransport {
            http3.resetResponse(streamID: streamID)
        } else {
            http3.abandonResponse(streamID: streamID)
        }
    }

    private func drainPeerTerminatedResponses() {
        for streamID in Array(routingTasks.keys)
            where http3.peerStoppedReceivingResponse(streamID: streamID) {
            terminatedRequestStreams.insert(streamID)
            if let context = requestLogs.removeValue(forKey: streamID) {
                ghostFileHTTP3ServerLogger.notice(
                    "Response stopped by peer during routing request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
                )
            }
            cancelResponse(streamID: streamID)
        }
        for streamID in http3.takePeerTerminatedResponseStreamIDs() {
            terminatedRequestStreams.insert(streamID)
            if let context = requestLogs.removeValue(forKey: streamID) {
                ghostFileHTTP3ServerLogger.notice(
                    "Response abandoned by peer request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
                )
            }
            cancelResponse(streamID: streamID)
        }
        for streamID in http3.takeFailedResponseStreamIDs() {
            terminatedRequestStreams.insert(streamID)
            if let context = requestLogs.removeValue(forKey: streamID) {
                ghostFileHTTP3ServerLogger.error(
                    "Response stream failed request=\(context.requestID, privacy: .public) session=\(self.sessionID, privacy: .public) stream=\(streamID, privacy: .public) operation=\(context.operation, privacy: .public) elapsedMs=\(ghostFileServerElapsedMilliseconds(since: context.startedAt), privacy: .public)"
                )
            }
            cancelResponse(streamID: streamID, resetTransport: true)
        }
    }

}

/// Resolves the service GhostFile just published and returns the actual mDNS
/// SRV target. `ProcessInfo.hostName` is not suitable here: VPN and DNS clients
/// can replace it with a connectivity-check hostname that is not the machine's
/// Bonjour endpoint.
private final class GhostFileBonjourSelfResolver: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let completion: (String) -> Void
    private let browser = NetServiceBrowser()
    private weak var publishedService: NetService?
    private var expectedName = ""
    private var candidates: [ObjectIdentifier: NetService] = [:]
    private var didResolve = false

    init(completion: @escaping (String) -> Void) {
        self.completion = completion
        super.init()
        browser.delegate = self
        browser.includesPeerToPeer = true
    }

    func publish(_ service: NetService) {
        publishedService = service
        service.delegate = self
        service.publish()
    }

    func stop() {
        browser.stop()
        for service in candidates.values {
            service.stop()
        }
        candidates.removeAll()
        publishedService?.delegate = nil
        publishedService = nil
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === publishedService else { return }
        expectedName = sender.name
        // Resolve the final registered name directly. Browsing for our own
        // service can miss or be delayed when instances with the same display
        // name overlap during their short shutdown grace period.
        resolve(domain: sender.domain, type: sender.type, name: sender.name)
        browser.searchForServices(ofType: sender.type, inDomain: sender.domain)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === publishedService else { return }
        ghostFileHTTP3ServerLogger.error(
            "Bonjour publication failed name=\(sender.name, privacy: .private(mask: .hash)) error=\(String(describing: errorDict), privacy: .public)"
        )
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        guard !didResolve, service.name == expectedName else { return }
        beginResolution(service)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard candidates.removeValue(forKey: ObjectIdentifier(sender)) != nil else { return }
        ghostFileHTTP3ServerLogger.notice(
            "Bonjour self-resolution attempt failed name=\(sender.name, privacy: .private(mask: .hash)) error=\(String(describing: errorDict), privacy: .public)"
        )
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !didResolve, candidates[ObjectIdentifier(sender)] != nil,
              let hostName = sender.hostName else { return }
        didResolve = true
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        completion(host)
        browser.stop()
        for service in candidates.values where service !== sender {
            service.stop()
        }
        candidates.removeAll()
    }

    private func resolve(domain: String, type: String, name: String) {
        beginResolution(NetService(domain: domain, type: type, name: name))
    }

    private func beginResolution(_ service: NetService) {
        let key = ObjectIdentifier(service)
        guard candidates[key] == nil else { return }
        candidates[key] = service
        service.delegate = self
        service.includesPeerToPeer = true
        service.resolve(withTimeout: 5)
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
