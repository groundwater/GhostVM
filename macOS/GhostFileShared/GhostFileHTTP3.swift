import Darwin
import Foundation
import GhostHTTP3
import Network

final class GhostFileHTTP3Connection: @unchecked Sendable {
    private static let maximumUDPPayloadSize: Int = {
        guard let rawValue = ProcessInfo.processInfo.environment["GHOSTFILE_HTTP3_UDP_PAYLOAD_SIZE"],
              let value = Int(rawValue), (1_200...65_527).contains(value) else {
            return 1_350
        }
        return value
    }()
    private static let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["GHOSTFILE_HTTP3_DIAGNOSTICS"] == "1"

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
    private var peerTerminatedResponseStreamIDs: [UInt64] = []
    private var failedResponseStreamIDs: [UInt64] = []
    private var localAddress = sockaddr_in()
    private var peerAddress = sockaddr_in()
    private let diagnosticRole: String
    private var diagnosticStartedAt = DispatchTime.now().uptimeNanoseconds
    private var diagnosticPumpCalls = 0
    private var diagnosticStreamVisits = 0
    private var diagnosticBodyAttempts = 0
    private var diagnosticBodyBlocked = 0
    private var diagnosticBodyAcceptedBytes = 0
    private var diagnosticNextDatagramCalls = 0
    private var diagnosticDatagrams = 0
    private var diagnosticDatagramBytes = 0
    private var diagnosticSendDone = 0
    private var diagnosticFuturePacingPackets = 0
    private var diagnosticFuturePacingNanoseconds: UInt64 = 0
    private var diagnosticMaximumPacingNanoseconds: UInt64 = 0
    private var diagnosticBatches = 0
    private var diagnosticBatchPackets = 0
    private var diagnosticProduceNanoseconds: UInt64 = 0
    private var diagnosticNetworkNanoseconds: UInt64 = 0

    init(role: Role) throws {
        self.role = role
        switch role {
        case .client: diagnosticRole = "client"
        case .server: diagnosticRole = "server"
        }
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
        quiche_config_set_max_recv_udp_payload_size(quicConfiguration, Self.maximumUDPPayloadSize)
        quiche_config_set_max_send_udp_payload_size(quicConfiguration, Self.maximumUDPPayloadSize)
        quiche_config_set_initial_max_data(quicConfiguration, 64 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_bidi_local(quicConfiguration, 2 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_bidi_remote(quicConfiguration, 2 * 1024 * 1024)
        quiche_config_set_initial_max_stream_data_uni(quicConfiguration, 2 * 1024 * 1024)
        // Each GhostFile content response is capped at 1 MiB. Keep the maximum
        // number of concurrent request streams aligned with the 64 MiB
        // connection window so application-side response buffering is bounded.
        quiche_config_set_initial_max_streams_bidi(quicConfiguration, 64)
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
        if Self.diagnosticsEnabled { diagnosticNextDatagramCalls += 1 }
        try pumpResponseBodies()
        var output = Data(count: Self.maximumUDPPayloadSize)
        var sendInfo = quiche_send_info()
        let length = output.withUnsafeMutableBytes { bytes in
            Int(quiche_conn_send(
                quicConnection,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                &sendInfo
            ))
        }
        if length == Int(QUICHE_ERR_DONE.rawValue) {
            if Self.diagnosticsEnabled { diagnosticSendDone += 1 }
            return nil
        }
        guard length > 0 else {
            throw ConnectionError.connection("QUIC could not produce a UDP datagram (\(length))")
        }
        output.count = length
        if Self.diagnosticsEnabled {
            diagnosticDatagrams += 1
            diagnosticDatagramBytes += length
            var now = timespec()
            clock_gettime(CLOCK_MONOTONIC, &now)
            let nowNanoseconds = Int64(now.tv_sec) * 1_000_000_000 + Int64(now.tv_nsec)
            let sendNanoseconds = Int64(sendInfo.at.tv_sec) * 1_000_000_000 + Int64(sendInfo.at.tv_nsec)
            if sendNanoseconds > nowNanoseconds {
                let delay = UInt64(sendNanoseconds - nowNanoseconds)
                diagnosticFuturePacingPackets += 1
                diagnosticFuturePacingNanoseconds += delay
                diagnosticMaximumPacingNanoseconds = max(diagnosticMaximumPacingNanoseconds, delay)
            }
        }
        return output
    }

    func recordSendBatch(packetCount: Int, produceNanoseconds: UInt64, networkNanoseconds: UInt64) {
        guard Self.diagnosticsEnabled else { return }
        diagnosticBatches += 1
        diagnosticBatchPackets += packetCount
        diagnosticProduceNanoseconds += produceNanoseconds
        diagnosticNetworkNanoseconds += networkNanoseconds

        let now = DispatchTime.now().uptimeNanoseconds
        guard now - diagnosticStartedAt >= 500_000_000, let quicConnection else { return }
        var stats = quiche_stats()
        quiche_conn_stats(quicConnection, &stats)
        var path = quiche_path_stats()
        let pathResult = quiche_conn_path_stats(quicConnection, 0, &path)
        let elapsedMilliseconds = Double(now - diagnosticStartedAt) / 1_000_000
        let averagePacingMicroseconds = diagnosticFuturePacingPackets == 0 ? 0 :
            Double(diagnosticFuturePacingNanoseconds) / Double(diagnosticFuturePacingPackets) / 1_000
        let message = String(format:
            "GHOSTFILE_H3_DIAG role=%@ interval_ms=%.1f payload=%d batches=%d batch_packets=%d produce_ms=%.3f nw_wait_ms=%.3f datagrams=%d datagram_bytes=%d next_calls=%d send_done=%d pump_calls=%d stream_visits=%d body_attempts=%d body_blocked=%d body_accepted=%d pacing_future=%d pacing_avg_us=%.1f pacing_max_us=%.1f quic_sent=%zu quic_lost=%zu quic_retrans=%zu quic_lost_bytes=%llu flow_blocked=%llu stream_blocked=%llu path_ok=%d rtt_us=%.1f cwnd=%zu delivery_Bps=%llu pmtu=%zu",
            diagnosticRole,
            elapsedMilliseconds,
            Self.maximumUDPPayloadSize,
            diagnosticBatches,
            diagnosticBatchPackets,
            Double(diagnosticProduceNanoseconds) / 1_000_000,
            Double(diagnosticNetworkNanoseconds) / 1_000_000,
            diagnosticDatagrams,
            diagnosticDatagramBytes,
            diagnosticNextDatagramCalls,
            diagnosticSendDone,
            diagnosticPumpCalls,
            diagnosticStreamVisits,
            diagnosticBodyAttempts,
            diagnosticBodyBlocked,
            diagnosticBodyAcceptedBytes,
            diagnosticFuturePacingPackets,
            averagePacingMicroseconds,
            Double(diagnosticMaximumPacingNanoseconds) / 1_000,
            stats.sent,
            stats.lost,
            stats.retrans,
            stats.lost_bytes,
            stats.data_blocked_sent_count,
            stats.stream_data_blocked_sent_count,
            pathResult,
            Double(path.rtt) / 1_000,
            path.cwnd,
            path.delivery_rate,
            path.pmtu
        )
        NSLog("%@", message)
        diagnosticStartedAt = now
        diagnosticPumpCalls = 0
        diagnosticStreamVisits = 0
        diagnosticBodyAttempts = 0
        diagnosticBodyBlocked = 0
        diagnosticBodyAcceptedBytes = 0
        diagnosticNextDatagramCalls = 0
        diagnosticDatagrams = 0
        diagnosticDatagramBytes = 0
        diagnosticSendDone = 0
        diagnosticFuturePacingPackets = 0
        diagnosticFuturePacingNanoseconds = 0
        diagnosticMaximumPacingNanoseconds = 0
        diagnosticBatches = 0
        diagnosticBatchPackets = 0
        diagnosticProduceNanoseconds = 0
        diagnosticNetworkNanoseconds = 0
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
        try beginResponse(streamID: streamID, headers: headers, contentLength: body.count)
        guard !body.isEmpty else { return }
        try appendResponseBody(streamID: streamID, data: body, isFinal: true)
    }

    func beginResponse(streamID: UInt64, headers: [(String, String)], contentLength: Int) throws {
        guard quicConnection != nil, http3Connection != nil else {
            throw ConnectionError.http3("The HTTP/3 connection is not ready")
        }
        guard contentLength >= 0, pendingResponses[streamID] == nil else {
            throw ConnectionError.http3("Invalid or duplicate HTTP/3 response")
        }
        pendingResponses[streamID] = PendingHTTP3Response(
            headers: headers,
            expectedBodyLength: contentLength
        )
        try pumpResponses()
    }

    func appendResponseBody(streamID: UInt64, data: Data, isFinal: Bool) throws {
        guard var pending = pendingResponses[streamID] else {
            throw ConnectionError.http3("No pending HTTP/3 response for stream \(streamID)")
        }
        guard !pending.inputFinished,
              pending.receivedBodyLength <= pending.expectedBodyLength - data.count else {
            throw ConnectionError.http3("HTTP/3 response body exceeded its declared length")
        }
        pending.append(data)
        if isFinal {
            guard pending.receivedBodyLength == pending.expectedBodyLength else {
                throw ConnectionError.http3("Incomplete HTTP/3 response body")
            }
            pending.inputFinished = true
        }
        pendingResponses[streamID] = pending
        try pumpResponses()
    }

    func abandonResponse(streamID: UInt64) {
        pendingResponses.removeValue(forKey: streamID)
    }

    func resetResponse(streamID: UInt64, errorCode: UInt64 = 0x010c) {
        pendingResponses.removeValue(forKey: streamID)
        guard let quicConnection else { return }
        _ = quiche_conn_stream_shutdown(
            quicConnection,
            streamID,
            QUICHE_SHUTDOWN_WRITE,
            errorCode
        )
    }

    func takePeerTerminatedResponseStreamIDs() -> [UInt64] {
        defer { peerTerminatedResponseStreamIDs.removeAll(keepingCapacity: true) }
        return peerTerminatedResponseStreamIDs
    }

    func takeFailedResponseStreamIDs() -> [UInt64] {
        defer { failedResponseStreamIDs.removeAll(keepingCapacity: true) }
        return failedResponseStreamIDs
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
        if Self.diagnosticsEnabled { diagnosticPumpCalls += 1 }
        for streamID in Array(pendingResponses.keys) {
            if Self.diagnosticsEnabled { diagnosticStreamVisits += 1 }
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
                        pending.expectedBodyLength == 0
                    )
                }
                if result == Int32(QUICHE_H3_ERR_STREAM_BLOCKED.rawValue) ||
                    result == Int32(QUICHE_H3_ERR_DONE.rawValue) {
                    pendingResponses[streamID] = pending
                    continue
                }
                if Self.isPeerTerminatedStreamError(Int(result)) {
                    pendingResponses.removeValue(forKey: streamID)
                    peerTerminatedResponseStreamIDs.append(streamID)
                    continue
                }
                guard result == 0 else {
                    pendingResponses.removeValue(forKey: streamID)
                    failedResponseStreamIDs.append(streamID)
                    continue
                }
                pending.headersSent = true
                if pending.expectedBodyLength == 0 {
                    pendingResponses.removeValue(forKey: streamID)
                    continue
                }
            }
            while let chunk = pending.currentChunk {
                let offeredLength = min(16 * 1024, chunk.count - pending.chunkOffset)
                let isFinal = pending.inputFinished &&
                    pending.sentBodyLength + offeredLength == pending.expectedBodyLength
                let sent = chunk.withUnsafeBytes { bytes -> Int in
                    let base = bytes.bindMemory(to: UInt8.self).baseAddress?.advanced(by: pending.chunkOffset)
                    return Int(quiche_h3_send_body(
                        http3Connection,
                        quicConnection,
                        streamID,
                        base,
                        offeredLength,
                        isFinal
                    ))
                }
                if Self.diagnosticsEnabled {
                    diagnosticBodyAttempts += 1
                    if sent == Int(QUICHE_H3_ERR_DONE.rawValue) ||
                        sent == Int(QUICHE_H3_ERR_STREAM_BLOCKED.rawValue) {
                        diagnosticBodyBlocked += 1
                    } else if sent > 0 {
                        diagnosticBodyAcceptedBytes += sent
                    }
                }
                if sent == Int(QUICHE_H3_ERR_DONE.rawValue) ||
                    sent == Int(QUICHE_H3_ERR_STREAM_BLOCKED.rawValue) { break }
                if Self.isPeerTerminatedStreamError(sent) {
                    pendingResponses.removeValue(forKey: streamID)
                    peerTerminatedResponseStreamIDs.append(streamID)
                    break
                }
                guard sent > 0 else {
                    pendingResponses.removeValue(forKey: streamID)
                    failedResponseStreamIDs.append(streamID)
                    break
                }
                pending.consume(sent)
            }
            if pendingResponses[streamID] == nil {
                continue
            } else if pending.inputFinished && pending.sentBodyLength == pending.expectedBodyLength {
                pendingResponses.removeValue(forKey: streamID)
            } else {
                pendingResponses[streamID] = pending
            }
        }
    }

    private static func isPeerTerminatedStreamError(_ value: Int) -> Bool {
        value == Int(QUICHE_H3_ERR_REQUEST_CANCELLED.rawValue) ||
            value == Int(QUICHE_H3_TRANSPORT_ERR_STREAM_STOPPED.rawValue) ||
            value == Int(QUICHE_H3_TRANSPORT_ERR_STREAM_RESET.rawValue) ||
            value == Int(QUICHE_H3_TRANSPORT_ERR_INVALID_STREAM_STATE.rawValue) ||
            value == Int(QUICHE_H3_TRANSPORT_ERR_FINAL_SIZE.rawValue)
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
    let expectedBodyLength: Int
    var headersSent = false
    var chunks: [Data] = []
    var chunkIndex = 0
    var chunkOffset = 0
    var receivedBodyLength = 0
    var sentBodyLength = 0
    var inputFinished: Bool

    init(headers: [(String, String)], expectedBodyLength: Int) {
        self.headers = headers
        self.expectedBodyLength = expectedBodyLength
        self.inputFinished = expectedBodyLength == 0
    }

    var currentChunk: Data? {
        chunkIndex < chunks.count ? chunks[chunkIndex] : nil
    }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        chunks.append(data)
        receivedBodyLength += data.count
    }

    mutating func consume(_ count: Int) {
        chunkOffset += count
        sentBodyLength += count
        guard let chunk = currentChunk, chunkOffset == chunk.count else { return }
        chunkIndex += 1
        chunkOffset = 0
        if chunkIndex >= 8, chunkIndex * 2 >= chunks.count {
            chunks.removeFirst(chunkIndex)
            chunkIndex = 0
        }
    }
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

enum GhostFileNetworkDatagram {
    // Amortize Network.framework callback and actor-hop overhead while keeping
    // both the send queue and the receive window explicitly bounded.
    static let maximumSendBatchCount: Int = {
        guard let rawValue = ProcessInfo.processInfo.environment["GHOSTFILE_HTTP3_SEND_BATCH_COUNT"],
              let value = Int(rawValue), (1...1_024).contains(value) else {
            return 64
        }
        return value
    }()
    static let maximumReceiveCount = 64
}

extension NWConnection {
    func sendGhostFileDatagrams(_ datagrams: [Data]) async throws {
        guard !datagrams.isEmpty else { return }

        try await withCheckedThrowingContinuation { continuation in
            let completion = GhostFileDatagramBatchCompletion(
                count: datagrams.count,
                continuation: continuation
            )
            batch {
                for datagram in datagrams {
                    send(content: datagram, completion: .contentProcessed { error in
                        completion.completed(error: error)
                    })
                }
            }
        }
    }
}

private final class GhostFileDatagramBatchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var continuation: CheckedContinuation<Void, Error>?

    init(count: Int, continuation: CheckedContinuation<Void, Error>) {
        remaining = count
        self.continuation = continuation
    }

    func completed(error: NWError?) {
        var continuationToResume: CheckedContinuation<Void, Error>?
        var completionError: Error?
        lock.lock()
        remaining -= 1
        if let error, continuation != nil {
            continuationToResume = continuation
            continuation = nil
            completionError = error
        } else if remaining == 0, continuation != nil {
            continuationToResume = continuation
            continuation = nil
        }
        lock.unlock()

        guard let continuationToResume else { return }
        if let completionError {
            continuationToResume.resume(throwing: completionError)
        } else {
            continuationToResume.resume()
        }
    }
}
