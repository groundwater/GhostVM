import Foundation

func runAttachment(
    invocation: GhostboxDirectInvocation,
    expectedStream: GhostboxIOStream,
    port: UInt32
) -> Int32 {
    if expectedStream == .terminal {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            writeStderr("ghostbox: terminal attach requires terminal stdin and stdout\n")
            return 125
        }
    }

    let request = GhostboxDirectRequest(invocation: invocation)
    let requestLine: Data
    do {
        requestLine = try encodeDirectRequestLine(request)
    } catch {
        writeStderr("ghostbox: failed to encode attachment request: \(error)\n")
        return 125
    }

    let fd: Int32
    do {
        fd = try vsockDialHost(port: port)
    } catch {
        writeStderr("ghostbox: cannot connect to host: \(error)\n")
        return 125
    }
    defer { Darwin.close(fd) }

    guard writeAll(fd: fd, requestLine) else {
        writeStderr("ghostbox: failed to send attachment request (errno \(errno))\n")
        return 125
    }

    let reader = LineReader(fd: fd, maxLineBytes: kMaxIOFrameLineBytes)
    let responseData: Data
    do {
        guard let response = try reader.readLine(), !response.isEmpty else {
            writeStderr("ghostbox: connection closed before attachment response\n")
            return 125
        }
        responseData = response
    } catch {
        writeStderr("ghostbox: failed to read attachment response: \(error)\n")
        return 125
    }

    switch decodeDirectResponse(responseData, requestID: request.id) {
    case .result(let value):
        guard case .json(.string(let mode)) = value.storage, mode == expectedStream.rawValue else {
            writeStderr("ghostbox: host returned an invalid attachment mode\n")
            return 125
        }
    case .error(let code, let message):
        writeStderr("ghostbox: host error [\(code)]: \(message)\n")
        return 125
    case .protocolError(let message):
        writeStderr("ghostbox: protocol error: \(message)\n")
        return 125
    }

    switch expectedStream {
    case .input:
        return forwardInputAttachment(fd: fd, reader: reader)
    case .output:
        _ = Darwin.shutdown(fd, SHUT_WR)
        return receiveAttachmentOutput(fd: fd, reader: reader, expectedStream: .output)
    case .terminal:
        return runTerminalAttachment(fd: fd, reader: reader)
    }
}

private func forwardInputAttachment(fd: Int32, reader: LineReader) -> Int32 {
    let writer = AttachmentFrameWriter(fd: fd)
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    while true {
        if reader.hasBufferedLine {
            return receiveAttachmentOutput(fd: fd, reader: reader, expectedStream: .input)
        }
        var descriptors = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0),
            pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
        ]
        let status = Darwin.poll(&descriptors, nfds_t(descriptors.count), -1)
        if status < 0, errno == EINTR { continue }
        if status < 0 {
            writeStderr("ghostbox: failed to poll stdin attachment (errno \(errno))\n")
            return 125
        }
        if descriptors[1].revents != 0 {
            return receiveAttachmentOutput(fd: fd, reader: reader, expectedStream: .input)
        }
        guard descriptors[0].revents != 0 else { continue }
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 {
            guard writer.send(.data(Data(buffer[0..<count]), stream: .input)) else {
                writeStderr("ghostbox: failed to forward stdin (errno \(errno))\n")
                return 125
            }
            continue
        }
        if count < 0, errno == EINTR { continue }
        if count < 0 {
            writeStderr("ghostbox: failed to read stdin (errno \(errno))\n")
            return 125
        }
        break
    }
    guard writer.send(.eof(.input)) else {
        writeStderr("ghostbox: failed to close proxied stdin (errno \(errno))\n")
        return 125
    }
    writer.shutdownWrite()
    return receiveAttachmentOutput(fd: fd, reader: reader, expectedStream: .input)
}

private func runTerminalAttachment(fd: Int32, reader: LineReader) -> Int32 {
    let terminal: RawAttachmentTerminal
    do {
        terminal = try RawAttachmentTerminal(fd: STDIN_FILENO)
    } catch {
        writeStderr("ghostbox: failed to enter raw terminal mode: \(error)\n")
        return 125
    }

    let writer = AttachmentFrameWriter(fd: fd)
    defer { writer.shutdownWrite() }
    let controlQueue = DispatchQueue(label: "org.ghostvm.ghostbox.terminal-signals", qos: .userInitiated)
    let sendResize: @Sendable () -> Bool = {
        let size = currentAttachmentTerminalSize()
        return writer.send(.resize(columns: size.columns, rows: size.rows))
    }
    let terminationSources = installAttachmentTerminationSignalHandlers(terminal, queue: controlQueue)
    let resizeSource = installAttachmentResizeSignalHandler(queue: controlQueue, sendResize: sendResize)
    let jobControlSources = installAttachmentJobControlSignalHandlers(
        terminal,
        writer: writer,
        queue: controlQueue,
        sendResize: sendResize
    )
    defer {
        terminationSources.forEach { $0.cancel() }
        resizeSource.cancel()
        jobControlSources.forEach { $0.cancel() }
    }

    do {
        try terminal.enterRawMode()
    } catch {
        writeStderr("ghostbox: failed to enter raw terminal mode: \(error)\n")
        return 125
    }
    defer { terminal.finish() }

    var sentInitialSize = false
    controlQueue.sync { sentInitialSize = sendResize() }
    guard sentInitialSize else {
        writeStderr("ghostbox: failed to send terminal size\r\n")
        return 125
    }

    DispatchQueue.global(qos: .userInitiated).async {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 {
                if !writer.send(.data(Data(buffer[0..<count]), stream: .terminal)) { return }
                continue
            }
            if count < 0, errno == EINTR { continue }
            _ = writer.send(.eof(.terminal))
            writer.shutdownWrite()
            return
        }
    }

    return receiveAttachmentOutput(fd: fd, reader: reader, expectedStream: .terminal, terminalDiagnostics: true)
}

private func receiveAttachmentOutput(
    fd: Int32,
    reader: LineReader,
    expectedStream: GhostboxIOStream,
    terminalDiagnostics: Bool = false
) -> Int32 {
    while true {
        let line: Data
        do {
            guard let value = try reader.readLine(), !value.isEmpty else {
                writeAttachmentDiagnostic("ghostbox: attachment closed before EOF\n", terminal: terminalDiagnostics)
                return 125
            }
            line = value
        } catch {
            writeAttachmentDiagnostic("ghostbox: failed to read attachment frame: \(error)\n", terminal: terminalDiagnostics)
            return 125
        }

        let frame: GhostboxIOFrame
        do {
            frame = try GhostboxIOFrame.decode(line: line)
        } catch {
            writeAttachmentDiagnostic("ghostbox: invalid attachment frame: \(error)\n", terminal: terminalDiagnostics)
            return 125
        }

        switch frame.type {
        case .data:
            guard frame.stream == expectedStream, let data = frame.data else {
                writeAttachmentDiagnostic("ghostbox: unexpected attachment data stream\n", terminal: terminalDiagnostics)
                return 125
            }
            guard writeStdout(data) else {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
                return 125
            }
        case .eof:
            guard frame.stream == expectedStream else {
                writeAttachmentDiagnostic("ghostbox: unexpected attachment EOF stream\n", terminal: terminalDiagnostics)
                return 125
            }
            return 0
        case .error:
            writeAttachmentDiagnostic("ghostbox: host I/O error: \(frame.message ?? "unknown error")\n", terminal: terminalDiagnostics)
            return 125
        case .resize:
            writeAttachmentDiagnostic("ghostbox: unexpected resize frame from host\n", terminal: terminalDiagnostics)
            return 125
        }
    }
}

private final class AttachmentFrameWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var writeClosed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ frame: GhostboxIOFrame) -> Bool {
        guard let line = try? frame.encodeLine() else { return false }
        return lock.withLock {
            guard !writeClosed else { return false }
            return writeAll(fd: fd, line)
        }
    }

    func shutdownWrite() {
        lock.withLock {
            guard !writeClosed else { return }
            writeClosed = true
            _ = Darwin.shutdown(fd, SHUT_WR)
        }
    }
}

private func currentAttachmentTerminalSize() -> (columns: UInt16, rows: UInt16) {
    var size = winsize()
    let descriptor = isatty(STDOUT_FILENO) != 0 ? STDOUT_FILENO : STDIN_FILENO
    guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
        return (80, 24)
    }
    return (size.ws_col, size.ws_row)
}

final class RawAttachmentTerminal: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private let original: termios
    private let raw: termios
    private var finished = false

    init(fd: Int32) throws {
        self.fd = fd
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var raw = original
        cfmakeraw(&raw)
        self.original = original
        self.raw = raw
    }

    func enterRawMode() throws {
        try lock.withLock {
            guard !finished else { return }
            var attributes = raw
            guard tcsetattr(fd, TCSAFLUSH, &attributes) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    @discardableResult
    func suspend() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            var attributes = original
            return tcsetattr(fd, TCSAFLUSH, &attributes) == 0
        }
    }

    @discardableResult
    func resume() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            var attributes = raw
            return tcsetattr(fd, TCSAFLUSH, &attributes) == 0
        }
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            var attributes = original
            _ = tcsetattr(fd, TCSAFLUSH, &attributes)
        }
    }
}

private func installAttachmentTerminationSignalHandlers(
    _ terminal: RawAttachmentTerminal,
    queue: DispatchQueue
) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP, SIGQUIT].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler {
            terminal.finish()
            signal(signalNumber, SIG_DFL)
            raise(signalNumber)
        }
        source.resume()
        return source
    }
}

private func installAttachmentResizeSignalHandler(
    queue: DispatchQueue,
    sendResize: @escaping @Sendable () -> Bool
) -> DispatchSourceSignal {
    signal(SIGWINCH, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: queue)
    source.setEventHandler { _ = sendResize() }
    source.resume()
    return source
}

private func installAttachmentJobControlSignalHandlers(
    _ terminal: RawAttachmentTerminal,
    writer: AttachmentFrameWriter,
    queue: DispatchQueue,
    sendResize: @escaping @Sendable () -> Bool
) -> [DispatchSourceSignal] {
    signal(SIGTSTP, SIG_IGN)
    signal(SIGCONT, SIG_IGN)

    let suspendSource = DispatchSource.makeSignalSource(signal: SIGTSTP, queue: queue)
    suspendSource.setEventHandler {
        guard terminal.suspend() else {
            writer.shutdownWrite()
            return
        }
        signal(SIGTSTP, SIG_DFL)
        raise(SIGTSTP)
        signal(SIGTSTP, SIG_IGN)
        guard terminal.resume(), sendResize() else { writer.shutdownWrite(); return }
    }
    suspendSource.resume()

    let continueSource = DispatchSource.makeSignalSource(signal: SIGCONT, queue: queue)
    continueSource.setEventHandler {
        guard terminal.resume(), sendResize() else { writer.shutdownWrite(); return }
    }
    continueSource.resume()
    return [suspendSource, continueSource]
}

private func writeAttachmentDiagnostic(_ message: String, terminal: Bool) {
    if terminal {
        writeStderr(message.replacingOccurrences(of: "\n", with: "\r\n"))
    } else {
        writeStderr(message)
    }
}
