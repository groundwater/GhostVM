@testable import ghostbox
import Darwin
import Foundation
import XCTest

/// Regression tests for the field-reported ghostbox port-forwarding failures against
/// Node.js servers (timeouts with zero bytes received, an orphaned forwarder holding
/// the port, and pass-only-after-restart behavior). One test per diagnostic scenario:
///
///  1. Node raw close        → testNodeRawClose_ColdThenWarmSequentialConnectionsAllForwarded
///  2. Node raw keep-alive   → testNodeRawKeepAlive_WarmSecondConnectionReceivesDataWithoutEOF
///  3. Node HTTP close       → testNodeHTTPClose_ConnectAfterForwarderStopIsRefusedNotAcceptedWithZeroBytes
///  4. Node HTTP keep-alive  → testNodeHTTPKeepAlive_SecondRequestOnReusedConnectionReceivesResponse
///  5. Node delayed response → testNodeDelayed_ResponsesArriveWhileForwarderAcceptsConcurrentConnection
///  6. Node 1 MiB response   → testNodeOneMiB_FullDeliveryUnderSlowClientReadBackpressure
///  7. Node mounted source   → testNodeMountedSource_ServerScriptExecutedFromTemporaryDirectoryPath
///  8. Node server-first     → testNodeServerFirst_ReplacementForwarderOnSamePortAfterStopDeliversBanner
///  9. Node echo             → testNodeEcho_InterleavedRoundTripsOnLongLivedConnection
/// 10. Node half-close       → testNodeHalfClose_ForwarderAcceptsNextConnectionAfterHalfClosedRelay
/// 11. Keep-alive pool       → testNodeEcho_KeepAliveConnectionPoolBeyondThirtyTwoStillForwarded
///
/// Root-cause hypothesis these tests target: on macOS, shutdown(2) on a *listening*
/// socket fails with ENOTCONN and does NOT wake a blocked accept(2) (verified
/// empirically on this host; Linux differs). The former forwarder relied on exactly
/// that shutdown once `start()` had run, so a stopped forwarder kept the
/// host port bound: the next client connect() still succeeds and is then closed with
/// zero bytes transferred, and a replacement forwarder cannot bind the port
/// (EADDRINUSE even with SO_REUSEADDR, verified empirically). That reproduces the
/// field pattern — stale/orphaned listener, "timeout, zero bytes", recovery only
/// after the stale process was killed. Scenarios 3 and 8 assert the correct
/// lifecycle behavior and are expected to FAIL on the defective implementation.
/// The other scenarios pin down data-path dimensions (warm reuse, in-connection
/// reuse, delayed output, backpressure, half-close, server-first ordering) that the
/// field diagnostic could not separate from the lifecycle defect.
///
/// Review note on the pre-existing Node tests in PortForwarderTests.swift: they
/// exercise single-connection happy paths through a freshly created forwarder, and
/// their Node fixture calls `server.close()` as soon as the first socket closes, so
/// by construction they cannot observe second-connection (warm) behavior, forwarder
/// stop/restart, or stale-listener effects — the dimensions the diagnostic
/// implicates. They are preserved unchanged; the fixture below serves an unlimited
/// number of connections instead.
final class PortForwarderNodeScenarioTests: XCTestCase {

    // MARK: - Scenario 1: raw close

    /// Field: "Node raw close: Timeout, HTTP 000". A single forwarder must keep
    /// forwarding across repeated sequential connections — the cold (first) and
    /// every warm (subsequent) connection must behave identically. Catches an
    /// accept loop or relay-accounting failure after the first relay completes.
    func testNodeRawClose_ColdThenWarmSequentialConnectionsAllForwarded() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "raw-close")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        for attempt in 1...4 {
            let client = try connectClient(port: publishedPort)
            defer { Darwin.close(client) }
            XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)), "attempt \(attempt)")
            XCTAssertEqual(
                readToEOF(fd: client), Array("raw-ok".utf8),
                "attempt \(attempt): connection \(attempt == 1 ? "cold" : "warm") received wrong or no data"
            )
        }
    }

    // MARK: - Scenario 2: raw keep-alive

    /// Field: "Node raw keep-alive: Timeout, HTTP 000, but one cold run passed in
    /// 5.139ms" — i.e. the first connection after a fresh start could pass while
    /// later ones failed. The server writes its reply but never closes, so bytes
    /// must be relayed as they arrive (no waiting for EOF), on the cold AND the
    /// warm connection.
    func testNodeRawKeepAlive_WarmSecondConnectionReceivesDataWithoutEOF() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "raw-keep-alive")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let cold = try connectClient(port: publishedPort)
        XCTAssertTrue(writeBytes(fd: cold, Array("request".utf8)))
        XCTAssertEqual(readExactly(fd: cold, count: 6), Array("raw-ok".utf8), "cold connection")
        Darwin.close(cold)

        let warm = try connectClient(port: publishedPort)
        defer { Darwin.close(warm) }
        XCTAssertTrue(writeBytes(fd: warm, Array("request".utf8)))
        XCTAssertEqual(
            readExactly(fd: warm, count: 6), Array("raw-ok".utf8),
            "warm connection after a completed keep-alive relay received no data (field: only the cold run passed)"
        )
    }

    // MARK: - Scenario 3: HTTP close

    /// Field: "Node HTTP close: Timeout, zero bytes" together with "an orphaned
    /// forwarding process was found and removed". After `stop()`, the published
    /// port must actually be released: a new client connect must be REFUSED.
    /// On the defective implementation, macOS shutdown(2) on the listening socket
    /// is a silent ENOTCONN no-op, the listener stays bound, the client's connect
    /// succeeds, and it then reads zero bytes — the exact field signature.
    func testNodeHTTPClose_ConnectAfterForwarderStopIsRefusedNotAcceptedWithZeroBytes() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "http-close")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        defer { drainStaleListener(port: publishedPort) }

        // Warm exchange first: forwarding works while the forwarder is running.
        let client = try connectClient(port: publishedPort)
        XCTAssertTrue(writeBytes(fd: client, Array(Self.httpRequest.utf8)))
        XCTAssertEqual(readToEOF(fd: client), Array(Self.httpCloseResponse.utf8), "pre-stop request")
        Darwin.close(client)

        await forwarder.stop()

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = try loopbackAddress(port: publishedPort)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            var byte = UInt8(0)
            let readCount = Darwin.read(fd, &byte, 1)
            XCTFail(
                "connect() to a stopped forwarder's port succeeded — the listener is still bound "
                    + "(stale listener; shutdown(2) on a listening socket is a no-op on macOS). "
                    + "Subsequent read returned \(readCount): the field 'timeout, zero bytes' failure."
            )
        } else {
            XCTAssertEqual(errno, ECONNREFUSED, "expected connection refused after stop(), got errno \(errno)")
        }
    }

    // MARK: - Scenario 4: HTTP keep-alive

    /// Field: "Node HTTP keep-alive: Timeout, zero bytes". curl reuses one TCP
    /// connection for keep-alive; the relay must keep both pumps alive after the
    /// first response and deliver a second response on the SAME connection.
    func testNodeHTTPKeepAlive_SecondRequestOnReusedConnectionReceivesResponse() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "http-keep-alive")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connectClient(port: publishedPort)
        defer { Darwin.close(client) }
        for request in 1...2 {
            XCTAssertTrue(writeBytes(fd: client, Array(Self.httpRequest.utf8)), "request \(request)")
            XCTAssertEqual(
                readExactly(fd: client, count: Self.httpKeepAliveResponse.utf8.count),
                Array(Self.httpKeepAliveResponse.utf8),
                "request \(request) on the reused keep-alive connection got no/short response"
            )
        }
    }

    // MARK: - Scenario 5: delayed response

    /// Field: "Node delayed response: Timeout, zero bytes". The reply arrives after
    /// a quiet period. While one relay is idle waiting for the delayed bytes, the
    /// forwarder must still accept and serve a second connection (the accept loop
    /// must not be serialized behind an in-flight relay), and both delayed replies
    /// must be delivered.
    func testNodeDelayed_ResponsesArriveWhileForwarderAcceptsConcurrentConnection() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "delayed")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let first = try connectClient(port: publishedPort)
        defer { Darwin.close(first) }
        XCTAssertTrue(writeBytes(fd: first, Array("request".utf8)))

        // Second connection is opened while the first is still awaiting its reply.
        let second = try connectClient(port: publishedPort)
        defer { Darwin.close(second) }
        XCTAssertTrue(writeBytes(fd: second, Array("request".utf8)))

        XCTAssertEqual(readToEOF(fd: second), Array("delayed".utf8), "second (concurrent) connection")
        XCTAssertEqual(readToEOF(fd: first), Array("delayed".utf8), "first connection's delayed reply")
    }

    // MARK: - Scenario 6: 1 MiB response

    /// Field: "Node 1 MiB response: Timeout, zero bytes". Node writes the full
    /// 1 MiB immediately; the client is given a tiny receive buffer so the relay's
    /// blocking writes experience sustained backpressure. Every byte must arrive
    /// intact and the relay must not stall or truncate mid-transfer.
    func testNodeOneMiB_FullDeliveryUnderSlowClientReadBackpressure() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "large")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connectClient(port: publishedPort) { fd in
            var small: Int32 = 8 * 1024
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout.size(ofValue: small)))
        }
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))

        // Give the server/relay a head start so the small receive window fills and
        // the relay's write path actually blocks before we begin draining.
        usleep(300_000)
        let expected = 1024 * 1024
        var received = 0
        var mismatched = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count > 0 {
                if !mismatched, buffer[..<count].contains(where: { $0 != 0x61 }) { mismatched = true }
                received += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        XCTAssertEqual(received, expected, "1 MiB response truncated under client-side backpressure")
        XCTAssertFalse(mismatched, "1 MiB response corrupted in transit")
    }

    // MARK: - Scenario 7: mounted source

    /// Field: "Node mounted source: Timeout, zero bytes". Boundary covered here
    /// WITHOUT a VM: the server script is executed from a file in a temporary
    /// directory (a foreign path outside the build tree, with a different working
    /// directory), instead of an inline `-e` script. This validates the
    /// script-from-external-path/cwd dimension only; VirtioFS/GhostFile mount
    /// semantics (I/O latency, page-cache behavior of the mounted volume) require a
    /// VM and are intentionally out of scope for this unit suite.
    func testNodeMountedSource_ServerScriptExecutedFromTemporaryDirectoryPath() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostbox-mounted-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let scriptURL = sourceDirectory.appendingPathComponent("server.js")
        try Self.nodeServerScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let (node, targetPort) = try launchNodeServer(mode: "http-close", scriptFile: scriptURL)
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connectClient(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array(Self.httpRequest.utf8)))
        XCTAssertEqual(readToEOF(fd: client), Array(Self.httpCloseResponse.utf8))
    }

    // MARK: - Scenario 8: server-first

    /// Field: "Node server-first: PASS after restart but failed before restart".
    /// The restart dimension: after `stop()`, a REPLACEMENT forwarder must be able
    /// to bind the same host port and serve the server-first banner. On the
    /// defective implementation the stopped forwarder's listener never closes
    /// (macOS shutdown-on-listener is a no-op), so the rebind fails with
    /// EADDRINUSE — the in-process analogue of the orphaned forwarder that had to
    /// be killed in the field before the scenario passed.
    func testNodeServerFirst_ReplacementForwarderOnSamePortAfterStopDeliversBanner() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "server-first")
        stopNodeAfterTest(node)
        let publishedPort = try reserveEphemeralPort()

        let original = try await PublishedPortForwarder(PublishedPort(
            hostAddress: "127.0.0.1", hostPort: publishedPort, containerPort: targetPort
        ))
        original.start(targetAddress: "127.0.0.1")
        defer { drainStaleListener(port: publishedPort) }

        // Banner works through the original forwarder ("before restart" it worked
        // until the stale process appeared).
        let before = try connectClient(port: publishedPort)
        XCTAssertEqual(readExactly(fd: before, count: 6), Array("READY\n".utf8), "original forwarder")
        Darwin.close(before)

        await original.stop()

        let replacement: PublishedPortForwarder
        do {
            replacement = try await PublishedPortForwarder(PublishedPort(
                hostAddress: "127.0.0.1", hostPort: publishedPort, containerPort: targetPort
            ))
        } catch {
            XCTFail(
                "replacement forwarder could not bind port \(publishedPort) after stop(): \(error). "
                    + "The stopped forwarder's listener is still bound (stale listener/orphan behavior)."
            )
            return
        }
        replacement.start(targetAddress: "127.0.0.1")
        stopAfterTest(replacement)

        let after = try connectClient(port: publishedPort)
        defer { Darwin.close(after) }
        XCTAssertEqual(readExactly(fd: after, count: 6), Array("READY\n".utf8), "after restart")
        XCTAssertTrue(writeBytes(fd: after, Array("request".utf8)))
        XCTAssertEqual(readToEOF(fd: after), Array("ACK".utf8), "after restart")
    }

    // MARK: - Scenario 9: echo

    /// Field: "Node echo: Timeout". Sustained interleaved request/response rounds
    /// over one long-lived connection: both relay pumps must stay alive across many
    /// alternating transfers, not just a single one-shot exchange.
    func testNodeEcho_InterleavedRoundTripsOnLongLivedConnection() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "echo")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connectClient(port: publishedPort)
        defer { Darwin.close(client) }
        for round in 0..<20 {
            let payload = (0..<1024).map { UInt8(truncatingIfNeeded: $0 &+ round) }
            XCTAssertTrue(writeBytes(fd: client, payload), "round \(round)")
            XCTAssertEqual(
                readExactly(fd: client, count: payload.count), payload,
                "round \(round): echo stopped mid-connection"
            )
        }
    }

    // MARK: - Scenario 10: half-close

    /// Field: "Node half-close: Timeout". After a relay whose client half-closed
    /// (SHUT_WR) completes its delayed post-EOF reply, the forwarder must still be
    /// healthy: a SECOND half-close exchange on a new connection must also succeed.
    /// Catches relay teardown after half-close poisoning the listener or relay
    /// bookkeeping.
    func testNodeHalfClose_ForwarderAcceptsNextConnectionAfterHalfClosedRelay() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "half-close")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        for attempt in 1...2 {
            let client = try connectClient(port: publishedPort)
            defer { Darwin.close(client) }
            XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)), "attempt \(attempt)")
            XCTAssertEqual(Darwin.shutdown(client, SHUT_WR), 0, "attempt \(attempt)")
            XCTAssertEqual(
                readToEOF(fd: client), Array("after-eof".utf8),
                "attempt \(attempt): post-half-close reply not forwarded"
            )
        }
    }

    // MARK: - Scenario 11: keep-alive connection pool

    /// Realistic container traffic: a client keeps a pool of idle keep-alive
    /// connections open (browser HTTP/1.1 pools, load balancers, websocket fans)
    /// while new connections arrive. Every relay in the former implementation
    /// parked TWO threads in blocking read() on DispatchQueue.global, whose worker
    /// pool is capped at 64 threads (a libdispatch constant, verified empirically
    /// on this host). Once 32 relays are alive the pool is exhausted: connection
    /// 33's pump work items are queued forever, so the client connects
    /// successfully (the accept loop lives on a private overcommit queue) and then
    /// reads zero bytes — the exact field signature "Timeout, zero bytes", this
    /// time under concurrency instead of lifecycle. The threshold is a hard
    /// deterministic cliff, not a probabilistic race.
    func testNodeEcho_KeepAliveConnectionPoolBeyondThirtyTwoStillForwarded() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "echo")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        var pool: [Int32] = []
        defer { pool.forEach { Darwin.close($0) } }

        for connection in 1...36 {
            let client = try connectClient(port: publishedPort)
            pool.append(client)
            let payload = Array("ping-\(connection)\n".utf8)
            XCTAssertTrue(writeBytes(fd: client, payload), "connection \(connection): write")
            guard let echoed = readExactly(fd: client, count: payload.count) else {
                XCTFail(
                    "connection \(connection) of 36 connected but received zero bytes while "
                        + "\(pool.count - 1) keep-alive connections were idle: with two blocking "
                        + "pump threads per relay the 64-thread global-queue pool is exhausted "
                        + "after 32 relays, so later relays never start pumping"
                )
                return
            }
            XCTAssertEqual(echoed, payload, "connection \(connection): wrong echo")
        }
    }

    // MARK: - Fixture

    private static let httpRequest = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
    private static let httpCloseResponse =
        "HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnode-http-ok"
    private static let httpKeepAliveResponse =
        "HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: keep-alive\r\n\r\nnode-http-ok"

    /// Unlike the fixture in PortForwarderTests.swift, this server keeps running and
    /// serves any number of connections, which is required to observe warm/second-
    /// connection and restart behavior. The mode is taken from the LAST argv entry
    /// so the identical script works both inline (`node -e script mode`) and from a
    /// file (`node /path/server.js mode`).
    private static let nodeServerScript = #"""
    const net = require("net");
    const mode = process.argv[process.argv.length - 1];
    const server = net.createServer({allowHalfOpen: true}, socket => {
      socket.on("error", () => {});
      if (mode === "server-first") {
        socket.write("READY\n");
        socket.once("data", () => socket.end("ACK"));
        socket.on("end", () => socket.end());
      } else if (mode === "raw-close") {
        socket.once("data", () => socket.end("raw-ok"));
      } else if (mode === "raw-keep-alive") {
        socket.once("data", () => socket.write("raw-ok"));
        socket.on("end", () => socket.end());
      } else if (mode === "echo") {
        socket.on("data", data => socket.write(data));
        socket.on("end", () => socket.end());
      } else if (mode === "half-close") {
        socket.on("data", () => {});
        socket.on("end", () => setTimeout(() => socket.end("after-eof"), 100));
      } else if (mode === "delayed") {
        socket.once("data", () => setTimeout(() => socket.end("delayed"), 400));
      } else if (mode === "large") {
        socket.once("data", () => socket.end(Buffer.alloc(1024 * 1024, 0x61)));
      } else if (mode === "http-keep-alive") {
        let pending = Buffer.alloc(0);
        socket.on("data", data => {
          pending = Buffer.concat([pending, data]);
          let index;
          while ((index = pending.indexOf("\r\n\r\n")) !== -1) {
            pending = pending.subarray(index + 4);
            socket.write("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: keep-alive\r\n\r\nnode-http-ok");
          }
        });
        socket.on("end", () => socket.end());
      } else if (mode === "http-close") {
        let pending = Buffer.alloc(0);
        socket.on("data", data => {
          pending = Buffer.concat([pending, data]);
          if (pending.indexOf("\r\n\r\n") !== -1) {
            socket.end("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnode-http-ok");
          }
        });
      }
    });
    server.listen(0, "127.0.0.1", () => console.log(server.address().port));
    """#

    private func launchNodeServer(mode: String, scriptFile: URL? = nil) throws -> (Process, UInt16) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        if let scriptFile {
            process.arguments = ["node", scriptFile.path, mode]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
        } else {
            process.arguments = ["node", "-e", Self.nodeServerScript, mode]
        }
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        var portLine = Data()
        while portLine.count < 16 {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            guard !byte.isEmpty else { break }
            if byte.first == UInt8(ascii: "\n") { break }
            portLine.append(byte)
        }
        guard let port = UInt16(String(decoding: portLine, as: UTF8.self)) else {
            process.waitUntilExit()
            throw XCTSkip("Node.js is unavailable or failed to start the test server")
        }
        return (process, port)
    }

    private func stopNodeAfterTest(_ process: Process) {
        addTeardownBlock { await Self.stopNodeServer(process) }
    }

    private static func stopNodeServer(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Forwarder helpers

    private func startForwarder(targetPort: UInt16) async throws -> (PublishedPortForwarder, UInt16) {
        let publishedPort = try reserveEphemeralPort()
        let forwarder = try await PublishedPortForwarder(PublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: publishedPort,
            containerPort: targetPort
        ))
        forwarder.start(targetAddress: "127.0.0.1")
        return (forwarder, publishedPort)
    }

    private func stopAfterTest(_ forwarder: PublishedPortForwarder) {
        addTeardownBlock { await forwarder.stop() }
    }

    /// On the defective implementation a stopped forwarder's accept loop stays
    /// blocked and its port stays bound until one more connection is sacrificed.
    /// Poke the port once so a defective run does not leak blocked threads and
    /// bound ports into later tests. On a correct implementation the connect is
    /// simply refused and this is a no-op.
    private func drainStaleListener(port: UInt16) {
        guard let fd = try? connectClient(port: port, recvTimeoutSeconds: 1) else { return }
        Darwin.close(fd)
    }

    private func reserveEphemeralPort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        defer { Darwin.close(fd) }
        var address = try loopbackAddress(port: 0)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw PortForwardError.socket(operation: "bind", code: errno) }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let lookup = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard lookup == 0 else { throw PortForwardError.socket(operation: "getsockname", code: errno) }
        return UInt16(bigEndian: bound.sin_port)
    }

    // MARK: - Socket helpers

    private func loopbackAddress(port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    private func connectClient(
        port: UInt16,
        recvTimeoutSeconds: Int = 3,
        configure: (Int32) -> Void = { _ in }
    ) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        do {
            var timeout = timeval(tv_sec: recvTimeoutSeconds, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            configure(fd)
            var address = try loopbackAddress(port: port)
            let result = withUnsafePointer(to: &address) { pointer in
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

    private func readExactly(fd: Int32, count: Int) -> [UInt8]? {
        var result = [UInt8]()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: min(32 * 1024, count))
        while result.count < count {
            let readCount = Darwin.read(fd, &buffer, min(buffer.count, count - result.count))
            if readCount > 0 {
                result.append(contentsOf: buffer[..<readCount])
            } else if readCount < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return result
    }

    private func readToEOF(fd: Int32) -> [UInt8] {
        var result = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let readCount = Darwin.read(fd, &buffer, buffer.count)
            if readCount > 0 {
                result.append(contentsOf: buffer[..<readCount])
            } else if readCount < 0, errno == EINTR {
                continue
            } else {
                return result
            }
        }
    }
}
