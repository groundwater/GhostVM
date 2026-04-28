import Foundation
import os

/// HealthServer listens on vsock port 5002 for persistent health check connections.
///
/// Protocol:
/// 1. Host connects to port 5002
/// 2. Server writes: {"status":"ok","version":"<version>"}\n
/// 3. Server blocks on read() until host disconnects
/// 4. Connection close = host detects unhealthy
///
/// Accepts one connection at a time. New connections replace the old one.
/// Uses blocking I/O — kqueue/poll don't fire for AF_VSOCK on macOS guests,
/// so NIO cannot be used here.
final class HealthServer: @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "HealthServer")

    private let port: UInt32 = 5002
    private let lock = NSLock()
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var currentClientFd: Int32 = -1

    init() {}

    deinit {
        stop()
    }

    func start() async throws {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VsockServerError.socketCreationFailed(errno)
        }

        var optval: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_vm(port: port)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            throw VsockServerError.bindFailed(errno)
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw VsockServerError.listenFailed(errno)
        }

        publishListenSocket(fd)

        // Keep socket BLOCKING — kqueue/poll don't fire for AF_VSOCK on macOS guests
        Self.logger.info("Listening on vsock port \(self.port)")

        // Blocking accept loop on dedicated thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private nonisolated func publishListenSocket(_ fd: Int32) {
        lock.lock()
        serverSocket = fd
        isRunning = true
        lock.unlock()
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let running = isRunning
            let listenFd = serverSocket
            lock.unlock()
            guard running, listenFd >= 0 else { break }

            var clientAddr = sockaddr_vm(port: 0)
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(listenFd, sockaddrPtr, &addrLen)
                }
            }

            if clientSocket < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                break // socket closed by stop()
            }

            // Check if stop() was called while we were blocked in accept()
            lock.lock()
            let stillRunning = isRunning
            lock.unlock()
            if !stillRunning {
                close(clientSocket)
                break
            }

            // Suppress SIGPIPE on this socket — peer may disconnect during write
            var nosigpipe: Int32 = 1
            setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            Self.logger.info("Client connected (fd=\(clientSocket))")

            // Shutdown previous client to unblock its read(), but let handleConnection close it
            lock.lock()
            let old = currentClientFd
            currentClientFd = clientSocket
            lock.unlock()
            if old >= 0 {
                Darwin.shutdown(old, SHUT_RDWR)
            }

            // Handle on dedicated thread (blocks until disconnect).
            // Strong self capture ensures closeFd runs even during teardown.
            DispatchQueue.global(qos: .utility).async {
                self.handleConnection(clientSocket)
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        // Write version line with retry for EINTR
        let json = "{\"status\":\"ok\",\"version\":\"\(kGhostToolsVersion)\"}\n"
        let ok = json.withCString { ptr -> Bool in
            var remaining = Int(strlen(ptr))
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, ptr + offset, remaining)
                if n > 0 {
                    offset += n
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }

        guard ok else {
            Self.logger.warning("Version write failed (fd=\(fd))")
            closeFd(fd)
            return
        }

        Self.logger.info("Version sent, monitoring liveness (fd=\(fd))")

        // Block on read until host disconnects or shutdown unblocks us
        var buffer = [UInt8](repeating: 0, count: 1)
        while true {
            let n = Darwin.read(fd, &buffer, 1)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
        }

        Self.logger.info("Client disconnected (fd=\(fd))")
        closeFd(fd)
    }

    /// Single close point for client fds. Clears tracking if still the current client.
    private func closeFd(_ fd: Int32) {
        lock.lock()
        if currentClientFd == fd {
            currentClientFd = -1
        }
        lock.unlock()
        close(fd)
    }

    func stop() {
        lock.lock()
        isRunning = false
        let listenFd = serverSocket
        let clientFd = currentClientFd
        serverSocket = -1
        // Don't clear currentClientFd — handleConnection's closeFd() owns the close
        lock.unlock()

        // Shutdown client to unblock its blocking read; handleConnection will close it
        if clientFd >= 0 {
            Darwin.shutdown(clientFd, SHUT_RDWR)
        }
        // Close listen socket to unblock accept loop
        if listenFd >= 0 {
            close(listenFd)
        }
    }
}
