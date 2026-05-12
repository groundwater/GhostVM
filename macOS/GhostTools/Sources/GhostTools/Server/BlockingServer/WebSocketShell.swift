import Foundation
import Darwin
import CPty
import os

/// Server-side WebSocket "shell" endpoint. Performs the WS handshake on a
/// blocking fd, spawns a login PTY, and bridges WS frames ↔ PTY bytes using
/// thread-per-direction blocking I/O. Mirrors the host-side vmctl shell
/// code exactly — including the WS frame format we already know works.
enum WebSocketShell {

    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "WebSocketShell")

    struct LaunchConfiguration {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]

        static func login(term: String) -> LaunchConfiguration {
            let user = ProcessInfo.processInfo.environment["USER"] ?? "root"
            return LaunchConfiguration(
                executablePath: "/usr/bin/login",
                arguments: ["login", "-fp", user],
                environment: ["TERM": term]
            )
        }
    }

    static func handleUpgradeAndRun(
        fd: Int32,
        request: HTTPRequest,
        cols: UInt16,
        rows: UInt16,
        term: String,
        prelude: Data = Data()
    ) throws {
        try handleUpgradeAndRun(
            fd: fd,
            request: request,
            cols: cols,
            rows: rows,
            term: term,
            prelude: prelude,
            launchConfiguration: .login(term: term)
        )
    }

    static func handleUpgradeAndRun(
        fd: Int32,
        request: HTTPRequest,
        cols: UInt16,
        rows: UInt16,
        term: String,
        prelude: Data = Data(),
        launchConfiguration: LaunchConfiguration
    ) throws {
        // 1. WS handshake.
        guard let key = request.header("Sec-WebSocket-Key") else {
            try HTTPCodec.writeResponse(.error(.badRequest, message: "missing Sec-WebSocket-Key"), fd: fd)
            return
        }
        let accept = wsAcceptKey(for: key)
        try HTTPCodec.writeResponseHead(
            fd: fd,
            status: .switchingProtocols,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Accept": accept,
            ]
        )

        // ConnectionWorker sets SO_RCVTIMEO=60s for HTTP requests. A WS shell
        // sits idle for arbitrarily long, so clear the timeout — otherwise
        // socket reads start returning EAGAIN once a minute and the input
        // bridge silently exits.
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))

        Self.logger.info("WS shell upgraded fd=\(fd) cols=\(cols) rows=\(rows) term=\(term, privacy: .public)")

        let (pid, masterFD) = try Self.spawnPTY(
            rows: rows,
            cols: cols,
            launchConfiguration: launchConfiguration
        )

        defer {
            // When the bridge returns, reap the shell.
            kill(pid, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            Darwin.close(masterFD)
        }

        // 3. Bidirectional bridge.
        //    - socket → PTY: parse WS frames, write payload to masterFD
        //    - PTY → socket: read masterFD, frame it as WS binary, write to socket
        let group = DispatchGroup()
        let socketWriter = LockedFDWriter(fd: fd)

        // socket → PTY
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var parser = WSFrameParser()
            var buf = [UInt8](repeating: 0, count: 16384)
            if !prelude.isEmpty {
                parser.feed(Array(prelude))
            }
            outer: while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                if n <= 0 { break }
                parser.feed(Array(buf[0..<n]))
                while let frame = parser.nextFrame() {
                    switch frame.opcode {
                    case .binary:
                        // Raw keystrokes → PTY input.
                        if !frame.payload.isEmpty {
                            _ = frame.payload.withUnsafeBufferPointer { ptr -> Bool in
                                guard let base = ptr.baseAddress else { return false }
                                return Self.writeAll(fd: masterFD, ptr: base, count: ptr.count)
                            }
                        }
                    case .text:
                        // Control message (JSON). Currently only {"type":"resize"}.
                        Self.handleControlMessage(payload: frame.payload, masterFD: masterFD)
                    case .close:
                        break outer
                    case .ping:
                        // Reply pong with same payload.
                        let pong = WSFrameEncoder.encode(opcode: .pong, payload: frame.payload, mask: false)
                        _ = socketWriter.write(pong)
                    default:
                        break
                    }
                }
            }
            kill(pid, SIGHUP)
            group.leave()
        }

        // PTY → socket
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = Darwin.read(masterFD, &buf, buf.count)
                if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                if n <= 0 { break }
                let frame = WSFrameEncoder.encode(opcode: .binary, payload: Array(buf[0..<n]), mask: false)
                let ok = socketWriter.write(frame)
                if !ok { break }
            }
            // Send a Close frame so the client cleans up promptly.
            let closeFrame = WSFrameEncoder.encode(opcode: .close, payload: [], mask: false)
            _ = socketWriter.write(closeFrame)
            group.leave()
        }

        group.wait()
    }

    // MARK: - Control messages

    /// Parses a JSON control message from a WebSocket text frame and applies
    /// it to the PTY. Currently supports `{"type":"resize","cols":N,"rows":M}`,
    /// which calls `TIOCSWINSZ` on the master fd — the kernel then auto-posts
    /// SIGWINCH to the slave-side foreground process group so TUI apps redraw
    /// to the new size.
    fileprivate static func handleControlMessage(payload: [UInt8], masterFD: Int32) {
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        switch type {
        case "resize":
            guard let cols = json["cols"] as? Int,
                  let rows = json["rows"] as? Int,
                  cols > 0, rows > 0,
                  cols <= Int(UInt16.max), rows <= Int(UInt16.max) else {
                return
            }
            var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(masterFD, TIOCSWINSZ, &ws)
            Self.logger.debug("resize → cols=\(cols) rows=\(rows)")
        default:
            Self.logger.debug("ignoring unknown control message: \(type, privacy: .public)")
        }
    }

    // MARK: - Helpers

    /// RFC 6455 server-side accept-key computation: SHA1(key + GUID), base64.
    private static func wsAcceptKey(for clientKey: String) -> String {
        let combined = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = sha1(combined)
        return digest.base64EncodedString()
    }

    private static func sha1(_ input: String) -> Data {
        var hash = [UInt8](repeating: 0, count: 20)
        input.withCString { ptr in
            _ = CC_SHA1_Local(ptr, UInt32(strlen(ptr)), &hash)
        }
        return Data(hash)
    }

    private static func spawnPTY(
        rows: UInt16,
        cols: UInt16,
        launchConfiguration: LaunchConfiguration
    ) throws -> (pid: pid_t, masterFD: Int32) {
        var masterFDVar: Int32 = -1
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&masterFDVar, nil, nil, &ws)
        if pid < 0 {
            Self.logger.error("forkpty failed: errno \(errno)")
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if pid == 0 {
            for (key, value) in launchConfiguration.environment {
                setenv(key, value, 1)
            }
            let cStrings = launchConfiguration.arguments.map { argument in
                argument.withCString { strdup($0) }
            }
            let argv = cStrings + [nil]
            defer {
                for pointer in cStrings {
                    free(pointer)
                }
            }
            _ = execv(launchConfiguration.executablePath, argv)
            Darwin._exit(1)
        }
        return (pid, masterFDVar)
    }

    fileprivate static func writeAll(fd: Int32, ptr: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, ptr + offset, count - offset)
            if n > 0 { offset += n }
            else if n < 0 && errno == EINTR { continue }
            else { return false }
        }
        return true
    }
}

private final class LockedFDWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()

    init(fd: Int32) {
        self.fd = fd
    }

    func write(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return false }
            lock.lock()
            defer { lock.unlock() }
            return WebSocketShell.writeAll(fd: fd, ptr: base, count: ptr.count)
        }
    }
}

// SHA1 via libsystem's CommonCrypto. We can't import CommonCrypto directly
// from a Swift package without a bridging header, so declare the symbol.
@_silgen_name("CC_SHA1") private func CC_SHA1_Local(
    _ data: UnsafeRawPointer,
    _ len: UInt32,
    _ md: UnsafeMutablePointer<UInt8>
) -> UnsafeMutablePointer<UInt8>

// MARK: - WS frame parser / encoder
//
// Minimal RFC-6455 implementation, masking optional. Server reads masked
// frames from the client and sends unmasked frames back.

enum WSOpcode: UInt8 {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

struct WSFrame {
    let opcode: WSOpcode
    let payload: [UInt8]
}

struct WSFrameParser {
    private static let maxPayloadBytes = 16 * 1024 * 1024
    private var buffer: [UInt8] = []

    mutating func feed(_ data: [UInt8]) {
        buffer.append(contentsOf: data)
    }

    mutating func nextFrame() -> WSFrame? {
        guard buffer.count >= 2 else { return nil }

        let fin = (buffer[0] & 0x80) != 0
        let opcodeByte = buffer[0] & 0x0F
        guard let opcode = WSOpcode(rawValue: opcodeByte) else {
            buffer.removeAll()
            return nil
        }
        guard fin else {
            return WSFrame(opcode: .close, payload: [])
        }
        let masked = (buffer[1] & 0x80) != 0
        var payloadLen = Int(buffer[1] & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            payloadLen = (Int(buffer[offset]) << 8) | Int(buffer[offset + 1])
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen = (payloadLen << 8) | Int(buffer[offset + i])
            }
            offset += 8
        }

        guard payloadLen <= Self.maxPayloadBytes else {
            buffer.removeAll()
            return nil
        }

        var maskKey = [UInt8]()
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskKey = Array(buffer[offset..<offset + 4])
            offset += 4
        }

        guard buffer.count >= offset + payloadLen else { return nil }
        var payload = Array(buffer[offset..<offset + payloadLen])
        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }
        buffer.removeFirst(offset + payloadLen)
        return WSFrame(opcode: opcode, payload: payload)
    }
}

enum WSFrameEncoder {
    /// Encodes a single FIN=1 frame. Server frames are unmasked; client
    /// frames are masked (caller picks `mask`).
    static func encode(opcode: WSOpcode, payload: [UInt8], mask: Bool) -> [UInt8] {
        var frame: [UInt8] = []
        frame.append(0x80 | opcode.rawValue) // FIN=1
        let maskBit: UInt8 = mask ? 0x80 : 0x00
        if payload.count <= 125 {
            frame.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(maskBit | 127)
            let len64 = UInt64(payload.count)
            for i in (0..<8).reversed() {
                frame.append(UInt8((len64 >> (i * 8)) & 0xFF))
            }
        }
        if mask {
            var key = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytesShim(4, &key)
            frame.append(contentsOf: key)
            for (i, b) in payload.enumerated() {
                frame.append(b ^ key[i % 4])
            }
        } else {
            frame.append(contentsOf: payload)
        }
        return frame
    }
}

private func SecRandomCopyBytesShim(_ count: Int, _ bytes: inout [UInt8]) -> Int {
    for i in 0..<count {
        bytes[i] = UInt8.random(in: 0...255)
    }
    return 0
}
