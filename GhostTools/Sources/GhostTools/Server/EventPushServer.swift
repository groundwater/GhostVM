import Foundation

/// Event types pushed from guest to host over NDJSON.
enum PushEvent {
    case files([String])
    case urls([String])
    case log(String)

    var jsonLine: String {
        switch self {
        case .files(let paths):
            let escaped = paths.map { escapeJSON($0) }
            return "{\"type\":\"files\",\"files\":[\(escaped.joined(separator: ","))]}"
        case .urls(let urls):
            let escaped = urls.map { escapeJSON($0) }
            return "{\"type\":\"urls\",\"urls\":[\(escaped.joined(separator: ","))]}"
        case .log(let message):
            return "{\"type\":\"log\",\"message\":\(escapeJSON(message))}"
        }
    }

    private func escapeJSON(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

/// EventPushServer listens on vsock port 5003 for persistent connections from the host.
/// Guest services push NDJSON events when data is available (files queued, URLs opened, logs).
///
/// Protocol:
/// 1. Host connects to port 5003
/// 2. Guest pushes NDJSON lines: {"type":"files","files":[...]}\n
/// 3. Host reads lines and dispatches events
/// 4. Connection drops if either side disconnects
final class EventPushServer: @unchecked Sendable {
    static let shared = EventPushServer()

    private let port: UInt32 = 5003
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private var acceptSource: DispatchSourceRead?

    /// Current connected client fd (-1 if none)
    private var clientFd: Int32 = -1
    private let clientLock = NSLock()

    private init() {}

    deinit {
        stop()
    }

    func start() async throws {
        print("[EventPushServer] Creating socket on port \(port)")

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

        var flags = fcntl(serverSocket, F_GETFL, 0)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        isRunning = true
        print("[EventPushServer] Listening on vsock port \(port)")

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

    /// Push an event to the connected host. No-op if no client connected.
    func pushEvent(_ event: PushEvent) {
        clientLock.lock()
        let fd = clientFd
        clientLock.unlock()

        guard fd >= 0 else { return }

        let line = event.jsonLine + "\n"
        line.withCString { ptr in
            _ = Darwin.write(fd, ptr, strlen(ptr))
        }
    }

    private func acceptConnection() {
        while isRunning {
            var clientAddr = sockaddr_vm(port: 0)
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

            let newFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            if newFd < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK { return }
                if err == EINTR { continue }
                if isRunning {
                    print("[EventPushServer] accept() failed: errno=\(err)")
                }
                return
            }

            // Close any existing client
            clientLock.lock()
            let oldFd = clientFd
            clientFd = newFd
            clientLock.unlock()
            if oldFd >= 0 {
                close(oldFd)
            }

            print("[EventPushServer] Client connected, fd=\(newFd)")

            // Block on read until host disconnects (on background thread)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var buf = [UInt8](repeating: 0, count: 1)
                while true {
                    let n = Darwin.read(newFd, &buf, 1)
                    if n <= 0 { break }
                }

                // Client disconnected — clear if still current
                self?.clientLock.lock()
                if self?.clientFd == newFd {
                    self?.clientFd = -1
                }
                self?.clientLock.unlock()
                close(newFd)
                print("[EventPushServer] Client disconnected")
            }
        }
    }

    func stop() {
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil

        clientLock.lock()
        let fd = clientFd
        clientFd = -1
        clientLock.unlock()
        if fd >= 0 { close(fd) }

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
}
