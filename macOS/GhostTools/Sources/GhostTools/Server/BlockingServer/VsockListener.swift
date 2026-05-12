import Foundation
import Darwin
import os

/// Blocking AF_VSOCK listener. Thread-per-connection, bounded.
///
/// Sits in place of the deleted NIO-based server. Built specifically to
/// sidestep macOS's AF_VSOCK non-blocking-write bug (see
/// `bug-repros/macos-vsock-write-loss/`): blocking `write()` is the only
/// kernel path that handles back-pressure honestly.
final class VsockListener: @unchecked Sendable {
    private static let logger = Logger(subsystem: "org.ghostvm.ghosttools", category: "VsockListener")

    private let port: UInt32
    private let router: Router
    private let maxConnections: Int
    private let connectionSlots: DispatchSemaphore
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var stopping = false

    var onStatusChange: ((Bool) -> Void)?

    init(port: UInt32 = 5000, router: Router, maxConnections: Int = 64) {
        self.port = port
        self.router = router
        self.maxConnections = maxConnections
        self.connectionSlots = DispatchSemaphore(value: maxConnections)
    }

    deinit { stop() }

    /// Synchronous start. Binds, listens, kicks off the accept thread, returns.
    /// Throws if bind/listen fails.
    func start() throws {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VsockServerError.socketCreationFailed(errno) }

        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_vm(port: port)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw VsockServerError.bindFailed(errno)
        }
        guard listen(fd, 128) == 0 else {
            Darwin.close(fd)
            throw VsockServerError.listenFailed(errno)
        }

        listenFD = fd
        Self.logger.info("Listening on vsock port \(self.port, privacy: .public) (fd=\(fd))")
        onStatusChange?(true)

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "VsockListener-accept-\(port)"
        acceptThread = thread
        thread.start()
    }

    func stop() {
        stopping = true
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
        onStatusChange?(false)
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        let fd = listenFD
        while !stopping {
            // Block until a connection slot is free. This is the bound on
            // concurrent connections — extra inbound connects sit in the
            // kernel listen backlog until a worker finishes.
            connectionSlots.wait()
            if stopping {
                connectionSlots.signal()
                return
            }

            var clientAddr = sockaddr_vm(port: 0)
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &addrLen)
                }
            }

            if clientFD < 0 {
                let e = errno
                connectionSlots.signal()
                if stopping { return }
                if e == EINTR { continue }
                Self.logger.error("accept failed: errno \(e)")
                // Brief pause to avoid a tight error loop on persistent failures.
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            Self.logger.debug("accepted client fd=\(clientFD)")
            spawnWorker(fd: clientFD)
        }
    }

    private func spawnWorker(fd: Int32) {
        let router = self.router
        let slots = self.connectionSlots
        let workerThread = Thread {
            defer { slots.signal() }
            ConnectionWorker(fd: fd, router: router).run()
        }
        workerThread.name = "VsockListener-worker-\(fd)"
        workerThread.start()
    }
}
