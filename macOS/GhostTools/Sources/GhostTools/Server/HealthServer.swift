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
    private var acceptSource: DispatchSourceRead?

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

        // Set non-blocking for accept loop
        var flags = fcntl(serverSocket, F_GETFL, 0)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        isRunning = true
        print("[HealthServer] Listening on vsock port \(port)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global(qos: .utility))
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()
    }

    private func acceptConnection() {
        while isRunning {
            var clientAddr = sockaddr_vm(port: 0)
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            if clientSocket < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { return }
                if err == EINTR { continue }
                if isRunning {
                    print("[HealthServer] accept() failed: errno=\(err)")
                }
                return
            }

            // Handle on background thread (blocks until disconnect)
            DispatchQueue.global(qos: .utility).async {
                self.handleConnection(clientSocket)
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
        acceptSource?.cancel()
        acceptSource = nil
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
}
