import CryptoKit
import Dispatch
import Foundation
import FSKit
import GhostHTTP3
import Network

struct GhostFileHTTP3Client: Sendable {
    private let transport: GhostFileHTTP3Transport

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
        try await decode(GhostFileMetadata.self, operation: "metadata", relativePath: path)
    }

    func directory(path: String) async throws -> GhostFileDirectoryListing {
        try await decode(GhostFileDirectoryListing.self, operation: "directory", relativePath: path)
    }

    func read(path: String, offset: UInt64, length: Int) async throws -> Data {
        guard length >= 0, length <= GhostFileProtocol.maximumReadLength else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        return try await request(operation: "content", relativePath: path, offset: offset, length: length)
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
    private var receiveTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hasStarted = false
    private var isNetworkReady = false
    private var hasValidatedPeer = false
    private var terminalError: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var handshakeWaiters: [CheckedContinuation<Void, Error>] = []
    private var pending: [UInt64: PendingResponse] = [:]
    private var isFlushing = false
    private var flushAgain = false

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
        let streamID = try http3.sendRequest(headers: headers)
        return try await withCheckedThrowingContinuation { continuation in
            pending[streamID] = PendingResponse(continuation: continuation)
            Task { await self.flushOutgoing() }
        }
    }

    private func operationPath(_ operation: String) -> String {
        // The share UUID is already part of the mount URL path. The server
        // validates it, so retain it when translating an FSKit operation.
        // `host` is intentionally not involved in HTTP routing.
        return resourceBasePath + "/" + operation
    }

    private func ensureHTTP3Ready() async throws {
        if let terminalError { throw terminalError }
        if !hasStarted { start() }
        if !isNetworkReady {
            try await withCheckedThrowingContinuation { readyWaiters.append($0) }
        }
        if !hasValidatedPeer {
            try await withCheckedThrowingContinuation { handshakeWaiters.append($0) }
        }
    }

    private func start() {
        guard !hasStarted else { return }
        hasStarted = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.connectionStateChanged(state) }
        }
        connection.start(queue: DispatchQueue(label: "org.ghostvm.ghostfile.http3.client"))
        receiveTask = Task { [weak self, connection] in
            do {
                while !Task.isCancelled {
                    let datagram = try await connection.receiveDatagram()
                    await self?.received(datagram)
                }
            } catch {
                await self?.fail(error)
            }
        }
    }

    private func connectionStateChanged(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            isNetworkReady = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await flushOutgoing()
        case .failed(let error):
            fail(error)
        case .cancelled:
            fail(TransportError.closed)
        default:
            break
        }
    }

    private func received(_ datagram: Data) async {
        do {
            try http3.receive(datagram)
            if http3.isEstablished && !hasValidatedPeer {
                guard let certificate = http3.peerCertificateDER(),
                      Self.pin(for: certificate) == expectedCertificatePin else {
                    throw TransportError.certificatePinMismatch
                }
                hasValidatedPeer = true
                let waiters = handshakeWaiters
                handshakeWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            try processEvents()
            await flushOutgoing()
            resetTimeout()
        } catch {
            fail(error)
        }
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
                while let datagram = try http3.nextDatagram() {
                    try await connection.sendDatagram(datagram)
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

    private func fail(_ error: Error) {
        guard terminalError == nil else { return }
        NSLog("GhostFile HTTP/3 transport failed: %@", String(describing: error))
        terminalError = error
        readyWaiters.forEach { $0.resume(throwing: error) }
        handshakeWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters.removeAll()
        handshakeWaiters.removeAll()
        for response in pending.values { response.continuation.resume(throwing: error) }
        pending.removeAll()
        timeoutTask?.cancel()
        connection.cancel()
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

    private enum TransportError: Error {
        case invalidResponse
        case certificatePinMismatch
        case streamReset
        case closed
    }
}

private extension NWConnection {
    func sendDatagram(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receiveDatagram() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            receiveMessage { content, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let content { continuation.resume(returning: content) }
                else { continuation.resume(throwing: GhostFileDatagramError.closed) }
            }
        }
    }
}

private enum GhostFileDatagramError: Error {
    case closed
}
