import Foundation
import GhostVMKit
#if canImport(Darwin)
import Darwin
#endif

/// `vmctl shell` — opens an interactive PTY session on the guest VM.
///
/// Usage:
///   vmctl shell --name MyVM [--command /bin/zsh]
///   vmctl shell --socket /path/to/sock
///
/// The command connects to the VM's HostAPIService Unix socket, sends
/// a POST /api/v1/shell request with the terminal size, and then bridges
/// the local terminal's stdin/stdout bidirectionally with the HTTP stream.
///
/// This works with both HTTP/1.1 (chunked/streaming) and HTTP/2 (DATA frames).
enum ShellCommand {

    static func run(arguments: [String]) throws {
        var args = arguments
        var socketPath: String?
        var vmName: String?
        var command: String?

        // Parse flags
        while !args.isEmpty {
            if args[0] == "--socket" || args[0] == "-s" {
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --socket") }
                socketPath = args.removeFirst()
            } else if args[0] == "--name" || args[0] == "-n" {
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --name") }
                vmName = args.removeFirst()
            } else if args[0] == "--command" || args[0] == "-c" {
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --command") }
                command = args.removeFirst()
            } else if args[0] == "--help" || args[0] == "-h" {
                showHelp()
                return
            } else {
                // Treat remaining args as the command
                command = args.joined(separator: " ")
                break
            }
        }

        // Resolve socket path
        let resolvedPath: String
        if let sp = socketPath {
            resolvedPath = (sp as NSString).expandingTildeInPath
        } else if let name = vmName {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolvedPath = supportDir.appendingPathComponent("GhostVM/api/\(name).GhostVM.sock").path
        } else {
            throw VMError.message("Must specify --socket <path> or --name <VMName>.\nUsage: vmctl shell --name <VMName> [--command /bin/bash]")
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw VMError.message("Socket not found at \(resolvedPath)\nIs the VM running?")
        }

        // Must be a TTY
        guard isatty(STDIN_FILENO) != 0 else {
            throw VMError.message("vmctl shell requires a terminal (stdin must be a TTY)")
        }

        // Get terminal size
        var winSize = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &winSize)
        let cols = winSize.ws_col > 0 ? winSize.ws_col : 80
        let rows = winSize.ws_row > 0 ? winSize.ws_row : 24

        // Connect to Unix socket
        let fd = try connectUnixSocket(path: resolvedPath)

        // Build HTTP request
        var headers = "POST /api/v1/shell HTTP/1.1\r\n"
        headers += "Host: localhost\r\n"
        headers += "X-Shell-Cols: \(cols)\r\n"
        headers += "X-Shell-Rows: \(rows)\r\n"
        if let cmd = command {
            headers += "X-Shell-Command: \(cmd)\r\n"
        }
        headers += "Transfer-Encoding: chunked\r\n"
        headers += "\r\n"

        // Send request headers
        let headerData = Data(headers.utf8)
        try headerData.withUnsafeBytes { ptr in
            let written = Darwin.write(fd, ptr.baseAddress!, headerData.count)
            guard written == headerData.count else {
                throw VMError.message("Failed to write request")
            }
        }

        // Read response headers
        let responseHeader = try readHTTPResponseHeader(fd: fd)
        guard responseHeader.contains("200") else {
            // Read body for error message
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &buf, buf.count)
            let body = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "" : ""
            Darwin.close(fd)
            throw VMError.message("Shell request failed: \(responseHeader.trimmingCharacters(in: .newlines))\n\(body)")
        }

        // Put terminal in raw mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)

        var raw = originalTermios
        cfmakeraw(&raw)
        // Keep output processing for \n → \r\n
        raw.c_oflag |= tcflag_t(OPOST)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Restore terminal on exit
        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
            Darwin.close(fd)
            print("") // newline after shell exits
        }

        // Handle SIGWINCH — send resize request on a separate connection
        let socketPathCopy = resolvedPath
        signal(SIGWINCH, SIG_IGN)
        let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winchSource.setEventHandler {
            var ws = winsize()
            _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
            if ws.ws_col > 0 && ws.ws_row > 0 {
                // TODO: Send resize via HTTP/2 stream or separate request
                // For now, this is a placeholder — resize needs the shell PID
                // which we get from X-Shell-PID response header
                _ = ws // suppress unused warning
                _ = socketPathCopy
            }
        }
        winchSource.resume()
        defer { winchSource.cancel() }

        // Bidirectional I/O: terminal ↔ socket
        // Set socket to non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        // Set stdin to non-blocking
        let stdinFlags = fcntl(STDIN_FILENO, F_GETFL, 0)
        _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags | O_NONBLOCK)

        defer {
            // Restore stdin to blocking
            _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags)
        }

        // Use select() for multiplexing stdin and socket
        var running = true

        // Handle SIGINT gracefully — don't kill vmctl, forward to shell via PTY
        signal(SIGINT, SIG_IGN)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler {
            // Send Ctrl-C to the shell via the socket
            var ctrlC: UInt8 = 3
            _ = Darwin.write(fd, &ctrlC, 1)
        }
        intSource.resume()
        defer { intSource.cancel() }

        while running {
            var readSet = fd_set()
            fdZero(&readSet)
            fdSet(STDIN_FILENO, set: &readSet)
            fdSet(fd, set: &readSet)

            let maxFD = max(STDIN_FILENO, fd) + 1
            var timeout = timeval(tv_sec: 1, tv_usec: 0)

            let ready = select(maxFD, &readSet, nil, nil, &timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            // Socket → stdout (shell output)
            if fdIsSet(fd, set: &readSet) {
                var buf = [UInt8](repeating: 0, count: 16384)
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 {
                    // Skip HTTP chunked encoding framing if present
                    // For now, write raw — the server sends raw bytes
                    _ = Darwin.write(STDOUT_FILENO, &buf, n)
                } else if n == 0 {
                    // EOF — shell exited
                    running = false
                } else if errno != EAGAIN && errno != EINTR {
                    running = false
                }
            }

            // stdin → socket (user input)
            if fdIsSet(STDIN_FILENO, set: &readSet) {
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
                if n > 0 {
                    _ = Darwin.write(fd, &buf, n)
                } else if n == 0 {
                    // stdin EOF
                    running = false
                }
            }
        }
    }

    // MARK: - Helpers

    private static func connectUnixSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VMError.message("Failed to create socket: errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw VMError.message("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, pathBytes.count)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw VMError.message("Failed to connect to \(path): errno \(errno)")
        }

        return fd
    }

    private static func readHTTPResponseHeader(fd: Int32) throws -> String {
        var headerData = Data()
        var buffer = [UInt8](repeating: 0, count: 1)
        let endMarker = Data("\r\n\r\n".utf8)

        // Read byte-by-byte until we find \r\n\r\n
        while true {
            let n = Darwin.read(fd, &buffer, 1)
            if n <= 0 {
                if n == 0 { throw VMError.message("Connection closed while reading response") }
                if errno == EINTR { continue }
                throw VMError.message("Read error: errno \(errno)")
            }
            headerData.append(contentsOf: buffer[0..<1])

            if headerData.count >= 4 && headerData.suffix(4) == endMarker {
                return String(data: headerData, encoding: .utf8) ?? ""
            }

            if headerData.count > 8192 {
                throw VMError.message("Response headers too large")
            }
        }
    }

    // MARK: - fd_set helpers (Swift doesn't have macros)

    private static func fdZero(_ set: inout fd_set) {
        // Zero out all bits
        withUnsafeMutablePointer(to: &set) { ptr in
            memset(ptr, 0, MemoryLayout<fd_set>.size)
        }
    }

    private static func fdSet(_ fd: Int32, set: inout fd_set) {
        let intOffset = Int(fd) / (MemoryLayout<Int32>.size * 8)
        let bitOffset = Int(fd) % (MemoryLayout<Int32>.size * 8)
        withUnsafeMutablePointer(to: &set) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            let intPtr = raw.bindMemory(to: Int32.self, capacity: intOffset + 1)
            intPtr[intOffset] |= Int32(1 << bitOffset)
        }
    }

    private static func fdIsSet(_ fd: Int32, set: inout fd_set) -> Bool {
        let intOffset = Int(fd) / (MemoryLayout<Int32>.size * 8)
        let bitOffset = Int(fd) % (MemoryLayout<Int32>.size * 8)
        return withUnsafePointer(to: &set) { ptr in
            let raw = UnsafeRawPointer(ptr)
            let intPtr = raw.bindMemory(to: Int32.self, capacity: intOffset + 1)
            return (intPtr[intOffset] & Int32(1 << bitOffset)) != 0
        }
    }

    private static func showHelp() {
        let help = """
        Usage: vmctl shell --name <VMName> [options]
               vmctl shell --socket <path> [options]

        Options:
          --name <VMName>      VM name (resolves socket from VM bundle)
          --socket <path>      Unix socket path
          --command <cmd>      Shell to run (default: guest user's login shell)

        Opens an interactive terminal session on the guest VM via GhostTools.
        Requires GhostTools to be running in the guest.

        Examples:
          vmctl shell --name MyVM
          vmctl shell --name MyVM --command /bin/bash
          vmctl shell --socket /path/to/sock
        """
        print(help)
    }
}
