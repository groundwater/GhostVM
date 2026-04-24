import Foundation
import GhostVMKit
#if canImport(Darwin)
import Darwin
#endif

/// `vmctl shell` — opens an interactive PTY session on the guest VM via WebSocket.
///
/// Usage:
///   vmctl shell --name MyVM [--command /bin/zsh]
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
        var command: String?

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

        // WebSocket upgrade handshake
        let wsKey = generateWebSocketKey()
        var path = "/api/v1/shell?cols=\(cols)&rows=\(rows)"
        if let cmd = command {
            let encoded = cmd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cmd
            path += "&command=\(encoded)"
        }

        let upgradeRequest = "GET \(path) HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Key: \(wsKey)\r\n" +
            "Sec-WebSocket-Version: 13\r\n" +
            "\r\n"

        try upgradeRequest.withCString { ptr in
            let len = strlen(ptr)
            guard Darwin.write(fd, ptr, len) == len else {
                throw VMError.message("Failed to send WebSocket upgrade request")
            }
        }

        // Read upgrade response
        let response = try readHTTPResponseHeader(fd: fd)
        guard response.contains("101") else {
            Darwin.close(fd)
            throw VMError.message("WebSocket upgrade failed: \(response.prefix(200))")
        }

        // WebSocket connection established — enter raw terminal mode
        var originalTermios = termios()
        tcgetattr(STDIN_FILENO, &originalTermios)

        var raw = originalTermios
        cfmakeraw(&raw)
        raw.c_oflag |= tcflag_t(OPOST)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

        defer {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
            Darwin.close(fd)
        }

        // Handle SIGWINCH — send resize as WebSocket text frame
        signal(SIGWINCH, SIG_IGN)
        let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        winchSource.setEventHandler {
            var ws = winsize()
            _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
            if ws.ws_col > 0 && ws.ws_row > 0 {
                let json = "{\"type\":\"resize\",\"cols\":\(ws.ws_col),\"rows\":\(ws.ws_row)}"
                sendWebSocketTextFrame(fd: fd, text: json)
            }
        }
        winchSource.resume()
        defer { winchSource.cancel() }

        // Handle SIGINT — forward as Ctrl-C to shell
        signal(SIGINT, SIG_IGN)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler {
            sendWebSocketBinaryFrame(fd: fd, data: [3]) // Ctrl-C
        }
        intSource.resume()
        defer { intSource.cancel() }

        // Bidirectional I/O loop
        let stdinFlags = fcntl(STDIN_FILENO, F_GETFL, 0)
        _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags | O_NONBLOCK)
        let sockFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, sockFlags | O_NONBLOCK)

        defer {
            _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags)
        }

        var running = true
        var wsParser = WebSocketFrameParser()

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

            // Socket → stdout (WebSocket frames from server)
            if fdIsSet(fd, set: &readSet) {
                var buf = [UInt8](repeating: 0, count: 16384)
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 {
                    wsParser.feed(Array(buf[0..<n]))
                    while let frame = wsParser.nextFrame() {
                        switch frame.opcode {
                        case 0x02: // Binary — PTY output
                            frame.payload.withUnsafeBufferPointer { ptr in
                                if let base = ptr.baseAddress {
                                    _ = Darwin.write(STDOUT_FILENO, base, ptr.count)
                                }
                            }
                        case 0x01: // Text — control message
                            if let text = String(bytes: frame.payload, encoding: .utf8) {
                                handleControlMessage(text)
                            }
                        case 0x08: // Close
                            running = false
                        case 0x09: // Ping
                            sendWebSocketPong(fd: fd, data: frame.payload)
                        default:
                            break
                        }
                    }
                } else if n == 0 {
                    running = false
                } else if errno != EAGAIN && errno != EINTR {
                    running = false
                }
            }

            // stdin → socket (user input as WebSocket binary frames)
            if fdIsSet(STDIN_FILENO, set: &readSet) {
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(STDIN_FILENO, &buf, buf.count)
                if n > 0 {
                    sendWebSocketBinaryFrame(fd: fd, data: Array(buf[0..<n]))
                } else if n == 0 {
                    running = false
                }
            }
        }

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

    // MARK: - WebSocket Frame Encoding (client → server, masked)

    private static func sendWebSocketBinaryFrame(fd: Int32, data: [UInt8]) {
        sendWebSocketFrame(fd: fd, opcode: 0x02, payload: data)
    }

    private static func sendWebSocketTextFrame(fd: Int32, text: String) {
        sendWebSocketFrame(fd: fd, opcode: 0x01, payload: Array(text.utf8))
    }

    private static func sendWebSocketPong(fd: Int32, data: [UInt8]) {
        sendWebSocketFrame(fd: fd, opcode: 0x0A, payload: data)
    }

    private static func sendWebSocketFrame(fd: Int32, opcode: UInt8, payload: [UInt8]) {
        var frame = [UInt8]()

        // FIN + opcode
        frame.append(0x80 | opcode)

        // Mask bit (client MUST mask) + payload length
        let len = payload.count
        if len < 126 {
            frame.append(0x80 | UInt8(len))
        } else if len < 65536 {
            frame.append(0x80 | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((len >> (i * 8)) & 0xFF))
            }
        }

        // Masking key (random)
        var maskKey = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&maskKey, 4)
        frame.append(contentsOf: maskKey)

        // Masked payload
        for (i, byte) in payload.enumerated() {
            frame.append(byte ^ maskKey[i % 4])
        }

        frame.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                _ = Darwin.write(fd, base, ptr.count)
            }
        }
    }

    // MARK: - WebSocket Frame Parsing (server → client, unmasked)

    private struct WSFrame {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private struct WebSocketFrameParser {
        private var buffer = [UInt8]()

        mutating func feed(_ data: [UInt8]) {
            buffer.append(contentsOf: data)
        }

        mutating func nextFrame() -> WSFrame? {
            guard buffer.count >= 2 else { return nil }

            let opcode = buffer[0] & 0x0F
            let masked = (buffer[1] & 0x80) != 0
            var payloadLen = Int(buffer[1] & 0x7F)
            var offset = 2

            if payloadLen == 126 {
                guard buffer.count >= offset + 2 else { return nil }
                payloadLen = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
                offset += 2
            } else if payloadLen == 127 {
                guard buffer.count >= offset + 8 else { return nil }
                payloadLen = 0
                for i in 0..<8 {
                    payloadLen = (payloadLen << 8) | Int(buffer[offset + i])
                }
                offset += 8
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

    private static func readHTTPResponseHeader(fd: Int32) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1)
        let endMarker = Data("\r\n\r\n".utf8)

        while true {
            let n = Darwin.read(fd, &buffer, 1)
            if n <= 0 {
                if n == 0 { throw VMError.message("Connection closed during handshake") }
                if errno == EINTR { continue }
                throw VMError.message("Read error: errno \(errno)")
            }
            data.append(contentsOf: buffer[0..<1])
            if data.count >= 4 && data.suffix(4) == endMarker {
                return String(data: data, encoding: .utf8) ?? ""
            }
            if data.count > 8192 {
                throw VMError.message("Response headers too large")
            }
        }
    }

    private static func generateWebSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, 16)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - fd_set helpers

    private static func fdZero(_ set: inout fd_set) {
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

        Opens an interactive terminal session on the guest VM.
        Uses WebSocket for bidirectional PTY streaming.

        Examples:
          vmctl shell --name MyVM
          vmctl shell --name MyVM --command /bin/bash
        """
        print(help)
    }
}
