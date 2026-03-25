import Foundation

public enum AsyncVSockIOError: Error {
    case closed
    case eofBeforeExpected(expected: Int, received: Int)
    case interrupted
    case wouldBlock
    case syscall(op: String, errno: Int32)
    case cancelled
}

// MARK: - SocketChannel protocol

public protocol SocketChannel: Sendable {
    func read(maxBytes: Int) async throws -> Data?
    func writeAll(_ data: Data) async throws
    func shutdownWrite() throws
    func close()
}

extension SocketChannel {
    public func readExactly(_ count: Int) async throws -> Data {
        precondition(count >= 0, "readExactly(_:) requires non-negative count")
        if count == 0 { return Data() }

        var result = Data()
        result.reserveCapacity(count)

        while result.count < count {
            let remaining = count - result.count
            guard let chunk = try await read(maxBytes: remaining) else {
                throw AsyncVSockIOError.eofBeforeExpected(expected: count, received: result.count)
            }
            result.append(chunk)
        }

        return result
    }
}

// MARK: - BlockingVSockChannel

/// Blocking I/O channel for vsock file descriptors.
///
/// Uses dedicated DispatchQueue threads for read and write, bridged to async/await
/// via CheckedContinuation. This works around the macOS limitation where kqueue/poll/
/// DispatchSource don't fire for AF_VSOCK sockets.
public final class BlockingVSockChannel: SocketChannel, @unchecked Sendable {
    private let readQueue = DispatchQueue(label: "org.ghostvm.blockingvsock.read", qos: .userInitiated)
    private let writeQueue = DispatchQueue(label: "org.ghostvm.blockingvsock.write", qos: .userInitiated)
    private let stateLock = NSLock()

    private var fd: Int32
    private let ownsFD: Bool
    private var isClosed = false

    public init(fd: Int32, ownsFD: Bool = false) {
        self.fd = fd
        self.ownsFD = ownsFD

        // Ensure blocking mode (clear O_NONBLOCK)
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 && (flags & O_NONBLOCK) != 0 {
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        }
    }

    deinit {
        if ownsFD {
            close()
        }
    }

    public func read(maxBytes: Int) async throws -> Data? {
        precondition(maxBytes > 0, "read(maxBytes:) requires maxBytes > 0")

        let currentFD = try validatedFD()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                readQueue.async {
                    var buffer = [UInt8](repeating: 0, count: maxBytes)
                    while true {
                        let n = Darwin.read(currentFD, &buffer, buffer.count)
                        if n > 0 {
                            continuation.resume(returning: Data(buffer[0..<n]))
                            return
                        }
                        if n == 0 {
                            continuation.resume(returning: nil)
                            return
                        }
                        let err = errno
                        if err == EINTR { continue }
                        continuation.resume(throwing: AsyncVSockIOError.syscall(op: "read", errno: err))
                        return
                    }
                }
            }
        } onCancel: {
            self.shutdownForCancel()
        }
    }

    public func writeAll(_ data: Data) async throws {
        if data.isEmpty { return }

        let currentFD = try validatedFD()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                writeQueue.async {
                    var offset = 0
                    while offset < data.count {
                        let written = data.withUnsafeBytes { ptr in
                            Darwin.write(currentFD, ptr.baseAddress! + offset, data.count - offset)
                        }
                        if written > 0 {
                            offset += written
                            continue
                        }
                        if written == 0 {
                            continuation.resume(throwing: AsyncVSockIOError.syscall(op: "write", errno: EPIPE))
                            return
                        }
                        let err = errno
                        if err == EINTR { continue }
                        continuation.resume(throwing: AsyncVSockIOError.syscall(op: "write", errno: err))
                        return
                    }
                    continuation.resume(returning: ())
                }
            }
        } onCancel: {
            self.shutdownForCancel()
        }
    }

    public func shutdownWrite() throws {
        let currentFD = try validatedFD()
        if Darwin.shutdown(currentFD, SHUT_WR) < 0 {
            let err = errno
            if err != ENOTCONN {
                throw AsyncVSockIOError.syscall(op: "shutdown", errno: err)
            }
        }
    }

    public func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        let currentFD = fd
        fd = -1
        stateLock.unlock()

        if currentFD >= 0 {
            Darwin.close(currentFD)
        }
    }

    private func validatedFD() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isClosed || fd < 0 {
            throw AsyncVSockIOError.closed
        }
        return fd
    }

    /// Unblock any threads blocked in read/write by shutting down the socket.
    /// Safer than close() because it avoids fd-reuse races.
    private func shutdownForCancel() {
        stateLock.lock()
        let currentFD = fd
        stateLock.unlock()
        if currentFD >= 0 {
            Darwin.shutdown(currentFD, SHUT_RDWR)
        }
    }
}

// MARK: - AsyncVSockIO (non-blocking, DispatchSource-based — for TCP)

private final class AsyncIOWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var source: DispatchSourceProtocol?
    private var done = false

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func setSource(_ source: DispatchSourceProtocol) {
        lock.lock()
        self.source = source
        lock.unlock()
    }

    func succeed() {
        finish(nil)
    }

    func cancel() {
        finish(AsyncVSockIOError.cancelled)
    }

    private func finish(_ error: Error?) {
        let cont: CheckedContinuation<Void, Error>?
        let src: DispatchSourceProtocol?

        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        cont = continuation
        continuation = nil
        src = source
        source = nil
        lock.unlock()

        src?.cancel()
        if let error = error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: ())
        }
    }
}

private final class WaiterHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: AsyncIOWaiter?

    func set(_ waiter: AsyncIOWaiter?) {
        lock.lock()
        self.waiter = waiter
        lock.unlock()
    }

    func cancelCurrent() {
        lock.lock()
        let w = waiter
        lock.unlock()
        w?.cancel()
    }
}

public final class AsyncVSockIO: SocketChannel, @unchecked Sendable {
    private let ioQueue = DispatchQueue(label: "org.ghostvm.asyncvsockio", qos: .userInitiated)
    private let stateLock = NSLock()

    private var fd: Int32
    private let ownsFD: Bool
    private var isClosed = false

    public init(fd: Int32, ownsFD: Bool = false) {
        self.fd = fd
        self.ownsFD = ownsFD

        let flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 {
            let err = errno
            fatalError("[AsyncVSockIO] Failed to read fd flags: fd=\(fd) errno=\(err) (\(String(cString: strerror(err))))")
        }
        if fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
            let err = errno
            fatalError("[AsyncVSockIO] Failed to set O_NONBLOCK: fd=\(fd) errno=\(err) (\(String(cString: strerror(err))))")
        }
    }

    deinit {
        if ownsFD {
            close()
        }
    }

    public func read(maxBytes: Int) async throws -> Data? {
        precondition(maxBytes > 0, "read(maxBytes:) requires maxBytes > 0")

        while true {
            if Task.isCancelled { throw AsyncVSockIOError.cancelled }

            let currentFD = try validatedFD()
            var buffer = [UInt8](repeating: 0, count: maxBytes)
            let n = Darwin.read(currentFD, &buffer, buffer.count)

            if n > 0 {
                return Data(buffer[0..<n])
            }
            if n == 0 {
                return nil
            }

            let err = errno
            if err == EINTR {
                continue
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                try await waitForReadability()
                continue
            }
            throw AsyncVSockIOError.syscall(op: "read", errno: err)
        }
    }

    public func readExactly(_ count: Int) async throws -> Data {
        precondition(count >= 0, "readExactly(_:) requires non-negative count")
        if count == 0 { return Data() }

        var result = Data()
        result.reserveCapacity(count)

        while result.count < count {
            let remaining = count - result.count
            guard let chunk = try await read(maxBytes: remaining) else {
                throw AsyncVSockIOError.eofBeforeExpected(expected: count, received: result.count)
            }
            result.append(chunk)
        }

        return result
    }

    public func writeAll(_ data: Data) async throws {
        if data.isEmpty { return }

        var offset = 0
        while offset < data.count {
            if Task.isCancelled { throw AsyncVSockIOError.cancelled }

            let currentFD = try validatedFD()
            let written = data.withUnsafeBytes { ptr in
                Darwin.write(currentFD, ptr.baseAddress! + offset, data.count - offset)
            }

            if written > 0 {
                offset += written
                continue
            }
            if written == 0 {
                throw AsyncVSockIOError.syscall(op: "write", errno: EPIPE)
            }

            let err = errno
            if err == EINTR {
                continue
            }
            if err == EAGAIN || err == EWOULDBLOCK {
                try await waitForWritability()
                continue
            }
            throw AsyncVSockIOError.syscall(op: "write", errno: err)
        }
    }

    public func shutdownWrite() throws {
        let currentFD = try validatedFD()
        if Darwin.shutdown(currentFD, SHUT_WR) < 0 {
            let err = errno
            if err != ENOTCONN {
                throw AsyncVSockIOError.syscall(op: "shutdown", errno: err)
            }
        }
    }

    public func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        let currentFD = fd
        fd = -1
        stateLock.unlock()

        if currentFD >= 0 {
            Darwin.close(currentFD)
        }
    }

    private func validatedFD() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isClosed || fd < 0 {
            throw AsyncVSockIOError.closed
        }
        return fd
    }

    private func waitForReadability() async throws {
        try await waitForEvent(makeSource: { fd in
            DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        })
    }

    private func waitForWritability() async throws {
        try await waitForEvent(makeSource: { fd in
            DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
        })
    }

    private func waitForEvent(makeSource: (Int32) -> DispatchSourceProtocol) async throws {
        if Task.isCancelled { throw AsyncVSockIOError.cancelled }
        let currentFD = try validatedFD()
        let holder = WaiterHolder()

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = AsyncIOWaiter(continuation)
                holder.set(waiter)

                let source = makeSource(currentFD)
                waiter.setSource(source)
                source.setEventHandler {
                    waiter.succeed()
                }
                source.setCancelHandler {}
                source.resume()
            }
        }, onCancel: {
            holder.cancelCurrent()
        })
    }
}

// MARK: - Relay functions

public func pipeBidirectional(_ a: some SocketChannel, _ b: some SocketChannel) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await pipeOneWay(from: a, to: b)
        }
        group.addTask {
            try await pipeOneWay(from: b, to: a)
        }
        do {
            try await group.waitForAll()
        } catch {
            group.cancelAll()
            throw error
        }
    }
}

private func pipeOneWay(from source: some SocketChannel, to destination: some SocketChannel) async throws {
    while let chunk = try await source.read(maxBytes: 65536) {
        if !chunk.isEmpty {
            try await destination.writeAll(chunk)
        }
    }

    do {
        try destination.shutdownWrite()
    } catch AsyncVSockIOError.closed {
        // Closed while shutting down write is expected during teardown.
    }
}
