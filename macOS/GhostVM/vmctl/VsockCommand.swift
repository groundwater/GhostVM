import Foundation
import GhostVMKit
#if canImport(Darwin)
import Darwin
#endif

/// `vmctl vsock connect <port>` — opens a raw vsock connection to the guest
/// on the given port and bridges it to vmctl's stdin/stdout. Netcat for vsock.
///
/// Usage:
///   vmctl vsock connect --name MyVM <port>
///   vmctl vsock connect --socket /path/to/sock <port>
///
/// Pipe-friendly:
///   vmctl vsock connect --name MyVM 5004 | dd of=/dev/null bs=1M
///   dd if=/dev/zero bs=1M count=100 | vmctl vsock connect --name MyVM 5004
///
/// Half-close semantics (matches nc):
///   ^D / stdin EOF → SHUT_WR on the unix socket → helper SHUT_WRs the vsock
///                    → peer in VM sees EOF on its read side. We keep reading
///                    until the peer closes back.
///   ^C / SIGINT   → default signal handler exits the process; OS closes fds
///                    → cascade to helper closing the vsock.
enum VsockCommand {

    static func run(arguments: [String]) throws {
        var args = arguments

        // First positional after parsing flags is the subcommand: `connect`.
        guard !args.isEmpty else {
            showHelp()
            throw VMError.message("Missing subcommand. Try `vmctl vsock connect <port>`.")
        }

        var socketPath: String?
        var vmName: String?

        // Pull off flags from anywhere on the line.
        var positional: [String] = []
        while !args.isEmpty {
            switch args[0] {
            case "--socket", "-s":
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --socket") }
                socketPath = args.removeFirst()
            case "--name", "-n":
                args.removeFirst()
                guard !args.isEmpty else { throw VMError.message("Missing value for --name") }
                vmName = args.removeFirst()
            case "--help", "-h":
                showHelp()
                return
            default:
                positional.append(args.removeFirst())
            }
        }

        guard let sub = positional.first else {
            showHelp()
            throw VMError.message("Missing subcommand. Try `vmctl vsock connect <port>`.")
        }

        switch sub {
        case "connect":
            guard positional.count >= 2, let port = UInt32(positional[1]) else {
                throw VMError.message("Usage: vmctl vsock connect <port>")
            }
            try runConnect(port: port, socketPath: socketPath, vmName: vmName)
        default:
            throw VMError.message("Unknown vsock subcommand: \(sub). Try `connect`.")
        }
    }

    // MARK: - connect

    private static func runConnect(port: UInt32, socketPath: String?, vmName: String?) throws {
        let resolvedPath = try resolveHelperSocket(socketPath: socketPath, vmName: vmName)

        let fd = try connectUnixSocket(path: resolvedPath)
        // We intentionally don't `defer Darwin.close(fd)` — control transfers
        // to the byte-bridge threads below, and they own fd lifetime.

        // Tell helper which vsock port we want. The endpoint takes a header,
        // not a query, so the body is empty.
        let request = "GET /api/v1/vsock-connect HTTP/1.1\r\n" +
            "Host: localhost\r\n" +
            "Vsock-Port: \(port)\r\n" +
            "Connection: Upgrade\r\n" +
            "Upgrade: vsock\r\n" +
            "\r\n"

        try blockingWriteAll(fd: fd, string: request)

        // Read response status line (and headers) — expect 101.
        let responseHeaders = try readHTTPHeaders(fd: fd)
        guard let statusLine = responseHeaders.split(separator: "\r\n").first else {
            throw VMError.message("Helper returned empty response")
        }
        guard statusLine.contains(" 101 ") else {
            // Drain whatever body the helper sent (small) and surface it.
            let body = drainSocket(fd: fd, maxBytes: 8 * 1024)
            Darwin.close(fd)
            let bodyText = String(data: body, encoding: .utf8) ?? ""
            throw VMError.message("Helper rejected vsock-connect: \(statusLine)\n\(bodyText)")
        }

        // Bidirectional blocking byte bridge.
        bridgeBlocking(unixFD: fd)
    }

    // MARK: - Byte bridge

    /// Spawns two threads doing blocking I/O between stdin/stdout and the
    /// unix-socket fd. Returns when the network-side direction (socket →
    /// stdout) hits EOF. The stdin-→-socket thread is fire-and-forget; if
    /// it's still blocked on a read at exit, the process termination will
    /// reap it. This matches `nc`'s behavior when nothing is piped in.
    private static func bridgeBlocking(unixFD: Int32) {
        let stdoutDoneSem = DispatchSemaphore(value: 0)

        // stdin → unix socket  (fire and forget; we don't wait on this side)
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                _ = buffer.withUnsafeBufferPointer { ptr -> Bool in
                    guard let base = ptr.baseAddress else { return n == 0 }
                    return writeAllRaw(fd: unixFD, ptr: base, count: n)
                }
            }
            // stdin EOF → half-close the write side so the helper sees EOF
            // and propagates SHUT_WR to the vsock peer.
            Darwin.shutdown(unixFD, SHUT_WR)
        }

        // unix socket → stdout  (this is the one we wait on)
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(unixFD, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                _ = buffer.withUnsafeBufferPointer { ptr -> Bool in
                    guard let base = ptr.baseAddress else { return n == 0 }
                    return writeAllRaw(fd: STDOUT_FILENO, ptr: base, count: n)
                }
            }
            stdoutDoneSem.signal()
        }

        stdoutDoneSem.wait()
        Darwin.close(unixFD)
    }

    // MARK: - Helpers

    private static func resolveHelperSocket(socketPath: String?, vmName: String?) throws -> String {
        let resolved: String
        if let sp = socketPath {
            resolved = (sp as NSString).expandingTildeInPath
        } else if let name = vmName {
            let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            resolved = supportDir.appendingPathComponent("GhostVM/api/\(name).GhostVM.sock").path
        } else {
            throw VMError.message("Specify --socket <path> or --name <VMName>")
        }

        guard FileManager.default.fileExists(atPath: resolved) else {
            throw VMError.message("Helper socket not found at \(resolved). Is the VM running?")
        }
        return resolved
    }

    private static func connectUnixSocket(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMError.message("socket(AF_UNIX) failed: errno \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let nul: CChar = 0
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { dstPtr in
                    strncpy(dstPtr, src, 103)
                    dstPtr[103] = nul
                }
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw VMError.message("connect(\(path)) failed: errno \(e)")
        }
        return fd
    }

    private static func blockingWriteAll(fd: Int32, string: String) throws {
        try string.withCString { ptr in
            let len = strlen(ptr)
            var offset = 0
            while offset < len {
                let n = Darwin.write(fd, ptr + offset, len - offset)
                if n > 0 { offset += n }
                else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000) }
                else { throw VMError.message("write to helper failed: errno \(errno)") }
            }
        }
    }

    private static func writeAllRaw(fd: Int32, ptr: UnsafeRawPointer, count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, ptr + offset, count - offset)
            if n > 0 { offset += n }
            else if n < 0 && (errno == EAGAIN || errno == EINTR) { usleep(1000) }
            else { return false }
        }
        return true
    }

    private static func readHTTPHeaders(fd: Int32) throws -> String {
        // Read one byte at a time until \r\n\r\n. Headers are tiny.
        var buffer = [UInt8]()
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        var one: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &one, 1)
            if n == 1 {
                buffer.append(one)
                if buffer.count >= 4 && Array(buffer.suffix(4)) == separator {
                    break
                }
                if buffer.count > 16384 {
                    throw VMError.message("Helper response headers exceeded 16 KiB")
                }
            } else if n == 0 {
                throw VMError.message("Helper closed connection before sending response headers")
            } else if errno == EINTR {
                continue
            } else {
                throw VMError.message("read failed waiting for helper headers: errno \(errno)")
            }
        }
        return String(bytes: buffer, encoding: .utf8) ?? ""
    }

    private static func drainSocket(fd: Int32, maxBytes: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            let n = Darwin.read(fd, &buffer, min(buffer.count, maxBytes - data.count))
            if n > 0 { data.append(contentsOf: buffer[0..<n]) }
            else { break }
        }
        return data
    }

    // MARK: - Help

    private static func showHelp() {
        let text = """
        Usage:
          vmctl vsock connect --name <VMName> <port>
          vmctl vsock connect --socket <path>  <port>

        Opens a raw vsock connection to the guest on the given port, bridged
        to vmctl's stdin and stdout (netcat-style). Use shell pipes for I/O:

          vmctl vsock connect --name MyVM 5004 | dd of=/dev/null bs=1M
          dd if=/dev/zero bs=1M count=100 | vmctl vsock connect -n MyVM 5004
          printf 'GET / HTTP/1.1\\r\\nHost: x\\r\\n\\r\\n' | vmctl vsock connect -n MyVM 5000

        Options:
          --name, -n <VMName>    Resolve helper socket from VM name.
          --socket, -s <path>    Use a specific helper socket path.
          --help, -h             Show this help.
        """
        print(text)
    }
}
