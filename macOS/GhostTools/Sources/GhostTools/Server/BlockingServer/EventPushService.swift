import Foundation
import Darwin
import os

/// Event types pushed from guest to host over NDJSON. Pure value type — no
/// NIO/Network bindings.
enum PushEvent {
    case files([String])
    case urls([String])
    case log(String)
    case ports([PortInfo])
    case app(name: String, bundleId: String, iconBase64: String?)

    var jsonLine: String {
        switch self {
        case .files(let paths):
            let escaped = paths.map { escapeJSON($0) }
            return "{\"type\":\"files\",\"files\":[\(escaped.joined(separator: ","))]}"
        case .urls(let urls):
            let escaped = urls.map { escapeJSON($0) }
            return "{\"type\":\"urls\",\"urls\":[\(escaped.joined(separator: ","))]}"
        case .log(let message):
            return "{\"type\":\"log\",\"message\":\(escapeJSON(message))}"
        case .ports(let portInfos):
            let entries = portInfos.map { "{\"port\":\($0.port),\"process\":\(escapeJSON($0.process))}" }
            return "{\"type\":\"ports\",\"ports\":[\(entries.joined(separator: ","))]}"
        case .app(let name, let bundleId, let iconBase64):
            var json = "{\"type\":\"app\",\"name\":\(escapeJSON(name)),\"bundleId\":\(escapeJSON(bundleId))"
            if let icon = iconBase64 {
                json += ",\"icon\":\(escapeJSON(icon))"
            }
            json += "}"
            return json
        }
    }

    private func escapeJSON(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// Manages a single upgraded event-stream client attached via the unified
/// HTTP server on vsock port 5000. Guest services call `pushEvent(_:)` to
/// send NDJSON lines downstream.
///
/// Concurrency model:
/// - One accept thread reaps incoming connections; if a new client arrives
///   while one is connected, the old one is closed.
/// - The current client fd is guarded by a lock; `pushEvent` writes under
///   the lock with blocking I/O. Failed writes (EPIPE/ECONNRESET) drop the fd.
/// - A per-client reader thread blocks on `read()` and clears the fd on
///   EOF so we don't keep handing events to a dead socket.
final class EventPushService: @unchecked Sendable {
    static let shared = EventPushService()

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "EventPushService")

    private let clientLock = NSLock()
    private let writeLock = NSLock()
    private var clientFD: Int32 = -1
    /// Monotonically increasing id, bumped each time we install a new client
    /// fd. The reader thread carries the generation it was started with, so
    /// it only clears `clientFD` if it still owns it (avoids a benign race
    /// where a new connection arrives just as the old one tears down).
    private var clientGeneration: UInt64 = 0

    private var stopping = false

    private init() {}

    deinit { stop() }

    func start() throws {
        stopping = false
        Self.logger.info("Event push service attached to unified HTTP server on port 5000")
    }

    func stop() {
        stopping = true
        clearClient()
    }

    func serveUpgradedConnection(fd: Int32, prelude: Data = Data()) throws {
        let response = HTTPResponse(
            status: .switchingProtocols,
            headers: [
                "Upgrade": "event-stream",
                "Connection": "Upgrade",
            ]
        )
        try HTTPCodec.writeResponseHead(fd: fd, status: response.status, headers: response.headers)
        clearReceiveTimeout(fd: fd)
        configureSendTimeout(fd: fd)

        clientLock.lock()
        let oldFD = clientFD
        clientFD = fd
        clientGeneration &+= 1
        let generation = clientGeneration
        clientLock.unlock()

        if oldFD >= 0 {
            Darwin.shutdown(oldFD, SHUT_RDWR)
        }

        pushCurrentState()

        Self.logger.info("event-stream client attached fd=\(fd)")
        readerLoop(fd: fd, generation: generation, initialData: prelude)
    }

    // MARK: - Push API

    /// Sends a single NDJSON line to the connected client. No-op if there
    /// is no client. Safe to call from any thread.
    func pushEvent(_ event: PushEvent) {
        let line = event.jsonLine + "\n"
        let bytes = Array(line.utf8)

        clientLock.lock()
        let fd = clientFD
        let generation = clientGeneration
        guard fd >= 0 else {
            clientLock.unlock()
            return
        }
        let dupFD = Darwin.dup(fd)
        clientLock.unlock()
        guard dupFD >= 0 else { return }

        writeLock.lock()
        let ok = bytes.withUnsafeBufferPointer { ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            return Self.writeAll(fd: dupFD, ptr: base, count: ptr.count)
        }
        writeLock.unlock()
        Darwin.close(dupFD)
        if !ok {
            // Write failed — peer is gone. Tear down so the next event
            // doesn't waste time hitting the same dead fd.
            Self.logger.info("pushEvent write failed; closing client fd")
            clientLock.lock()
            if clientFD == fd {
                clientFD = -1
                clientGeneration &+= 1
                clientLock.unlock()
                Darwin.shutdown(fd, SHUT_RDWR)
            } else {
                clientLock.unlock()
            }
            return
        }

        clientLock.lock()
        if clientFD == fd && clientGeneration != generation {
            Self.logger.debug("event push write completed after client generation changed")
        }
        clientLock.unlock()
    }

    private func readerLoop(fd: Int32, generation: UInt64, initialData: Data) {
        if !initialData.isEmpty {
            Self.logger.debug("event-stream client sent \(initialData.count) bytes of upgrade prelude; ignoring")
        }
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            if n <= 0 { break }
            // Host shouldn't be sending anything; ignore inbound bytes.
        }
        // Clear the slot if this fd is still current.
        clientLock.lock()
        if clientFD == fd && clientGeneration == generation {
            clientFD = -1
            clientGeneration &+= 1
            clientLock.unlock()
            Self.logger.info("client disconnected fd=\(fd)")
        } else {
            clientLock.unlock()
        }
    }

    private func clearClient() {
        clientLock.lock()
        let fd = clientFD
        clientFD = -1
        clientGeneration &+= 1
        clientLock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    // MARK: - Helpers

    private static func writeAll(fd: Int32, ptr: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, ptr + offset, count - offset)
            if n > 0 { offset += n }
            else if n < 0 && errno == EINTR { continue }
            else { return false }
        }
        return true
    }

    private func clearReceiveTimeout(fd: Int32) {
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func configureSendTimeout(fd: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func pushCurrentState() {
        pushEvent(.files(FileService.shared.listOutgoingFiles()))
        pushEvent(.urls(URLService.shared.listPendingURLs()))
        pushEvent(.ports(PortScanner.shared.getListeningPortsWithProcess()))
        DispatchQueue.main.async {
            ForegroundAppService.shared.pushCurrentAppToConnectedClient()
        }
    }
}
