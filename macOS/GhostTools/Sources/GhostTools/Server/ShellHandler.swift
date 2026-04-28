import Foundation
import NIOCore
import NIOPosix
import NIOWebSocket
import CPty

/// WebSocket handler for interactive shell sessions on `/api/v1/shell`.
///
/// Protocol (after WebSocket upgrade):
///   - Binary frames: raw PTY data (both directions)
///   - Text frames: JSON control messages
///     - Client → Server: {"type":"resize","cols":120,"rows":40}
///     - Server → Client: {"type":"exit","code":0}
///
/// Query parameters on the upgrade request:
///   - cols: initial terminal columns (default 80)
///   - rows: initial terminal rows (default 24)
///   - Always runs user's login shell via /usr/bin/login
final class ShellWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private var masterFD: Int32 = -1
    private var shellPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private weak var channelRef: Channel?
    private var isCleaningUp = false
    private var processExited = false
    /// Serial queue for PTY I/O and process exit — prevents read/drain races.
    private let ptyQueue = DispatchQueue(label: "ghosttools.shell.pty")

    private let initialCols: UInt16
    private let initialRows: UInt16

    init(cols: UInt16 = 80, rows: UInt16 = 24) {
        self.initialCols = cols
        self.initialRows = rows
    }

    deinit {
        cleanup()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.channelRef = context.channel
        if context.channel.isActive {
            spawnShell(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.channelRef = context.channel
        // Guard against double-spawn if handlerAdded already started the shell
        if shellPID == 0 {
            spawnShell(context: context)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary:
            // Stdin data → PTY (off the event loop to avoid blocking on backpressure)
            guard masterFD >= 0 else { return }
            var frameData = frame.unmaskedData
            guard let bytes = frameData.readBytes(length: frameData.readableBytes) else { return }
            let fd = masterFD
            ptyQueue.async { [weak self] in
                guard let self = self, self.masterFD == fd else { return }
                if !self.writeAll(fd: fd, bytes: bytes) {
                    self.failSession("PTY write failed: errno \(errno)")
                }
            }

        case .text:
            // Control message (JSON)
            var textData = frame.unmaskedData
            guard let text = textData.readString(length: textData.readableBytes),
                  let jsonData = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            switch type {
            case "resize":
                handleResize(json: json)
            default:
                print("[Shell] Unknown control message type: \(type)")
            }

        case .connectionClose:
            var closeData = frame.unmaskedData
            let closeCode = closeData.readSlice(length: 2) ?? ByteBuffer()
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeCode)
            context.writeAndFlush(wrapOutboundOut(closeFrame)).whenComplete { _ in
                context.close(promise: nil)
            }

        case .ping:
            var pongData = frame.unmaskedData
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: pongData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        cleanup()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[Shell] Error: \(error)")
        cleanup()
        context.close(promise: nil)
    }

    private func failSession(_ message: String) {
        let trace = Thread.callStackSymbols.joined(separator: "\n")
        print("[Shell] FATAL: \(message)\n\(trace)")
        cleanup()
        channelRef?.eventLoop.execute { [weak self] in
            guard let self = self, let channel = self.channelRef, channel.isActive else { return }
            let buffer: ByteBuffer
            if let jsonBuffer = self.makeJSONBuffer(channel: channel, json: [
                "type": "error",
                "message": message
            ]) {
                buffer = jsonBuffer
            } else {
                var fallback = channel.allocator.buffer(capacity: 46)
                fallback.writeString(#"{"type":"error","message":"internal error"}"#)
                buffer = fallback
            }
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            channel.writeAndFlush(NIOAny(frame)).whenComplete { _ in
                let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
                channel.writeAndFlush(NIOAny(closeFrame)).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        }
    }

    // MARK: - Shell Lifecycle

    private func spawnShell(context: ChannelHandlerContext) {
        print("[Shell] Spawning login shell (\(initialCols)x\(initialRows))")

        var winSize = winsize()
        winSize.ws_col = initialCols
        winSize.ws_row = initialRows

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &winSize)

        if pid < 0 {
            print("[Shell] forkpty failed: \(errno)")
            sendControlMessage(context: context, json: [
                "type": "error",
                "message": "forkpty failed: \(String(cString: strerror(errno)))"
            ])
            context.close(promise: nil)
            return
        }

        if pid == 0 {
            // Child process — use login(1) to get a proper login session
            // with full environment (HOME, PATH, USER, etc.)
            setenv("TERM", "xterm-256color", 1)

            let loginArgs: [UnsafeMutablePointer<CChar>?] = [
                strdup("login"),
                strdup("-fp"),
                strdup(NSUserName()),
                nil
            ]
            execv("/usr/bin/login", loginArgs)
            _exit(127)
        }

        // Parent
        self.masterFD = masterFD
        self.shellPID = pid
        self.processExited = false
        self.isCleaningUp = false

        print("[Shell] Started PID \(pid) on fd \(masterFD)")

        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        // Send started message
        sendControlMessage(context: context, json: [
            "type": "started",
            "pid": pid,
        ])

        startReadingPTY(context: context)
        startWatchingProcess(context: context)
    }

    // MARK: - PTY I/O

    private func startReadingPTY(context: ChannelHandlerContext) {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ptyQueue)

        source.setEventHandler { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }

            var buf = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.read(fd, &buf, buf.count)

            if n > 0 {
                let channel = self.channelRef
                // Copy the data before crossing to the event loop
                let bytes = Array(buf[0..<n])
                channel?.eventLoop.execute {
                    guard let channel = channel, channel.isActive else { return }
                    var buffer = channel.allocator.buffer(capacity: n)
                    buffer.writeBytes(bytes)
                    let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                    channel.writeAndFlush(NIOAny(frame), promise: nil)
                }
            } else if n == 0 {
                source.cancel()
                self.readSource = nil
            } else if n < 0 && errno != EAGAIN && errno != EINTR {
                source.cancel()
                self.readSource = nil
                self.failSession("PTY read failed: errno \(errno)")
            }
        }

        source.resume()
        self.readSource = source
    }

    private func startWatchingProcess(context: ChannelHandlerContext) {
        let source = DispatchSource.makeProcessSource(
            identifier: shellPID,
            eventMask: .exit,
            queue: ptyQueue
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            waitpid(self.shellPID, &status, 0)
            self.processExited = true

            let exitCode: Int32
            if (status & 0x7f) == 0 {
                exitCode = (status >> 8) & 0xff
            } else {
                exitCode = -1
            }
            print("[Shell] PID \(self.shellPID) exited with code \(exitCode)")

            // Drain remaining PTY output: read until EOF, then close.
            // This runs on the same serial queue as the read source,
            // so no concurrent reads can race with us.
            let ptyFD = self.masterFD
            if ptyFD >= 0 {
                self.readSource?.cancel()
                self.readSource = nil

                // Synchronously drain any remaining bytes from the PTY
                var buf = [UInt8](repeating: 0, count: 16384)
                while true {
                    let n = Darwin.read(ptyFD, &buf, buf.count)
                    if n > 0 {
                        let bytes = Array(buf[0..<n])
                        let channel = self.channelRef
                        channel?.eventLoop.execute {
                            guard let channel = channel, channel.isActive else { return }
                            var buffer = channel.allocator.buffer(capacity: bytes.count)
                            buffer.writeBytes(bytes)
                            let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                            channel.writeAndFlush(NIOAny(frame), promise: nil)
                        }
                    } else {
                        break
                    }
                }
            }

            // Send exit code and close the WebSocket on the event loop
            guard let channel = self.channelRef, channel.isActive else { return }
            channel.eventLoop.execute {
                let json = "{\"type\":\"exit\",\"code\":\(exitCode)}"
                var buf = channel.allocator.buffer(capacity: json.utf8.count)
                buf.writeString(json)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                channel.writeAndFlush(NIOAny(frame)).whenComplete { _ in
                    let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: ByteBuffer())
                    channel.writeAndFlush(NIOAny(closeFrame)).whenComplete { _ in
                        channel.close(promise: nil)
                    }
                }
            }
        }

        source.resume()
        self.waitSource = source
    }

    // MARK: - Control Messages

    private func handleResize(json: [String: Any]) {
        guard let cols = json["cols"] as? Int, let rows = json["rows"] as? Int,
              cols > 0, rows > 0, masterFD >= 0 else {
            return
        }

        var winSize = winsize()
        winSize.ws_col = UInt16(cols)
        winSize.ws_row = UInt16(rows)
        _ = ioctl(masterFD, TIOCSWINSZ, &winSize)

        print("[Shell] Resized to \(cols)x\(rows)")
    }

    private func sendControlMessage(context: ChannelHandlerContext, json: [String: Any]) {
        guard let buffer = makeJSONBuffer(channel: context.channel, json: json) else {
            failSession("Failed to serialize shell control message")
            return
        }
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    private func makeJSONBuffer(channel: Channel, json: [String: Any]) -> ByteBuffer? {
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json) else {
            return nil
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        return buffer
    }

    // MARK: - Cleanup

    private func cleanup() {
        ptyQueue.async { [weak self] in
            guard let self = self, !self.isCleaningUp else { return }
            self.isCleaningUp = true

            self.readSource?.cancel()
            self.readSource = nil
            self.waitSource?.cancel()
            self.waitSource = nil

            let fd = self.masterFD
            let pid = self.shellPID
            let shouldSignalProcess = !self.processExited && pid > 0
            self.masterFD = -1
            self.shellPID = 0

            if shouldSignalProcess {
                _ = kill(pid, SIGHUP)
            }
            if fd >= 0 { Darwin.close(fd) }
        }
    }

    /// Write all bytes to fd, retrying on short writes and EAGAIN.
    /// Bails out if masterFD is invalidated (cleanup in progress).
    @discardableResult
    private func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return true }
            var offset = 0
            while offset < ptr.count {
                let n = Darwin.write(fd, base + offset, ptr.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EAGAIN {
                    if self.masterFD < 0 { return false } // cleanup invalidated the fd
                    usleep(1000)
                } else {
                    return false // real error or fd closed
                }
            }
            return true
        }
    }
}
