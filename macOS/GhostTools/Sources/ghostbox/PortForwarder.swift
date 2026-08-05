import Darwin
import Foundation

enum PortForwardError: Error, LocalizedError {
    case invalidAddress(String)
    case socket(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let address):
            return "invalid IPv4 address \(address)"
        case .socket(let operation, let code):
            return "\(operation) failed: errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}

final class PublishedPortForwarder: @unchecked Sendable {
    private let publication: PublishedPort
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenerFD: Int32
    private var started = false
    private var relays: [UUID: TCPRelay] = [:]

    init(_ publication: PublishedPort) throws {
        self.publication = publication
        self.queue = DispatchQueue(label: "org.ghostvm.ghostbox.publish.\(publication.hostPort)", qos: .userInitiated)
        self.listenerFD = try Self.openListener(address: publication.hostAddress, port: publication.hostPort)
    }

    func start(targetAddress: String) {
        lock.lock()
        guard !started, listenerFD >= 0 else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        queue.async { [self] in
            acceptConnections(targetAddress: targetAddress)
        }
    }

    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        let active = Array(relays.values)
        relays.removeAll()
        lock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        active.forEach { $0.stop() }
    }

    deinit {
        stop()
    }

    private func acceptConnections(targetAddress: String) {
        while true {
            lock.lock()
            let fd = listenerFD
            lock.unlock()
            guard fd >= 0 else { return }

            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                return
            }
            do {
                let targetFD = try Self.connect(address: targetAddress, port: publication.containerPort)
                let id = UUID()
                let relay = TCPRelay(clientFD: clientFD, targetFD: targetFD)
                lock.lock()
                relays[id] = relay
                lock.unlock()
                relay.start { [weak self] in
                    self?.removeRelay(id)
                }
            } catch {
                Darwin.close(clientFD)
                writeStderr("ghostbox: port \(publication.hostPort) forwarding failed: \(error.localizedDescription)\n")
            }
        }
    }

    private func removeRelay(_ id: UUID) {
        lock.lock()
        relays.removeValue(forKey: id)
        lock.unlock()
    }

    private static func openListener(address: String, port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        do {
            var enabled: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw PortForwardError.socket(operation: "setsockopt", code: errno)
            }
            var socketAddress = try ipv4SocketAddress(address: address, port: port)
            let bindResult = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw PortForwardError.socket(operation: "bind", code: errno) }
            guard Darwin.listen(fd, 128) == 0 else { throw PortForwardError.socket(operation: "listen", code: errno) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func connect(address: String, port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        do {
            var socketAddress = try ipv4SocketAddress(address: address, port: port)
            let result = withUnsafePointer(to: &socketAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else { throw PortForwardError.socket(operation: "connect", code: errno) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func ipv4SocketAddress(address: String, port: UInt16) throws -> sockaddr_in {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard address.withCString({ inet_pton(AF_INET, $0, &socketAddress.sin_addr) }) == 1 else {
            throw PortForwardError.invalidAddress(address)
        }
        return socketAddress
    }
}

private final class TCPRelay: @unchecked Sendable {
    private let clientFD: Int32
    private let targetFD: Int32
    private let lock = NSLock()
    private var remainingPumps = 2
    private var closed = false
    private var completion: (@Sendable () -> Void)?

    init(clientFD: Int32, targetFD: Int32) {
        self.clientFD = clientFD
        self.targetFD = targetFD
    }

    func start(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        self.completion = completion
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: clientFD, to: targetFD)
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: targetFD, to: clientFD)
        }
    }

    func stop() {
        _ = Darwin.shutdown(clientFD, SHUT_RDWR)
        _ = Darwin.shutdown(targetFD, SHUT_RDWR)
    }

    private func pump(from input: Int32, to output: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count > 0 {
                guard writeAll(fd: output, bytes: buffer, count: count) else { break }
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        _ = Darwin.shutdown(output, SHUT_WR)
        finishPump()
    }

    private func finishPump() {
        lock.lock()
        remainingPumps -= 1
        guard remainingPumps == 0, !closed else {
            lock.unlock()
            return
        }
        closed = true
        let completion = self.completion
        self.completion = nil
        lock.unlock()

        Darwin.close(clientFD)
        Darwin.close(targetFD)
        completion?()
    }

    private func writeAll(fd: Int32, bytes: [UInt8], count: Int) -> Bool {
        bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < count {
                let written = Darwin.write(fd, base.advanced(by: offset), count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
