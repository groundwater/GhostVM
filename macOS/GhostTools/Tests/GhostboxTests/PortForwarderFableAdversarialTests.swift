@testable import ghostbox
import Darwin
import Foundation
import XCTest

/// Adversarial probe for NetworkRelay's post-pump lifecycle: once one pump has
/// completed, terminal state updates on the drained connection are the relay's
/// only remaining death notice, and NetworkRelay.connectionStateChanged ignores
/// them (`.failed`/`.waiting` are honored only while `!pumpsStarted`).
final class PortForwarderFableAdversarialTests: XCTestCase {
    /// The ghostbox CLI ignores SIGPIPE as its first act (GhostboxCLI.main); the
    /// xctest host does not, and this probe writes into sockets the forwarder
    /// may reset mid-transfer, which would otherwise kill the process.
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
    }

    /// After the client half-closes (SHUT_WR), the client→target pump delivers
    /// isComplete, forwards the FIN, and finishes — leaving no outstanding
    /// operation on the client connection. If the client then aborts (RST) while
    /// the target stays open and silent — a curl/browser cancellation against a
    /// long-poll or SSE backend — the only signal the relay gets is the client
    /// NWConnection's terminal state update, which connectionStateChanged drops
    /// because pumpsStarted is true. The relay and its container-side connection
    /// then leak until the target volunteers data or the forwarder stops.
    ///
    /// Oracle: the relay's target NWConnection is the only socket in this
    /// process whose *peer* is the target port (the test's client socket peers
    /// with the published port; the target-side accepted socket peers with an
    /// ephemeral port). A correct relay tears down after the client dies,
    /// releasing that fd; the leak keeps it open indefinitely. Target-side
    /// reads cannot distinguish these outcomes (they return EOF either way once
    /// the forwarded FIN arrived), so the fd is the observable.
    func testClientAbortAfterHalfCloseReleasesTargetConnection() async throws {
        let (targetListener, targetPort) = try makeListener()
        defer { Darwin.close(targetListener) }
        let publishedPort = try reserveEphemeralPort()
        let forwarder = try await PublishedPortForwarder(PublishedPort(
            hostAddress: "127.0.0.1", hostPort: publishedPort, containerPort: targetPort
        ))
        addTeardownBlock { await forwarder.stop() }
        forwarder.start(targetAddress: "127.0.0.1")

        // Target: read the request and the forwarded FIN, then hold the
        // connection open and silent (long-poll analogue) until released.
        let handshake = expectation(description: "target saw request and forwarded FIN")
        let targetExited = expectation(description: "target thread exited")
        let release = DispatchSemaphore(value: 0)
        let handshakeFailure = LockedBox<String?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { targetExited.fulfill() }
            let connection = Darwin.accept(targetListener, nil, nil)
            guard connection >= 0 else {
                handshakeFailure.mutate { $0 = "target accept failed: errno \(errno)" }
                handshake.fulfill()
                return
            }
            defer { Darwin.close(connection) }
            var timeout = timeval(tv_sec: 4, tv_usec: 0)
            _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var buffer = [UInt8](repeating: 0, count: 16)
            let requestCount = Darwin.read(connection, &buffer, 7)
            let eofCount = requestCount == 7 ? Darwin.read(connection, &buffer, 1) : -1
            if requestCount != 7 || eofCount != 0 {
                handshakeFailure.mutate { $0 = "handshake failed: request \(requestCount), eof \(eofCount), errno \(errno)" }
            }
            handshake.fulfill()
            release.wait()
        }
        defer { release.signal() }

        let client = try connectClient(port: publishedPort)
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))
        XCTAssertEqual(Darwin.shutdown(client, SHUT_WR), 0)
        await fulfillment(of: [handshake], timeout: 4)
        if let failure = handshakeFailure.value {
            Darwin.close(client)
            return XCTFail(failure)
        }

        // Oracle precondition: with the relay established, its target-side
        // socket must be visible. If Network.framework ever stops exposing
        // per-connection fds this fails loudly instead of passing vacuously.
        let relayVisible = try await poll(seconds: 2) { [self] in
            !socketsPeered(toPort: targetPort).isEmpty
        }
        guard relayVisible else {
            Darwin.close(client)
            return XCTFail("oracle precondition failed: relay's target connection fd is not observable")
        }

        // Abort. The client→target pump already finished, so the client
        // connection has no outstanding receive: the terminal state update is
        // the only remaining death notice.
        var abort = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout.size(ofValue: abort)))
        Darwin.close(client)

        let released = try await poll(seconds: 3) { [self] in
            socketsPeered(toPort: targetPort).isEmpty
        }
        XCTAssertTrue(
            released,
            "relay ignored the client's terminal failure after half-close: the container-side "
                + "connection (peer port \(targetPort)) is still held 3s after the client aborted. "
                + "NetworkRelay.connectionStateChanged only honors .failed/.waiting while "
                + "!pumpsStarted, so a dead client leaks the relay — and pins the container-side "
                + "server's connection — until the silent target sends or the forwarder stops."
        )

        release.signal()
        await fulfillment(of: [targetExited], timeout: 2)
    }

    // MARK: - Helpers

    /// All fds in this process holding an IPv4 socket whose *peer* is `port`.
    private func socketsPeered(toPort port: UInt16) -> [Int32] {
        var matches: [Int32] = []
        for fd in 0..<Int32(min(Int(getdtablesize()), 8192)) {
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getpeername(fd, $0, &length)
                }
            }
            guard result == 0, address.ss_family == sa_family_t(AF_INET) else { continue }
            let peerPort = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            }
            if peerPort == port { matches.append(fd) }
        }
        return matches
    }

    private func poll(seconds: Double, _ condition: @escaping () -> Bool) async throws -> Bool {
        var elapsed = 0.0
        while elapsed < seconds {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
            elapsed += 0.05
        }
        return condition()
    }

    private func reserveEphemeralPort() throws -> UInt16 {
        let (fd, port) = try makeListener()
        Darwin.close(fd)
        return port
    }

    private func makeListener() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw PortForwardError.socket(operation: "bind/listen", code: code)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lookup = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard lookup == 0 else {
            let code = errno
            Darwin.close(fd)
            throw PortForwardError.socket(operation: "getsockname", code: code)
        }
        return (fd, UInt16(bigEndian: bound.sin_port))
    }

    private func connectClient(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw PortForwardError.socket(operation: "connect", code: code)
        }
        return fd
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate(_ transform: (inout Value) -> Void) {
        lock.withLock { transform(&stored) }
    }
}
