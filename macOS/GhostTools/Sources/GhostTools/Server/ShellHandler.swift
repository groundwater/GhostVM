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
///   - command: shell to run (default: user's login shell)
final class ShellWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private var masterFD: Int32 = -1
    private var shellPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private weak var channelRef: Channel?

    private let command: String
    private let initialCols: UInt16
    private let initialRows: UInt16

    init(command: String? = nil, cols: UInt16 = 80, rows: UInt16 = 24) {
        self.command = command ?? ShellWebSocketHandler.defaultShell()
        self.initialCols = cols
        self.initialRows = rows
    }

    deinit {
        cleanup()
    }

    func channelActive(context: ChannelHandlerContext) {
        self.channelRef = context.channel
        spawnShell(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary:
            // Stdin data → PTY
            guard masterFD >= 0 else { return }
            var frameData = frame.unmaskedData
            guard let bytes = frameData.readBytes(length: frameData.readableBytes) else { return }
            bytes.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress, ptr.count > 0 {
                    _ = Darwin.write(masterFD, base, ptr.count)
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

    // MARK: - Shell Lifecycle

    private func spawnShell(context: ChannelHandlerContext) {
        print("[Shell] Spawning: \(command) (\(initialCols)x\(initialRows))")

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
            // Child process
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)

            let shellBasename = "-" + (command as NSString).lastPathComponent
            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(shellBasename),
                nil
            ]
            execv(command, argv)
            _exit(127)
        }

        // Parent
        self.masterFD = masterFD
        self.shellPID = pid

        print("[Shell] Started PID \(pid) on fd \(masterFD)")

        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        // Send started message
        sendControlMessage(context: context, json: [
            "type": "started",
            "pid": pid,
            "command": command
        ])

        startReadingPTY(context: context)
        startWatchingProcess(context: context)
    }

    // MARK: - PTY I/O

    private func startReadingPTY(context: ChannelHandlerContext) {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))

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
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }

        source.resume()
        self.readSource = source
    }

    private func startWatchingProcess(context: ChannelHandlerContext) {
        let source = DispatchSource.makeProcessSource(
            identifier: shellPID,
            eventMask: .exit,
            queue: .global(qos: .userInitiated)
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            waitpid(self.shellPID, &status, 0)

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
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let str = String(data: data, encoding: .utf8) else { return }
        var buffer = context.channel.allocator.buffer(capacity: str.utf8.count)
        buffer.writeString(str)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }

    // MARK: - Cleanup

    private func cleanup() {
        readSource?.cancel()
        readSource = nil
        waitSource?.cancel()
        waitSource = nil

        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }

        if shellPID > 0 {
            kill(shellPID, SIGHUP)
            shellPID = 0
        }
    }

    private static func defaultShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }
}
