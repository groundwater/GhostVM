@testable import ghostbox
import Darwin
import Foundation
import XCTest

final class PortForwarderTests: XCTestCase {
    func testStopReleasesListenerForImmediateReuse() async throws {
        let (reservation, publishedPort) = try makeListener(port: 0)
        Darwin.close(reservation)
        let publication = PublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: publishedPort,
            containerPort: publishedPort
        )
        let forwarder = try await PublishedPortForwarder(publication)
        await forwarder.stop()

        let replacement = try await PublishedPortForwarder(publication)
        await replacement.stop()
    }

    func testRejectsSecondForwarderOnSamePort() async throws {
        let (reservation, publishedPort) = try makeListener(port: 0)
        Darwin.close(reservation)
        let publication = PublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: publishedPort,
            containerPort: publishedPort
        )
        let forwarder = try await PublishedPortForwarder(publication)
        stopAfterTest(forwarder)

        do {
            let duplicate = try await PublishedPortForwarder(publication)
            await duplicate.stop()
            XCTFail("expected a second listener on the same port to fail")
        } catch {}
    }

    func testForwardsTCPInBothDirections() async throws {
        let (targetListener, targetPort) = try makeListener(port: 0)
        defer { Darwin.close(targetListener) }

        let (reservation, publishedPort) = try makeListener(port: 0)
        Darwin.close(reservation)
        let forwarder = try await PublishedPortForwarder(PublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: publishedPort,
            containerPort: targetPort
        ))
        stopAfterTest(forwarder)
        forwarder.start(targetAddress: "127.0.0.1")

        let served = expectation(description: "target served relayed request")
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = Darwin.accept(targetListener, nil, nil)
            guard connection >= 0 else { served.fulfill(); return }
            defer { Darwin.close(connection) }
            var request = [UInt8](repeating: 0, count: 4)
            if Darwin.read(connection, &request, request.count) == 4,
               Data(request) == Data("ping".utf8) {
                _ = writeBytes(fd: connection, Array("pong".utf8))
            }
            served.fulfill()
        }

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("ping".utf8)))
        var response = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(Darwin.read(client, &response, response.count), 4)
        XCTAssertEqual(Data(response), Data("pong".utf8))
        await fulfillment(of: [served], timeout: 2)
    }

    func testPropagatesClientHalfCloseWithoutDroppingResponse() async throws {
        let (targetListener, targetPort) = try makeListener(port: 0)
        defer { Darwin.close(targetListener) }

        let (reservation, publishedPort) = try makeListener(port: 0)
        Darwin.close(reservation)
        let forwarder = try await PublishedPortForwarder(PublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: publishedPort,
            containerPort: targetPort
        ))
        stopAfterTest(forwarder)
        forwarder.start(targetAddress: "127.0.0.1")

        let served = expectation(description: "target observed EOF and replied")
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = Darwin.accept(targetListener, nil, nil)
            guard connection >= 0 else { served.fulfill(); return }
            defer { Darwin.close(connection) }
            var request = [UInt8](repeating: 0, count: 4)
            var trailing = UInt8(0)
            if Darwin.read(connection, &request, request.count) == 4,
               Data(request) == Data("ping".utf8),
               Darwin.read(connection, &trailing, 1) == 0 {
                _ = writeBytes(fd: connection, Array("pong".utf8))
            }
            served.fulfill()
        }

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("ping".utf8)))
        XCTAssertEqual(Darwin.shutdown(client, SHUT_WR), 0)
        var response = [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(Darwin.read(client, &response, response.count), 4)
        XCTAssertEqual(Data(response), Data("pong".utf8))
        await fulfillment(of: [served], timeout: 2)
    }

    func testStopClosesActiveRelay() async throws {
        let (targetListener, targetPort) = try makeListener(port: 0)
        defer { Darwin.close(targetListener) }

        let (reservation, publishedPort) = try makeListener(port: 0)
        Darwin.close(reservation)
        let forwarder = try await PublishedPortForwarder(PublishedPort(
            hostAddress: "127.0.0.1",
            hostPort: publishedPort,
            containerPort: targetPort
        ))
        forwarder.start(targetAddress: "127.0.0.1")

        let accepted = expectation(description: "target accepted relay")
        let closed = expectation(description: "target observed relay shutdown")
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = Darwin.accept(targetListener, nil, nil)
            guard connection >= 0 else {
                accepted.fulfill()
                closed.fulfill()
                return
            }
            accepted.fulfill()
            var byte = UInt8(0)
            _ = Darwin.read(connection, &byte, 1)
            Darwin.close(connection)
            closed.fulfill()
        }

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        await fulfillment(of: [accepted], timeout: 2)
        await forwarder.stop()
        var byte = UInt8(0)
        XCTAssertEqual(Darwin.read(client, &byte, 1), 0)
        await fulfillment(of: [closed], timeout: 2)
    }

    func testTargetResetClosesIdleClient() async throws {
        let (targetListener, targetPort) = try makeListener(port: 0)
        defer { Darwin.close(targetListener) }
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let targetReset = expectation(description: "target reset established relay")
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = Darwin.accept(targetListener, nil, nil)
            guard connection >= 0 else { targetReset.fulfill(); return }
            var reset = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(
                connection,
                SOL_SOCKET,
                SO_LINGER,
                &reset,
                socklen_t(MemoryLayout.size(ofValue: reset))
            )
            Darwin.close(connection)
            targetReset.fulfill()
        }

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        await fulfillment(of: [targetReset], timeout: 2)

        var byte = UInt8(0)
        let count = Darwin.read(client, &byte, 1)
        XCTAssertTrue(count == 0 || (count < 0 && errno == ECONNRESET), "idle client was not closed after target reset")
    }

    func testForwardsNodeRawCloseResponse() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "raw-close")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))
        XCTAssertEqual(readToEOF(fd: client), Array("raw-ok".utf8))
    }

    func testForwardsNodeRawKeepAliveResponseWithoutWaitingForEOF() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "raw-keep-alive")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))
        XCTAssertEqual(Self.readExactly(fd: client, count: 6), Array("raw-ok".utf8))
    }

    func testForwardsNodeHTTPResponsesForCloseAndKeepAlive() async throws {
        for mode in ["http-close", "http-keep-alive"] {
            let (node, targetPort) = try launchNodeServer(mode: mode)
            let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
            let client = try connect(port: publishedPort)
            let request = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: \(mode == "http-close" ? "close" : "keep-alive")\r\n\r\n"

            XCTAssertTrue(writeBytes(fd: client, Array(request.utf8)), mode)
            let response = readUntil(fd: client, contains: Array("node-http".utf8))
            XCTAssertNotNil(response, mode)
            if let response {
                XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"), mode)
            }

            Darwin.close(client)
            await forwarder.stop()
            await Self.stopNodeServer(node)
        }
    }

    func testForwardsDelayedNodeResponse() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "delayed")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))
        XCTAssertEqual(Self.readExactly(fd: client, count: 7), Array("delayed".utf8))
    }

    func testForwardsOneMiBNodeResponse() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "large")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))
        let response = Self.readExactly(fd: client, count: 1024 * 1024)
        XCTAssertEqual(response?.count, 1024 * 1024)
        XCTAssertTrue(response?.allSatisfy { $0 == 0x61 } == true)
    }

    func testForwardsNodeServerFirstProtocol() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "server-first")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertEqual(Self.readExactly(fd: client, count: 6), Array("READY\n".utf8))
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))
        XCTAssertEqual(Self.readExactly(fd: client, count: 3), Array("ACK".utf8))
    }

    func testForwardsNodeEchoWhileConnectionRemainsOpen() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "echo")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        let payload = (0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0) }
        XCTAssertTrue(writeBytes(fd: client, payload))
        XCTAssertEqual(Self.readExactly(fd: client, count: payload.count), payload)
    }

    func testForwardsConcurrentBidirectionalTraffic() async throws {
        let (targetListener, targetPort) = try makeListener(port: 0)
        defer { Darwin.close(targetListener) }
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)
        let clientPayload = (0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) }
        let targetPayload = (0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) }

        let targetFinished = expectation(description: "target completed simultaneous transfer")
        DispatchQueue.global(qos: .userInitiated).async {
            let connection = Darwin.accept(targetListener, nil, nil)
            guard connection >= 0 else { targetFinished.fulfill(); return }
            defer { Darwin.close(connection) }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = writeBytes(fd: connection, targetPayload)
                _ = Darwin.shutdown(connection, SHUT_WR)
            }
            let received = Self.readExactly(fd: connection, count: clientPayload.count)
            XCTAssertEqual(received, clientPayload)
            targetFinished.fulfill()
        }

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        let clientWrite = expectation(description: "client completed simultaneous write")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertTrue(writeBytes(fd: client, clientPayload))
            _ = Darwin.shutdown(client, SHUT_WR)
            clientWrite.fulfill()
        }
        XCTAssertEqual(Self.readExactly(fd: client, count: targetPayload.count), targetPayload)
        await fulfillment(of: [clientWrite, targetFinished], timeout: 5)
    }

    func testForwardsNodeResponseAfterClientHalfClose() async throws {
        let (node, targetPort) = try launchNodeServer(mode: "half-close")
        stopNodeAfterTest(node)
        let (forwarder, publishedPort) = try await startForwarder(targetPort: targetPort)
        stopAfterTest(forwarder)

        let client = try connect(port: publishedPort)
        defer { Darwin.close(client) }
        XCTAssertTrue(writeBytes(fd: client, Array("request".utf8)))
        XCTAssertEqual(Darwin.shutdown(client, SHUT_WR), 0)
        XCTAssertEqual(readToEOF(fd: client), Array("after-eof".utf8))
    }

    private func startForwarder(targetPort: UInt16) async throws -> (PublishedPortForwarder, UInt16) {
        let (reservation, publishedPort) = try makeListener(port: 0)
        Darwin.close(reservation)
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

    private func launchNodeServer(mode: String) throws -> (Process, UInt16) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", Self.nodeServerScript, mode]
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

    private static func readExactly(fd: Int32, count: Int) -> [UInt8]? {
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

    private func readUntil(fd: Int32, contains expected: [UInt8]) -> [UInt8]? {
        var result = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < 1024 * 1024 {
            let readCount = Darwin.read(fd, &buffer, buffer.count)
            if readCount > 0 {
                result.append(contentsOf: buffer[..<readCount])
                if Data(result).range(of: Data(expected)) != nil { return result }
            } else if readCount < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return nil
    }

    private static let nodeServerScript = #"""
    const net = require("net");
    const mode = process.argv[1];
    const server = net.createServer({allowHalfOpen: true}, socket => {
      if (mode === "server-first") {
        socket.write("READY\n");
        socket.once("data", () => socket.end("ACK"));
      } else if (mode === "raw-close") {
        socket.once("data", () => socket.end("raw-ok"));
      } else if (mode === "raw-keep-alive") {
        socket.once("data", () => socket.write("raw-ok"));
      } else if (mode === "echo") {
        socket.on("data", data => socket.write(data));
      } else if (mode === "half-close") {
        socket.on("data", () => {});
        socket.on("end", () => setTimeout(() => socket.end("after-eof"), 150));
      } else if (mode === "delayed") {
        socket.once("data", () => setTimeout(() => socket.end("delayed"), 150));
      } else if (mode === "large") {
        socket.once("data", () => socket.end(Buffer.alloc(1024 * 1024, 0x61)));
      } else {
        let requestChunks = [];
        socket.on("data", data => {
          requestChunks.push(data);
          if (!Buffer.concat(requestChunks).includes("\r\n\r\n")) return;
          const keepAlive = mode === "http-keep-alive";
          const response = "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: " +
            (keepAlive ? "keep-alive" : "close") + "\r\n\r\nnode-http";
          if (keepAlive) socket.write(response); else socket.end(response);
        });
      }
      socket.on("close", () => server.close());
    });
    server.listen(0, "127.0.0.1", () => console.log(server.address().port));
    """#

    private func makeListener(port: UInt16) throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        do {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0, Darwin.listen(fd, 4) == 0 else {
                throw PortForwardError.socket(operation: "bind/listen", code: errno)
            }
            var bound = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let lookup = withUnsafeMutablePointer(to: &bound) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &length)
                }
            }
            guard lookup == 0 else { throw PortForwardError.socket(operation: "getsockname", code: errno) }
            return (fd, UInt16(bigEndian: bound.sin_port))
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func connect(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortForwardError.socket(operation: "socket", code: errno) }
        do {
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
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
            guard result == 0 else { throw PortForwardError.socket(operation: "connect", code: errno) }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
}
