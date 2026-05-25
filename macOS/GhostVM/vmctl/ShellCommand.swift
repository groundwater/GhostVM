import Foundation
import GhostHTTP
import GhostVMKit
import CryptoKit
#if canImport(Darwin)
import Darwin
#endif

/// `vmctl shell` — opens an interactive PTY session on the guest VM via WebSocket.
///
/// Usage:
///   vmctl shell --name MyVM
///   vmctl shell --socket /path/to/sock
///
/// Protocol:
///   1. HTTP/1.1 Upgrade to WebSocket on /api/v1/shell?cols=N&rows=N
///   2. Binary WebSocket frames = PTY data (bidirectional)
///   3. Text WebSocket frames = JSON control messages (resize, exit)
enum ShellCommand {

    static func run(arguments: [String]) throws {
        var args = arguments
        var socketPath: String?
        var vmName: String?

        while !args.isEmpty {
            if args[0] == "--socket" || args[0] == "-s" {
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --socket") }
                socketPath = args.removeFirst()
            } else if args[0] == "--name" || args[0] == "-n" {
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --name") }
                vmName = args.removeFirst()
            } else if args[0] == "--help" || args[0] == "-h" {
                showHelp()
                return
            } else {
                throw VMError.message("Unknown argument: \(args[0])\nUsage: vmctl shell --name <VMName>")
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
            throw VMError.message("Must specify --socket <path> or --name <VMName>.\nUsage: vmctl shell --name <VMName>")
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw VMError.message("Socket not found at \(resolvedPath)\nIs the VM running?")
        }

        guard isatty(STDIN_FILENO) != 0 else {
            throw VMError.message("vmctl shell requires a terminal (stdin must be a TTY)")
        }

        // Get terminal size
        var winSize = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &winSize)
        let cols = winSize.ws_col > 0 ? winSize.ws_col : 80
        let rows = winSize.ws_row > 0 ? winSize.ws_row : 24

        // Connect
        let fd = try connectUnixSocket(path: resolvedPath)

        // WebSocket upgrade handshake. Forward our TERM so the in-VM shell
        // can emit color/clear escapes that this terminal can interpret.
        let wsKey = generateWebSocketKey()
        let term = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        let termEncoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "xterm-256color"
        let path = "/api/v1/shell?cols=\(cols)&rows=\(rows)&term=\(termEncoded)"

        let upgraded = try HTTPClient.performUpgradeRequest(
            fd: fd,
            path: path,
            headers: [
                "Host": "localhost",
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": wsKey,
                "Sec-WebSocket-Version": "13",
            ]
        )
        guard upgraded.responseHead.status == .switchingProtocols else {
            Darwin.close(fd)
            throw VMError.message("WebSocket upgrade failed with status \(upgraded.responseHead.status.rawValue)")
        }
        let expectedAccept = webSocketAccept(for: wsKey)
        let actualAccept = upgraded.responseHead.headers["Sec-WebSocket-Accept"]
        guard actualAccept == expectedAccept else {
            Darwin.close(fd)
            throw VMError.message("WebSocket upgrade failed: invalid Sec-WebSocket-Accept")
        }

        // WebSocket connection established — enter raw terminal mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)

        var raw = originalTermios
        cfmakeraw(&raw)
        // Keep the local tty fully raw. The guest PTY's slave-side termios is
        // responsible for newline translation; re-enabling local `OPOST` or
        // `ONLCR` here causes double CR/LF mapping and subtle TUI drift.
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        // Only the SOCKET goes non-blocking — that's what DispatchSource's
        // writability semantics need.
        //
        // We deliberately leave STDIN alone. STDIN and STDOUT share the
        // open file description on a TTY, so flipping O_NONBLOCK on STDIN
        // also flips it on STDOUT. With non-blocking STDOUT, TUI-redraw
        // bursts return EAGAIN mid-write, the inner retry loop silently
        // dropped bytes on edge cases, and the rendered output came out
        // slightly mis-aligned (lines offset, digits in wrong columns).
        // DispatchSource.makeReadSource works fine on a blocking fd —
        // it only invokes the handler when data is available — and a
        // blocking STDOUT write just back-pressures naturally.
        let sockFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, sockFlags | O_NONBLOCK)

        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        }

        WebSocketShellClient.run(
            configuration: .init(
                socketFD: fd,
                inputFD: STDIN_FILENO,
                outputFD: STDOUT_FILENO,
                prelude: upgraded.prelude,
                installWindowResizeHandler: true,
                installInterruptHandler: true,
                onControlMessage: handleControlMessage
            )
        )

        print("") // newline after shell exits
    }

    // MARK: - Control Messages

    private static func handleControlMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "exit" {
            let code = json["code"] as? Int ?? 0
            if code != 0 {
                FileHandle.standardError.write(Data("Shell exited with code \(code)\n".utf8))
            }
        }
    }

    // MARK: - Socket Helpers

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

    private static func generateWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, 16)
        return Data(bytes).base64EncodedString()
    }

    private static func webSocketAccept(for key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    private static func showHelp() {
        let help = """
        Usage: vmctl shell --name <VMName>
               vmctl shell --socket <path>

        Options:
          --name <VMName>      VM name (resolves socket from VM bundle)
          --socket <path>      Unix socket path

        Opens an interactive terminal session on the guest VM.
        Uses WebSocket for bidirectional PTY streaming.

        Examples:
          vmctl shell --name MyVM
        """
        print(help)
    }
}
