import Foundation
import Darwin
import os

/// Owns one accepted client fd from `accept()` to `close()`. Reads one HTTP
/// request, dispatches to the router (or to the WebSocket upgrade path),
/// writes the response, and closes. No keep-alive in v1 — one request per
/// connection, then close.
final class ConnectionWorker {
    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "ConnectionWorker")

    private let fd: Int32
    private let router: Router

    init(fd: Int32, router: Router) {
        self.fd = fd
        self.router = router
    }

    func run() {
        defer { Darwin.close(fd) }

        // Set a receive timeout so that a buggy/silent peer can't pin this
        // thread forever. Generous default (60 s) — long-running endpoints
        // (file uploads) reset their progress every chunk, which keeps the
        // timer fresh because each successful read() resets it.
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let request: HTTPRequest
        let prelude: Data
        do {
            (request, prelude) = try HTTPCodec.readRequest(fd: fd)
        } catch {
            Self.logger.error("readRequest failed: \(String(describing: error), privacy: .public)")
            // Best-effort error reply (may itself fail if the peer is gone).
            try? HTTPCodec.writeResponse(.error(.badRequest, message: "\(error)"), fd: fd)
            return
        }

        Self.logger.debug("request \(request.method.rawValue, privacy: .public) \(request.path, privacy: .public)")

        // WebSocket upgrade — /api/v1/shell — is handled specially. The
        // worker hands the fd to the WS shell after the handshake succeeds.
        let pathOnly = request.path.components(separatedBy: "?").first ?? request.path
        if pathOnly == "/api/v1/shell" {
            let cols = parseUInt16Query(request.path, key: "cols") ?? 80
            let rows = parseUInt16Query(request.path, key: "rows") ?? 24
            let term = parseStringQuery(request.path, key: "term") ?? "xterm-256color"
            do {
                try WebSocketShell.handleUpgradeAndRun(
                    fd: fd,
                    request: request,
                    cols: cols,
                    rows: rows,
                    term: term,
                    prelude: prelude
                )
            } catch {
                Self.logger.error("ws shell failed: \(String(describing: error), privacy: .public)")
            }
            return
        }
        if pathOnly == "/api/v1/tunnel-connect" {
            do {
                try TunnelService.shared.handleUpgrade(fd: fd, request: request, prelude: prelude)
            } catch {
                Self.logger.error("tunnel upgrade failed: \(String(describing: error), privacy: .public)")
            }
            return
        }
        if pathOnly == "/api/v1/event-stream" {
            do {
                try EventPushService.shared.serveUpgradedConnection(fd: fd, prelude: prelude)
            } catch {
                Self.logger.error("event-stream upgrade failed: \(String(describing: error), privacy: .public)")
            }
            return
        }

        // Pick the body framing the way swift-nio's HTTPRequestDecoder did.
        // RFC 7230 §3.3.3: Transfer-Encoding wins over Content-Length.
        let framing: BodyFraming
        let te = request.header("transfer-encoding")?.lowercased()
        if let te, te.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("chunked") {
            framing = .chunked
        } else if let cl = request.contentLength {
            framing = .knownLength(cl)
        } else {
            framing = .eof
        }
        let body = BodyReader(fd: fd, framing: framing, prelude: prelude)

        let response: HTTPResponse
        do {
            response = try router.route(request: request, body: body)
        } catch {
            Self.logger.error("router threw: \(String(describing: error), privacy: .public)")
            response = .error(.internalServerError, message: String(describing: error))
        }

        do {
            try HTTPCodec.writeResponse(response, fd: fd)
        } catch {
            Self.logger.error("writeResponse failed: \(String(describing: error), privacy: .public)")
        }

        // Make a best effort to drain unread body bytes after the response
        // has already been sent. The connection is closed either way.
        body.discard()
    }

    private func parseUInt16Query(_ path: String, key: String) -> UInt16? {
        guard let raw = parseStringQuery(path, key: key) else { return nil }
        return UInt16(raw)
    }

    private func parseStringQuery(_ path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: queryStart)...])
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 && parts[0] == key {
                let value = String(parts[1])
                return value.removingPercentEncoding ?? value
            }
        }
        return nil
    }
}
