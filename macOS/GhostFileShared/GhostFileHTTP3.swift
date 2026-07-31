import Darwin
import Foundation
import GhostHTTP3

final class GhostFileHTTP3Connection: @unchecked Sendable {
    enum Role {
        case client(serverName: String)
        case server(certificatePath: String, privateKeyPath: String)
    }

    enum Event {
        case headers(streamID: UInt64, fields: [(String, String)], hasBody: Bool)
        case data(streamID: UInt64)
        case finished(streamID: UInt64)
        case reset(streamID: UInt64)
    }

    enum ConnectionError: LocalizedError {
        case configuration(String)
        case connection(String)
        case http3(String)

        var errorDescription: String? {
            switch self {
            case .configuration(let message), .connection(let message), .http3(let message):
                return message
            }
        }
    }

    private let role: Role
    private let quicConfiguration: OpaquePointer
    private let http3Configuration: OpaquePointer
    private var quicConnection: OpaquePointer?
    private var http3Connection: OpaquePointer?
    private var currentEvent: OpaquePointer?
    private var pendingResponses: [UInt64: PendingHTTP3Response] = [:]
    private var localAddress = sockaddr_in()
    private var peerAddress = sockaddr_in()

    init(role: Role) throws {
        self.role = role
        guard let quicConfiguration = quiche_config_new(UInt32(QUICHE_PROTOCOL_VERSION)) else {
            throw ConnectionError.configuration("Unable to create the QUIC configuration")
        }
        self.quicConfiguration = quicConfiguration
        guard let http3Configuration = quiche_h3_config_new() else {
            quiche_config_free(quicConfiguration)
            throw ConnectionError.configuration("Unable to create the HTTP/3 configuration")
        }
        self.http3Configuration = http3Configuration

        let alpn = [UInt8](QUICHE_H3_APPLICATION_PROTOCOL.utf8)
        guard quiche_config_set_application_protos(quicConfiguration, alpn, alpn.count) == 0 else {
            throw ConnectionError.configuration("Unable to configure the HTTP/3 ALPN")
        }
        quiche_config_set_max_idle_timeout(quicConfiguration, 60_000)
        quiche_config_set_max_recv_udp_payload_size(quicConfiguration, 1_350)
        quiche_config_set_max_send_udp_payload_size(quicConfiguration, 1_350)
        quiche_config_set_initial_max_data(quicConfiguration, 64 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_bidi_local(quicConfiguration, 2 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_bidi_remote(quicConfiguration, 2 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_uni(quicConfiguration, 2 * 1024 * 1024)
        quiche_config_set_initial_max_streams_bidi(quicConfiguration, 256)
        quiche_config_set_initial_max_streams_uni(quicConfiguration, 16)
        quiche_config_set_disable_active_migration(quicConfiguration, true)
        quiche_h3_config_set_qpack_max_table_capacity(http3Configuration, 4_096)
        quiche_h3_config_set_qpack_blocked_streams(http3Configuration, 100)

        Self.fillAddress(&localAddress, port: 41_000)
        Self.fillAddress(&peerAddress, port: 41_001)

        switch role {
        case .client(let serverName):
            quiche_config_verify_peer(quicConfiguration, false)
            var sourceID = [UInt8](repeating: 0, count: 16)
            arc4random_buf(&sourceID, sourceID.count)
            quicConnection = withAddresses { local, localLength, peer, peerLength in
                sourceID.withUnsafeBufferPointer { sourceID in
                    serverName.withCString { serverName in
                        quiche_connect(
                            serverName,
                            sourceID.baseAddress,
                            sourceID.count,
                            local,
                            localLength,
                            peer,
                            peerLength,
                            quicConfiguration
                        )
                    }
                }
            }
            guard quicConnection != nil else {
                throw ConnectionError.connection("Unable to create the client QUIC connection")
            }

        case .server(let certificatePath, let privateKeyPath):
            guard quiche_config_load_cert_chain_from_pem_file(quicConfiguration, certificatePath) == 0 else {
                throw ConnectionError.configuration("Unable to load the GhostFile TLS certificate")
            }
            guard quiche_config_load_priv_key_from_pem_file(quicConfiguration, privateKeyPath) == 0 else {
                throw ConnectionError.configuration("Unable to load the GhostFile TLS private key")
            }
            swap(&localAddress, &peerAddress)
        }
    }

    deinit {
        if let currentEvent { quiche_h3_event_free(currentEvent) }
        if let http3Connection { quiche_h3_conn_free(http3Connection) }
        if let quicConnection { quiche_conn_free(quicConnection) }
        quiche_h3_config_free(http3Configuration)
        quiche_config_free(quicConfiguration)
    }

    var isEstablished: Bool {
        guard let quicConnection else { return false }
        return quiche_conn_is_established(quicConnection)
    }

    var isClosed: Bool {
        guard let quicConnection else { return false }
        return quiche_conn_is_closed(quicConnection)
    }

    var timeoutNanoseconds: UInt64? {
        guard let quicConnection else { return nil }
        let value = quiche_conn_timeout_as_nanos(quicConnection)
        return value == UInt64.max ? nil : value
    }

    func handleTimeout() {
        guard let quicConnection else { return }
        quiche_conn_on_timeout(quicConnection)
    }

    func receive(_ datagram: Data) throws {
        if quicConnection == nil {
            try acceptInitial(datagram)
        }
        guard let quicConnection else {
            throw ConnectionError.connection("The server did not accept the QUIC connection")
        }
        var mutableDatagram = datagram
        let result = withAddresses { local, localLength, peer, peerLength -> Int in
            var receiveInfo = quiche_recv_info(
                from: UnsafeMutablePointer(mutating: peer),
                from_len: peerLength,
                to: UnsafeMutablePointer(mutating: local),
                to_len: localLength
            )
            return mutableDatagram.withUnsafeMutableBytes { bytes in
                Int(quiche_conn_recv(
                    quicConnection,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    &receiveInfo
                ))
            }
        }
        guard result >= 0 else {
            throw ConnectionError.connection("QUIC rejected a UDP datagram (\(result))")
        }
        try createHTTP3ConnectionIfReady()
        try pumpResponseBodies()
    }

    func nextDatagram() throws -> Data? {
        guard let quicConnection else { return nil }
        try pumpResponseBodies()
        var output = Data(count: 65_535)
        var sendInfo = quiche_send_info()
        let length = output.withUnsafeMutableBytes { bytes in
            Int(quiche_conn_send(
                quicConnection,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &sendInfo
            ))
        }
        if length == Int(QUICHE_ERR_DONE.rawValue) { return nil }
        guard length > 0 else {
            throw ConnectionError.connection("QUIC could not produce a UDP datagram (\(length))")
        }
        output.count = length
        return output
    }

    func peerCertificateDER() -> Data? {
        guard let quicConnection else { return nil }
        var pointer: UnsafePointer<UInt8>?
        var length = 0
        quiche_conn_peer_cert(quicConnection, &pointer, &length)
        guard let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }

    func sendRequest(headers: [(String, String)], body: Data = Data()) throws -> UInt64 {
        try createHTTP3ConnectionIfReady()
        guard let quicConnection, let http3Connection else {
            throw ConnectionError.http3("The HTTP/3 handshake is not complete")
        }
        let managedHeaders = ManagedHTTP3Headers(headers)
        let streamID = managedHeaders.withUnsafeHeaders { headers, count in
            quiche_h3_send_request(http3Connection, quicConnection, headers, count, body.isEmpty)
        }
        guard streamID >= 0 else {
            throw ConnectionError.http3("Unable to open an HTTP/3 request stream (\(streamID))")
        }
        if !body.isEmpty {
            let sent = body.withUnsafeBytes { bytes in
                quiche_h3_send_body(
                    http3Connection,
                    quicConnection,
                    UInt64(streamID),
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    true
                )
            }
            guard sent == body.count else {
                throw ConnectionError.http3("Unable to send the complete HTTP/3 request body")
            }
        }
        return UInt64(streamID)
    }

    func sendResponse(streamID: UInt64, headers: [(String, String)], body: Data) throws {
        guard quicConnection != nil, http3Connection != nil else {
            throw ConnectionError.http3("The HTTP/3 connection is not ready")
        }
        pendingResponses[streamID] = PendingHTTP3Response(headers: headers, body: body)
        try pumpResponses()
    }

    func pollEvent() throws -> Event? {
        if let currentEvent {
            quiche_h3_event_free(currentEvent)
            self.currentEvent = nil
        }
        guard let quicConnection, let http3Connection else { return nil }
        var event: OpaquePointer?
        let streamID = quiche_h3_conn_poll(http3Connection, quicConnection, &event)
        if streamID == Int64(QUICHE_H3_ERR_DONE.rawValue) { return nil }
        guard streamID >= 0, let event else {
            throw ConnectionError.http3("Unable to poll HTTP/3 events (\(streamID))")
        }
        currentEvent = event
        switch quiche_h3_event_type(event) {
        case QUICHE_H3_EVENT_HEADERS:
            let box = HeaderCollectionBox()
            let context = Unmanaged.passUnretained(box).toOpaque()
            guard quiche_h3_event_for_each_header(event, ghostFileHTTP3CollectHeader, context) == 0 else {
                throw ConnectionError.http3("Received malformed HTTP/3 headers")
            }
            return .headers(
                streamID: UInt64(streamID),
                fields: box.fields,
                hasBody: quiche_h3_event_headers_has_more_frames(event)
            )
        case QUICHE_H3_EVENT_DATA:
            return .data(streamID: UInt64(streamID))
        case QUICHE_H3_EVENT_FINISHED:
            return .finished(streamID: UInt64(streamID))
        case QUICHE_H3_EVENT_RESET:
            return .reset(streamID: UInt64(streamID))
        default:
            return nil
        }
    }

    func receiveBody(streamID: UInt64) throws -> Data {
        guard let quicConnection, let http3Connection else { return Data() }
        var result = Data()
        var buffer = Data(count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Int(quiche_h3_recv_body(
                    http3Connection,
                    quicConnection,
                    streamID,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                ))
            }
            if count == Int(QUICHE_H3_ERR_DONE.rawValue) { break }
            guard count >= 0 else {
                throw ConnectionError.http3("Unable to receive an HTTP/3 body (\(count))")
            }
            result.append(buffer.prefix(count))
        }
        return result
    }

    private func acceptInitial(_ datagram: Data) throws {
        guard case .server = role else { return }
        var version: UInt32 = 0
        var packetType: UInt8 = 0
        var sourceID = [UInt8](repeating: 0, count: Int(QUICHE_MAX_CONN_ID_LEN))
        var destinationID = [UInt8](repeating: 0, count: Int(QUICHE_MAX_CONN_ID_LEN))
        var token = [UInt8](repeating: 0, count: 256)
        var sourceIDLength = sourceID.count
        var destinationIDLength = destinationID.count
        var tokenLength = token.count
        let parsed = datagram.withUnsafeBytes { datagramBytes in
            sourceID.withUnsafeMutableBufferPointer { sourceID in
                destinationID.withUnsafeMutableBufferPointer { destinationID in
                    token.withUnsafeMutableBufferPointer { token in
                        quiche_header_info(
                            datagramBytes.bindMemory(to: UInt8.self).baseAddress,
                            datagramBytes.count,
                            16,
                            &version,
                            &packetType,
                            sourceID.baseAddress,
                            &sourceIDLength,
                            destinationID.baseAddress,
                            &destinationIDLength,
                            token.baseAddress,
                            &tokenLength
                        )
                    }
                }
            }
        }
        guard parsed == 0, quiche_version_is_supported(version) else {
            throw ConnectionError.connection("Received an unsupported QUIC Initial packet")
        }
        var serverID = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&serverID, serverID.count)
        quicConnection = withAddresses { local, localLength, peer, peerLength in
            serverID.withUnsafeBufferPointer { serverID in
                destinationID.withUnsafeBufferPointer { destinationID in
                    quiche_accept(
                        serverID.baseAddress,
                        serverID.count,
                        destinationID.baseAddress,
                        destinationIDLength,
                        local,
                        localLength,
                        peer,
                        peerLength,
                        quicConfiguration
                    )
                }
            }
        }
    }

    private func createHTTP3ConnectionIfReady() throws {
        guard http3Connection == nil,
              let quicConnection,
              quiche_conn_is_established(quicConnection) else { return }
        guard let connection = quiche_h3_conn_new_with_transport(quicConnection, http3Configuration) else {
            throw ConnectionError.http3("Unable to create the HTTP/3 connection")
        }
        http3Connection = connection
    }

    private func pumpResponseBodies() throws {
        try pumpResponses()
    }

    private func pumpResponses() throws {
        guard let quicConnection, let http3Connection, !pendingResponses.isEmpty else { return }
        for streamID in Array(pendingResponses.keys) {
            guard var pending = pendingResponses[streamID] else { continue }
            if !pending.headersSent {
                let managedHeaders = ManagedHTTP3Headers(pending.headers)
                let result = managedHeaders.withUnsafeHeaders { headers, count in
                    quiche_h3_send_response(
                        http3Connection,
                        quicConnection,
                        streamID,
                        headers,
                        count,
                        pending.body.isEmpty
                    )
                }
                if result == Int32(QUICHE_H3_ERR_STREAM_BLOCKED.rawValue) ||
                    result == Int32(QUICHE_H3_ERR_DONE.rawValue) {
                    pendingResponses[streamID] = pending
                    continue
                }
                guard result == 0 else {
                    throw ConnectionError.http3("Unable to send HTTP/3 response headers (\(result))")
                }
                pending.headersSent = true
                if pending.body.isEmpty {
                    pendingResponses.removeValue(forKey: streamID)
                    continue
                }
            }
            while pending.offset < pending.data.count {
                let offeredLength = min(16 * 1024, pending.data.count - pending.offset)
                let isFinal = pending.offset + offeredLength == pending.data.count
                let sent = pending.data.withUnsafeBytes { bytes -> Int in
                    let base = bytes.bindMemory(to: UInt8.self).baseAddress?.advanced(by: pending.offset)
                    return Int(quiche_h3_send_body(
                        http3Connection,
                        quicConnection,
                        streamID,
                        base,
                        offeredLength,
                        isFinal
                    ))
                }
                if sent == Int(QUICHE_H3_ERR_DONE.rawValue) ||
                    sent == Int(QUICHE_H3_ERR_STREAM_BLOCKED.rawValue) { break }
                guard sent > 0 else {
                    throw ConnectionError.http3("Unable to send the HTTP/3 response body (\(sent))")
                }
                pending.offset += sent
            }
            if pending.offset == pending.data.count {
                pendingResponses.removeValue(forKey: streamID)
            } else {
                pendingResponses[streamID] = pending
            }
        }
    }

    private func withAddresses<T>(
        _ body: (UnsafePointer<sockaddr>, socklen_t, UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) rethrows -> T {
        try withUnsafePointer(to: &localAddress) { local in
            try withUnsafePointer(to: &peerAddress) { peer in
                try local.withMemoryRebound(to: sockaddr.self, capacity: 1) { local in
                    try peer.withMemoryRebound(to: sockaddr.self, capacity: 1) { peer in
                        try body(local, socklen_t(MemoryLayout<sockaddr_in>.size), peer, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private static func fillAddress(_ address: inout sockaddr_in, port: UInt16) {
        address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    }
}

private struct PendingHTTP3Response {
    let headers: [(String, String)]
    let body: Data
    var headersSent = false
    var offset: Int

    init(headers: [(String, String)], body: Data) {
        self.headers = headers
        self.body = body
        self.offset = 0
    }

    var data: Data { body }
}

private final class HeaderCollectionBox {
    var fields: [(String, String)] = []
}

private func ghostFileHTTP3CollectHeader(
    _ name: UnsafeMutablePointer<UInt8>?,
    _ nameLength: Int,
    _ value: UnsafeMutablePointer<UInt8>?,
    _ valueLength: Int,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let name, let value, let context,
          let headerName = String(bytes: UnsafeBufferPointer(start: name, count: nameLength), encoding: .utf8),
          let headerValue = String(bytes: UnsafeBufferPointer(start: value, count: valueLength), encoding: .utf8) else {
        return -1
    }
    Unmanaged<HeaderCollectionBox>.fromOpaque(context).takeUnretainedValue().fields.append((headerName, headerValue))
    return 0
}

private final class ManagedHTTP3Headers {
    private var names: [UnsafeMutablePointer<UInt8>] = []
    private var values: [UnsafeMutablePointer<UInt8>] = []
    private var headers: [quiche_h3_header] = []

    init(_ fields: [(String, String)]) {
        names.reserveCapacity(fields.count)
        values.reserveCapacity(fields.count)
        headers.reserveCapacity(fields.count)
        for (name, value) in fields {
            let nameBytes = Array(name.utf8)
            let valueBytes = Array(value.utf8)
            let namePointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, nameBytes.count))
            let valuePointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, valueBytes.count))
            if !nameBytes.isEmpty { namePointer.initialize(from: nameBytes, count: nameBytes.count) }
            if !valueBytes.isEmpty { valuePointer.initialize(from: valueBytes, count: valueBytes.count) }
            names.append(namePointer)
            values.append(valuePointer)
            headers.append(quiche_h3_header(
                name: UnsafePointer(namePointer),
                name_len: nameBytes.count,
                value: UnsafePointer(valuePointer),
                value_len: valueBytes.count
            ))
        }
    }

    deinit {
        for pointer in names { pointer.deallocate() }
        for pointer in values { pointer.deallocate() }
    }

    func withUnsafeHeaders<T>(_ body: (UnsafePointer<quiche_h3_header>?, Int) -> T) -> T {
        headers.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
    }
}
