import Foundation

/// HealthServer listens on vsock port 5002 for persistent health check connections.
///
/// Protocol:
/// 1. Host connects to port 5002
/// 2. Server writes: {"status":"ok","version":"<version>"}\n
/// 3. Server blocks on read() until host disconnects
/// 4. Connection close = host detects unhealthy
///
/// Accepts one connection at a time. New connections replace the old one.
final class HealthServer: @unchecked Sendable {
    private let port: UInt32 = 5002
    private var serverSocket: Int32 = -1
    private var isRunning = false

    init() {}

    deinit {
        stop()
    }

    func start() async throws {
        print("[HealthServer] Creating socket on port \(port)")

        serverSocket = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw VsockServerError.socketCreationFailed(errno)
        }

        var optval: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_vm(port: port)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        guard bindResult == 0 else {
            close(serverSocket)
            throw VsockServerError.bindFailed(errno)
        }

        guard listen(serverSocket, 1) == 0 else {
            close(serverSocket)
            throw VsockServerError.listenFailed(errno)
        }

        // Keep socket BLOCKING — kqueue/poll don't fire for AF_VSOCK on macOS guests
        isRunning = true
        print("[HealthServer] Listening on vsock port \(port)")

        // Blocking accept loop on dedicated thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while self?.isRunning == true {
                var clientAddr = sockaddr_vm(port: 0)
                var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

                let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(self?.serverSocket ?? -1, sockaddrPtr, &addrLen)
                    }
                }

                if clientSocket < 0 {
                    if errno == EINTR { continue }
                    break // socket closed by stop()
                }

                // Handle on background thread (blocks until disconnect)
                DispatchQueue.global(qos: .utility).async {
                    self?.handleConnection(clientSocket)
                }
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        // Write version line
        let json = "{\"status\":\"ok\",\"version\":\"\(kGhostToolsVersion)\"}\n"
        _ = json.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }

        // Block on read until host disconnects
        var buffer = [UInt8](repeating: 0, count: 1)
        while true {
            let n = Darwin.read(fd, &buffer, 1)
            if n <= 0 { break }
        }

        print("[HealthServer] Client disconnected")
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
}
