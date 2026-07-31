import Foundation

let gcVersion = "0.1.0"

let gcHelp = """
Usage: ghost-container run [-i] [-t] [-v GUEST_PATH:CONTAINER_PATH:ro] IMAGE [COMMAND...]

Run a container image on the outer Mac through Apple container.

Arguments:
  IMAGE     Fully qualified OCI image reference
  COMMAND   Optional command and args to run inside the container

Examples:
  ghost-container run registry-1.docker.io/library/alpine:latest echo hello
  ghost-container run -it registry-1.docker.io/library/alpine:latest /bin/sh
  ghost-container run -v /home/user/src:/src:ro registry-1.docker.io/library/alpine:latest ls /src
  ghost-container run registry-1.docker.io/library/ubuntu:24.04

Options:
  -i, --interactive  Keep stdin attached
  -t, --tty          Allocate a terminal (combine as -it)
  -v, --volume SPEC  Mount a guest directory read-only (GUEST:CONTAINER:ro)
  --help, -h     Show this help
  --version, -v  Show version
"""

/// Entry point — parses argv, dispatches to run, exits with appropriate status.
@main
struct GhostContainerCLI {
    static func main() {
        signal(SIGPIPE, SIG_IGN)

        let argv = Array(CommandLine.arguments.dropFirst())

        let result = parseArguments(argv)

        let exitCode: Int32
        switch result {
        case .success(let opts):
            exitCode = run(opts)
        case .failure(let err):
            FileHandle.standardError.write(Data((err.errorDescription ?? "error").utf8))
            FileHandle.standardError.write(Data("\n".utf8))
            exitCode = 125
        }

        exit(exitCode)
    }

    /// Execute a parsed action. Returns a process exit status.
    static func run(_ opts: CLIOptions) -> Int32 {
        switch opts.action {
        case .help:
            FileHandle.standardOutput.write(Data(gcHelp.utf8))
            return 0
        case .version:
            FileHandle.standardOutput.write(Data("\(gcVersion)\n".utf8))
            return 0
        case .run(let image, let command, let volumes, let interactive, let tty):
            return runContainer(
                image: image,
                command: command,
                volumes: volumes,
                interactive: interactive,
                tty: tty,
                port: kDefaultVsockPort
            )
        }
    }
}

/// Connect to the host via vsock, attach stdin, and stream responses.
func runContainer(
    image: String,
    command: [String],
    volumes: [HostContainerVolume] = [],
    interactive: Bool = false,
    tty: Bool = false,
    port: UInt32
) -> Int32 {
    if tty && isatty(STDOUT_FILENO) == 0 {
        writeStderr("ghost-container: -t requires stdout to be a terminal\n")
        return 125
    }
    if tty && interactive && isatty(STDIN_FILENO) == 0 {
        writeStderr("ghost-container: -it requires stdin to be a terminal\n")
        return 125
    }

    let terminalSize = tty ? currentTerminalSize() : nil
    var rawTerminal: RawTerminal?
    if tty && interactive {
        do {
            rawTerminal = try RawTerminal(fd: STDIN_FILENO)
        } catch {
            writeStderr("ghost-container: failed to enter raw terminal mode: \(error)\n")
            return 125
        }
    }
    defer { rawTerminal?.restore() }
    let terminationSources = rawTerminal.map(installTerminalSignalHandlers) ?? []
    defer { terminationSources.forEach { $0.cancel() } }

    var terminalStderrNormalizer = TerminalNewlineNormalizer()
    @discardableResult
    func writeRunStderr(_ data: Data) -> Bool {
        let output = rawTerminal == nil ? data : terminalStderrNormalizer.normalize(data)
        return writeStderr(output)
    }
    @discardableResult
    func writeRunStderr(_ string: String) -> Bool {
        writeRunStderr(Data(string.utf8))
    }

    let fd: Int32
    do {
        fd = try vsockDialHost(port: port)
    } catch let err as VsockDialError {
        writeRunStderr("ghost-container: cannot connect to host: \(err)\n")
        return 125
    } catch {
        writeRunStderr("ghost-container: unexpected error: \(error)\n")
        return 125
    }

    defer {
        Darwin.close(fd)
    }

    let inputWriter: ContainerInputWriter?
    if interactive || tty {
        let inputSocket = Darwin.dup(fd)
        guard inputSocket >= 0 else {
            writeRunStderr("ghost-container: failed to duplicate input socket (errno \(errno))\n")
            return 125
        }
        inputWriter = ContainerInputWriter(fd: inputSocket)
    } else {
        inputWriter = nil
    }
    defer { inputWriter?.close() }

    let request = makeRunRequest(
        image: image,
        command: command,
        volumes: volumes,
        interactive: interactive,
        tty: tty,
        columns: terminalSize?.columns,
        rows: terminalSize?.rows
    )
    let line: Data
    do {
        line = try encodeRequestLine(request)
    } catch {
        writeRunStderr("ghost-container: failed to encode request: \(error)\n")
        return 125
    }

    guard writeAll(fd: fd, line) else {
        writeRunStderr("ghost-container: failed to send request (EPIPE/errno \(errno))\n")
        return 125
    }

    // Input and resize controls share one serialized framed writer.
    var resizeSource: DispatchSourceSignal?
    if tty, let inputWriter {
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            let size = currentTerminalSize()
            _ = inputWriter.send(.resize(columns: size.columns, rows: size.rows))
        }
        source.resume()
        resizeSource = source
    }
    defer {
        resizeSource?.cancel()
    }

    if interactive, let inputWriter {
        DispatchQueue.global(qos: .userInitiated).async {
            forwardStdin(inputFD: STDIN_FILENO, writer: inputWriter, keepWriteSideOpen: tty)
        }
    } else if !tty {
        _ = Darwin.shutdown(fd, SHUT_WR)
    }

    let reader = LineReader(fd: fd, maxLineBytes: 1_048_576)

    while true {
        let rawLine: Data?
        do {
            rawLine = try reader.readLine()
        } catch LineReaderError.lineTooLong(let max) {
            writeRunStderr("ghost-container: response line exceeded \(max) bytes\n")
            return 125
        } catch LineReaderError.ioError(let err, let op) {
            writeRunStderr("ghost-container: \(op) error: errno \(err) (\(String(cString: strerror(err))))\n")
            return 125
        } catch {
            writeRunStderr("ghost-container: unexpected read error: \(error)\n")
            return 125
        }

        guard let json = rawLine, !json.isEmpty else {
            writeRunStderr("ghost-container: connection closed before exit response\n")
            return 125
        }

        switch decodeResponse(json) {
        case .stdout(let data):
            if !writeStdout(data) {
                writeRunStderr("ghost-container: failed to write stdout to fd 1 (errno \(errno): \(String(cString: strerror(errno))))\n")
                return 125
            }
        case .stderr(let data):
            if !writeRunStderr(data) {
                // Best-effort diagnostic: writing the diagnostic itself may also
                // fail (e.g. fd 2 closed). If it does, we cannot report further;
                // just surface the original failure via the exit status.
                _ = writeRunStderr("ghost-container: failed to write stderr to fd 2 (errno \(errno): \(String(cString: strerror(errno))))\n")
                return 125
            }
        case .exit(let code):
            return code
        case .error(let message):
            writeRunStderr("ghost-container: host error: \(message)\n")
            return 125
        case .protocolError(let message):
            writeRunStderr("ghost-container: protocol error: \(message)\n")
            return 125
        }
    }
}

/// Encode a request as an NDJSON line with the exact key order:
/// `{"version":1,"operation":"run","image":"...","command":[...]}\n`
///
/// `JSONEncoder` uses alphabetical key ordering which doesn't match the
/// required wire format, so we build the JSON string manually with proper
/// escaping.
func encodeRequestLine(_ request: HostContainerRequest) throws -> Data {
    var json = "{\"version\":\(request.version)"
    json += ",\"operation\":\(jsonString(request.operation))"
    json += ",\"image\":\(jsonString(request.image))"
    json += ",\"command\":["
    json += request.command.map { jsonString($0) }.joined(separator: ",")
    json += request.stdin ? "],\"stdin\":true" : "],\"stdin\":false"
    json += request.tty ? ",\"tty\":true" : ",\"tty\":false"
    if let columns = request.columns, let rows = request.rows {
        json += ",\"columns\":\(columns),\"rows\":\(rows)"
    }
    if !request.volumes.isEmpty {
        json += ",\"volumes\":["
        json += request.volumes.map { volume in
            "{\"guestPath\":\(jsonString(volume.guestPath)),\"destination\":\(jsonString(volume.destination)),\"readOnly\":\(volume.readOnly ? "true" : "false")}"
        }.joined(separator: ",")
        json += "]"
    }
    json += "}"
    json.append("\n")
    return Data(json.utf8)
}

/// Relays fd 0 to the socket's write side and half-closes it at EOF, leaving
/// the opposite direction open for stdout/stderr/exit frames.
func forwardStdin(inputFD: Int32, writer: ContainerInputWriter, keepWriteSideOpen: Bool) {
    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
    while true {
        let count = Darwin.read(inputFD, &buffer, buffer.count)
        if count > 0 {
            if !writer.send(.stdin(Data(buffer[0..<count]))) { break }
            continue
        }
        if count < 0, errno == EINTR { continue }
        break
    }
    _ = writer.send(.stdinClose)
    if !keepWriteSideOpen {
        writer.shutdownWrite()
    }
}

final class ContainerInputWriter: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    @discardableResult
    func send(_ frame: HostContainerInputFrame) -> Bool {
        guard let line = try? encodeInputFrame(frame) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        return writeAll(fd: fd, line)
    }

    func shutdownWrite() {
        lock.lock()
        if !closed {
            _ = Darwin.shutdown(fd, SHUT_WR)
        }
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        _ = Darwin.shutdown(fd, SHUT_WR)
        Darwin.close(fd)
        lock.unlock()
    }
}

func currentTerminalSize() -> (columns: UInt16, rows: UInt16) {
    var size = winsize()
    let descriptor = isatty(STDOUT_FILENO) != 0 ? STDOUT_FILENO : STDIN_FILENO
    guard ioctl(descriptor, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else {
        return (80, 24)
    }
    return (size.ws_col, size.ws_row)
}

final class RawTerminal: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var original: termios?

    init(fd: Int32) throws {
        self.fd = fd
        var original = termios()
        guard tcgetattr(fd, &original) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(fd, TCSAFLUSH, &raw) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.original = original
    }

    func restore() {
        lock.lock()
        guard var original else {
            lock.unlock()
            return
        }
        self.original = nil
        _ = tcsetattr(fd, TCSAFLUSH, &original)
        lock.unlock()
    }
}

struct TerminalNewlineNormalizer {
    private var previousByteWasCarriageReturn = false

    mutating func normalize(_ data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(data.count)
        for byte in data {
            if byte == 0x0A, !previousByteWasCarriageReturn {
                output.append(0x0D)
            }
            output.append(byte)
            previousByteWasCarriageReturn = byte == 0x0D
        }
        return output
    }
}

func installTerminalSignalHandlers(_ terminal: RawTerminal) -> [DispatchSourceSignal] {
    [SIGINT, SIGTERM, SIGHUP, SIGQUIT].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            terminal.restore()
            signal(signalNumber, SIG_DFL)
            raise(signalNumber)
        }
        source.resume()
        return source
    }
}

/// Escape a string for inclusion in a JSON string literal (including surrounding quotes).
private func jsonString(_ s: String) -> String {
    var result = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"":
            result += "\\\""
        case "\\":
            result += "\\\\"
        case "\n":
            result += "\\n"
        case "\r":
            result += "\\r"
        case "\t":
            result += "\\t"
        case "\u{08}":
            result += "\\b"
        case "\u{0C}":
            result += "\\f"
        default:
            if scalar.value < 0x20 {
                result += String(format: "\\u%04x", scalar.value)
            } else {
                result += String(scalar)
            }
        }
    }
    result += "\""
    return result
}

/// Write bytes to fd 1 (stdout). Returns false on write failure.
@discardableResult
func writeStdout(_ data: Data) -> Bool {
    return writeAll(fd: 1, data)
}

/// Write bytes to fd 2 (stderr). Returns false on write failure.
@discardableResult
func writeStderr(_ data: Data) -> Bool {
    return writeAll(fd: 2, data)
}

/// Write a UTF-8 string to stderr. Returns false on write failure.
@discardableResult
func writeStderr(_ s: String) -> Bool {
    return writeStderr(Data(s.utf8))
}

/// Map a host-provided exit status into a valid process exit status.
///
/// Predictable mapping (no bit masking):
/// - `0...255` is accepted unchanged.
/// - Any malformed/out-of-range value (negative, ≥ 256) maps to `125` so the
///   guest never silently returns a wrong code.
func clampExitCode(_ code: Int32) -> Int32 {
    if (0...255).contains(code) {
        return code
    }
    return 125
}
