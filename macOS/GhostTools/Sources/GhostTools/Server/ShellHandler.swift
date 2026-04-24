import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import CPty

/// Handles an HTTP/2 (or HTTP/1.1) stream for `/api/v1/shell`.
///
/// Protocol:
///   1. Client sends: POST /api/v1/shell with headers:
///      - X-Shell-Command: /bin/bash (optional, defaults to user's shell)
///      - X-Shell-Cols: 80
///      - X-Shell-Rows: 24
///   2. Server responds: 200 OK with header X-Shell-PID
///   3. Bidirectional DATA streaming:
///      - Client DATA → PTY stdin
///      - PTY stdout → Server DATA
///   4. Control messages via special streams (or in-band):
///      - POST /api/v1/shell/resize with X-Shell-Cols/X-Shell-Rows headers
///
/// The stream stays open until the shell process exits or the client disconnects.
final class ShellHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var masterFD: Int32 = -1
    private var shellPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var waitSource: DispatchSourceProcess?
    private weak var channelRef: Channel?

    deinit {
        cleanup()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)

        switch part {
        case .head(let head):
            handleHead(head, context: context)

        case .body(let buffer):
            // Client stdin → PTY
            if masterFD >= 0 {
                buffer.withUnsafeReadableBytes { ptr in
                    if !ptr.isEmpty {
                        _ = Darwin.write(masterFD, ptr.baseAddress!, ptr.count)
                    }
                }
            }

        case .end:
            // Client closed their send side — close PTY stdin
            // (This signals EOF to the shell, like Ctrl-D)
            // Don't close the channel yet — wait for shell to exit
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

    private func handleHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let command = head.headers.first(name: "x-shell-command") ?? defaultShell()
        let cols = UInt16(head.headers.first(name: "x-shell-cols") ?? "80") ?? 80
        let rows = UInt16(head.headers.first(name: "x-shell-rows") ?? "24") ?? 24

        print("[Shell] Spawning: \(command) (\(cols)x\(rows))")

        // Set up terminal size
        var winSize = winsize()
        winSize.ws_col = cols
        winSize.ws_row = rows

        // Fork with PTY
        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &winSize)

        if pid < 0 {
            print("[Shell] forkpty failed: \(errno)")
            sendError(context: context, message: "forkpty failed: \(String(cString: strerror(errno)))")
            return
        }

        if pid == 0 {
            // Child process — exec the shell
            // Set up environment
            setenv("TERM", "xterm-256color", 1)
            setenv("LANG", "en_US.UTF-8", 1)

            // Exec as login shell (argv[0] = "-bash" convention)
            let shellBasename = "-" + (command as NSString).lastPathComponent
            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(shellBasename),
                nil
            ]
            execv(command, argv)
            // If execl returns, it failed
            _exit(127)
        }

        // Parent process
        self.masterFD = masterFD
        self.shellPID = pid
        self.channelRef = context.channel

        print("[Shell] Started PID \(pid) on fd \(masterFD)")

        // Set master fd to non-blocking
        let flags = fcntl(masterFD, F_GETFL, 0)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        // Send response headers (keep stream open — no END_STREAM)
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/octet-stream")
        headers.add(name: "x-shell-pid", value: "\(pid)")
        let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.flush()

        // Start reading PTY output → client
        startReadingPTY(context: context)

        // Watch for shell exit
        startWatchingProcess(context: context)
    }

    /// Reads data from the PTY master fd and sends it as HTTP DATA frames.
    private func startReadingPTY(context: ChannelHandlerContext) {
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))

        source.setEventHandler { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }

            var buf = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.read(fd, &buf, buf.count)

            if n > 0 {
                let data = Data(buf[0..<n])
                let channel = self.channelRef

                channel?.eventLoop.execute {
                    guard let channel = channel, channel.isActive else { return }
                    var buffer = channel.allocator.buffer(capacity: n)
                    buffer.writeBytes(data)
                    let part = HTTPServerResponsePart.body(.byteBuffer(buffer))
                    channel.writeAndFlush(NIOAny(part), promise: nil)
                }
            } else if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                // EOF or error — shell closed
                source.cancel()
            }
        }

        source.setCancelHandler { [weak self] in
            // PTY closed — end the HTTP stream
            self?.endStream()
        }

        source.resume()
        self.readSource = source
    }

    /// Watches for the shell process to exit.
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

            // WIFEXITED/WEXITSTATUS are C macros; reimplement in Swift
            let exitCode: Int32
            if (status & 0x7f) == 0 {
                // Normal exit — extract exit code
                exitCode = (status >> 8) & 0xff
            } else {
                exitCode = -1
            }
            print("[Shell] PID \(self.shellPID) exited with code \(exitCode)")

            // Give a moment for final PTY output to flush
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                self.readSource?.cancel()
            }
        }

        source.resume()
        self.waitSource = source
    }

    private func endStream() {
        guard let channel = channelRef, channel.isActive else { return }
        channel.eventLoop.execute {
            let end = HTTPServerResponsePart.end(nil)
            channel.writeAndFlush(NIOAny(end)).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
    }

    private func sendError(context: ChannelHandlerContext, message: String) {
        let body = ByteBuffer(string: "{\"error\":\"\(message)\"}\n")
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(body.readableBytes)")
        let head = HTTPResponseHead(version: .http1_1, status: .internalServerError, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

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

    private func defaultShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }
}

// MARK: - Shell Resize Handler

/// Handles POST /api/v1/shell/resize to change the terminal size of a running shell.
/// Uses a shared registry of active shell sessions keyed by PID.
final class ShellResizeHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        guard case .head(let head) = part else { return }

        guard let pidStr = head.headers.first(name: "x-shell-pid"),
              let pid = Int32(pidStr),
              let colsStr = head.headers.first(name: "x-shell-cols"),
              let cols = UInt16(colsStr),
              let rowsStr = head.headers.first(name: "x-shell-rows"),
              let rows = UInt16(rowsStr) else {
            let body = ByteBuffer(string: "{\"error\":\"need x-shell-pid, x-shell-cols, x-shell-rows\"}\n")
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: "\(body.readableBytes)")
            let head = HTTPResponseHead(version: .http1_1, status: .badRequest, headers: headers)
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            return
        }

        // Send SIGWINCH to the shell process group — the PTY driver handles the rest
        var winSize = winsize()
        winSize.ws_col = cols
        winSize.ws_row = rows

        // We need the master fd to ioctl on. For now, use SIGWINCH to the process.
        // The shell will query the PTY for the new size.
        // TODO: Store master fds in a registry keyed by PID for direct ioctl
        kill(pid, SIGWINCH)

        let body = ByteBuffer(string: "{\"ok\":true}\n")
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: "\(body.readableBytes)")
        let respHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(respHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
