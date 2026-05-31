import Foundation
import Darwin
import os

/// Operational/runtime error reported by the tunnel for telemetry surfaces.
struct TunnelRuntimeError: Sendable {
    enum Phase: String, Sendable {
        case handshakeRead
        case handshakeProtocol
        case connectLocal
        case bridge
    }

    let phase: Phase
    let message: String
    let targetPort: UInt16?
    let timestamp: Date

    init(phase: Phase, message: String, targetPort: UInt16? = nil, timestamp: Date = Date()) {
        self.phase = phase
        self.message = message
        self.targetPort = targetPort
        self.timestamp = timestamp
    }
}

/// Upgrade-only tunnel service attached to the unified HTTP server on vsock
/// port 5000. After a successful `101 Switching Protocols` response, the
/// connection becomes a raw byte bridge to `127.0.0.1:<Tunnel-Port>`.
final class TunnelService: @unchecked Sendable {
    static let shared = TunnelService()

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "TunnelService")

    var onStatusChange: ((Bool) -> Void)?
    var onOperationalError: ((TunnelRuntimeError) -> Void)?
    var onConnectionSuccess: (() -> Void)?

    private init() {}

    func start() throws {
        Self.logger.info("Tunnel service attached to unified HTTP server on port 5000")
        onStatusChange?(true)
    }

    func stop() {
        onStatusChange?(false)
    }

    func handleUpgrade(fd: Int32, request: HTTPRequest, prelude: Data = Data()) throws {
        guard let portText = request.header("Tunnel-Port") else {
            try HTTPCodec.writeResponse(.error(.badRequest, message: "Missing Tunnel-Port header"), fd: fd)
            report(.init(phase: .handshakeRead, message: "Missing Tunnel-Port header"), id: UUID().uuidString)
            return
        }
        guard let targetPort = UInt16(portText) else {
            try HTTPCodec.writeResponse(.error(.badRequest, message: "Invalid Tunnel-Port header"), fd: fd)
            report(.init(phase: .handshakeProtocol, message: "Invalid Tunnel-Port header '\(portText)'"), id: UUID().uuidString)
            return
        }

        let connectionID = UUID().uuidString
        let tcpFD = socket(AF_INET, SOCK_STREAM, 0)
        if tcpFD < 0 {
            try? HTTPCodec.writeResponse(.error(.badGateway, message: "socket() failed"), fd: fd)
            report(.init(phase: .connectLocal, message: "socket() failed errno=\(errno)", targetPort: targetPort), id: connectionID)
            return
        }
        var bridgeStarted = false
        defer {
            if !bridgeStarted {
                Darwin.close(tcpFD)
            }
        }

        var sa = sockaddr_in()
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = in_port_t(targetPort.bigEndian)
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &sa) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(tcpFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult != 0 {
            let e = errno
            try? HTTPCodec.writeResponse(.error(.badGateway, message: "Connection refused to port \(targetPort)"), fd: fd)
            report(.init(phase: .connectLocal, message: "connect() failed errno=\(e)", targetPort: targetPort), id: connectionID)
            Darwin.close(tcpFD)
            return
        }

        try HTTPCodec.writeResponseHead(
            fd: fd,
            status: .switchingProtocols,
            headers: [
                "Upgrade": "tunnel",
                "Connection": "Upgrade",
            ]
        )
        clearReceiveTimeout(fd: fd)
        configureSendTimeout(fd: fd)
        configureSendTimeout(fd: tcpFD)
        if !prelude.isEmpty {
            try HTTPCodec.writeAll(fd: tcpFD, data: prelude)
        }
        onConnectionSuccess?()
        Self.logger.info("unified tunnel bridge established id=\(connectionID, privacy: .public) targetPort=\(targetPort) tcpFD=\(tcpFD)")
        bridgeStarted = true
        bridgeBytes(srcFD: fd, dstFD: tcpFD, connectionID: connectionID, targetPort: targetPort, closeSourceFD: false)
    }

    private func bridgeBytes(srcFD: Int32, dstFD: Int32, connectionID: String, targetPort: UInt16, closeSourceFD: Bool) {
        let group = DispatchGroup()

        group.enter()
        let aToB = Thread { [weak self] in
            self?.pumpOneWay(from: srcFD, to: dstFD, label: "tunnel", connectionID: connectionID, targetPort: targetPort)
            group.leave()
        }
        aToB.name = "TunnelService-pump-\(srcFD)→\(dstFD)"
        aToB.start()

        group.enter()
        pumpOneWay(from: dstFD, to: srcFD, label: "tunnel-reverse", connectionID: connectionID, targetPort: targetPort)
        group.leave()

        group.wait()
        if closeSourceFD {
            Darwin.close(srcFD)
        }
        Darwin.close(dstFD)
        Self.logger.info("bridge closed id=\(connectionID, privacy: .public) targetPort=\(targetPort)")
    }

    private func pumpOneWay(from src: Int32, to dst: Int32, label: String, connectionID: String, targetPort: UInt16) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(src, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if n <= 0 {
                _ = Darwin.shutdown(dst, SHUT_WR)
                return
            }
            let ok = buf.withUnsafeBufferPointer { ptr -> Bool in
                guard let base = ptr.baseAddress else { return false }
                return Self.writeAll(fd: dst, ptr: base, count: n)
            }
            if !ok {
                report(.init(phase: .bridge, message: "write failed in \(label)", targetPort: targetPort), id: connectionID)
                _ = Darwin.shutdown(dst, SHUT_WR)
                return
            }
        }
    }

    private func report(_ error: TunnelRuntimeError, id: String) {
        let portText = error.targetPort.map(String.init) ?? "none"
        if error.phase == .bridge {
            Self.logger.warning("Operational tunnel error id=\(id, privacy: .public) phase=\(error.phase.rawValue, privacy: .public) targetPort=\(portText, privacy: .public): \(error.message, privacy: .public)")
        } else {
            Self.logger.error("Operational tunnel error id=\(id, privacy: .public) phase=\(error.phase.rawValue, privacy: .public) targetPort=\(portText, privacy: .public): \(error.message, privacy: .public)")
        }
        onOperationalError?(error)
    }

    private static func writeAll(fd: Int32, ptr: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, ptr + offset, count - offset)
            if n > 0 {
                offset += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    private func clearReceiveTimeout(fd: Int32) {
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func configureSendTimeout(fd: Int32) {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
