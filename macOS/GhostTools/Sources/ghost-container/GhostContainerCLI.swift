import Foundation

let gcVersion = "0.1.0"

let gcHelp = """
Usage: ghost-container run IMAGE [COMMAND...]

Run a container image on the outer Mac through Apple container.

Arguments:
  IMAGE     Container image name (e.g. "alpine")
  COMMAND   Optional command and args to run inside the container

Examples:
  ghost-container run alpine echo hello
  ghost-container run ubuntu:24.04

Options:
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
        case .run(let image, let command):
            return runContainer(image: image, command: command, port: kDefaultVsockPort)
        }
    }
}

/// Connect to the host via vsock, send a run request, stream responses.
func runContainer(image: String, command: [String], port: UInt32) -> Int32 {
    let fd: Int32
    do {
        fd = try vsockDialHost(port: port)
    } catch let err as VsockDialError {
        writeStderr("ghost-container: cannot connect to host: \(err)\n")
        return 125
    } catch {
        writeStderr("ghost-container: unexpected error: \(error)\n")
        return 125
    }

    defer {
        Darwin.close(fd)
    }

    let request = makeRunRequest(image: image, command: command)
    let line: Data
    do {
        line = try encodeRequestLine(request)
    } catch {
        writeStderr("ghost-container: failed to encode request: \(error)\n")
        return 125
    }

    guard writeAll(fd: fd, line) else {
        writeStderr("ghost-container: failed to send request (EPIPE/errno \(errno))\n")
        return 125
    }

    let reader = LineReader(fd: fd, maxLineBytes: 1_048_576)

    while true {
        let rawLine: Data?
        do {
            rawLine = try reader.readLine()
        } catch LineReaderError.lineTooLong(let max) {
            writeStderr("ghost-container: response line exceeded \(max) bytes\n")
            return 125
        } catch LineReaderError.ioError(let err, let op) {
            writeStderr("ghost-container: \(op) error: errno \(err) (\(String(cString: strerror(err))))\n")
            return 125
        } catch {
            writeStderr("ghost-container: unexpected read error: \(error)\n")
            return 125
        }

        guard let json = rawLine, !json.isEmpty else {
            writeStderr("ghost-container: connection closed before exit response\n")
            return 125
        }

        switch decodeResponse(json) {
        case .stdout(let data):
            if !writeStdout(data) {
                writeStderr("ghost-container: failed to write stdout to fd 1 (errno \(errno): \(String(cString: strerror(errno))))\n")
                return 125
            }
        case .stderr(let data):
            if !writeStderr(data) {
                // Best-effort diagnostic: writing the diagnostic itself may also
                // fail (e.g. fd 2 closed). If it does, we cannot report further;
                // just surface the original failure via the exit status.
                _ = writeStderr("ghost-container: failed to write stderr to fd 2 (errno \(errno): \(String(cString: strerror(errno))))\n")
                return 125
            }
        case .exit(let code):
            return code
        case .error(let message):
            writeStderr("ghost-container: host error: \(message)\n")
            return 125
        case .protocolError(let message):
            writeStderr("ghost-container: protocol error: \(message)\n")
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
    json += "]}"
    json += "\n"
    return Data(json.utf8)
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
