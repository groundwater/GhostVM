import XCTest
import Darwin
@testable import GhostHTTP

final class GhostHTTPTests: XCTestCase {
    func testReadRequestWithContentLengthBody() throws {
        let pair = try makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }

        let body = Data("hello world".utf8)
        try HTTPCodec.writeRequest(fd: pair.0, method: "POST", path: "/clipboard", headers: HTTPHeaders(["Content-Type": "text/plain"]), body: body)
        _ = Darwin.shutdown(pair.0, SHUT_WR)

        let (request, prelude) = try HTTPCodec.readRequest(fd: pair.1)
        XCTAssertEqual(request.method, .POST)
        XCTAssertEqual(request.path, "/clipboard")
        XCTAssertEqual(request.header("Content-Type"), "text/plain")

        let reader = HTTPBodyReader(fd: pair.1, framing: HTTPCodec.requestFraming(for: request), prelude: prelude)
        XCTAssertEqual(try reader.readAll(), body)
    }

    func testReadChunkedRequestBody() throws {
        let pair = try makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }

        let request = "POST /upload HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Transfer-Encoding: chunked\r\n"
            + "\r\n"
            + "5\r\n"
            + "hello\r\n"
            + "6\r\n"
            + " world\r\n"
            + "0\r\n"
            + "\r\n"
        try HTTPCodec.writeAll(fd: pair.0, data: Data(request.utf8))
        _ = Darwin.shutdown(pair.0, SHUT_WR)

        let (head, prelude) = try HTTPCodec.readRequest(fd: pair.1)
        XCTAssertEqual(head.path, "/upload")
        XCTAssertEqual(HTTPCodec.requestFraming(for: head), .chunked)

        let reader = HTTPBodyReader(fd: pair.1, framing: .chunked, prelude: prelude)
        XCTAssertEqual(try reader.readAll(), Data("hello world".utf8))
    }

    func testWriteStreamingResponse() throws {
        let pair = try makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }

        let response = HTTPResponse(
            status: .ok,
            headers: HTTPHeaders(["Content-Type": "application/octet-stream"]),
            body: .stream(contentLength: 11) { writer in
                try writer.write(Data("hello ".utf8))
                try writer.write(Data("world".utf8))
            }
        )

        try HTTPCodec.writeResponse(response, fd: pair.0)
        _ = Darwin.shutdown(pair.0, SHUT_WR)

        let buffered = try HTTPClient.readBufferedResponse(fd: pair.1)
        XCTAssertEqual(buffered.head.status, .ok)
        XCTAssertEqual(buffered.head.header("Content-Type"), "application/octet-stream")
        XCTAssertEqual(buffered.body, Data("hello world".utf8))
    }

    func testBufferedClientRequestResponseRoundTrip() throws {
        let pair = try makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }

        let responseData = Data(#"{"ok":true}"#.utf8)
        DispatchQueue.global().async {
            do {
                let (request, prelude) = try HTTPCodec.readRequest(fd: pair.1)
                let reader = HTTPBodyReader(fd: pair.1, framing: HTTPCodec.requestFraming(for: request), prelude: prelude)
                let body = try reader.readAll()
                XCTAssertEqual(request.method, .POST)
                XCTAssertEqual(request.path, "/api/v1/test")
                XCTAssertEqual(body, Data("payload".utf8))
                try HTTPCodec.writeResponse(.json(responseData), fd: pair.1)
                _ = Darwin.shutdown(pair.1, SHUT_WR)
            } catch {
                XCTFail("server failed: \(error)")
            }
        }

        let response = try HTTPClient.performRequest(
            fd: pair.0,
            method: "POST",
            path: "/api/v1/test",
            headers: HTTPHeaders(["Content-Type": "text/plain"]),
            body: Data("payload".utf8)
        )

        XCTAssertEqual(response.head.status, .ok)
        XCTAssertEqual(response.head.header("Content-Type"), "application/json")
        XCTAssertEqual(response.body, responseData)
    }

    func testResponseHeadWithPreludeSupportsStreamingRead() throws {
        let pair = try makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }

        let response = "HTTP/1.1 200 OK\r\nContent-Length: 12\r\nX-Test: yes\r\n\r\nhello world!"
        try HTTPCodec.writeAll(fd: pair.0, data: Data(response.utf8))
        _ = Darwin.shutdown(pair.0, SHUT_WR)

        let (head, reader) = try HTTPClient.readResponseHead(fd: pair.1)
        XCTAssertEqual(head.status, .ok)
        XCTAssertEqual(head.header("X-Test"), "yes")
        XCTAssertEqual(try reader.readAll(), Data("hello world!".utf8))
    }

    func testUpgradeRequestReturnsResponseHeadAndPrelude() throws {
        let pair = try makeSocketPair()
        defer {
            Darwin.close(pair.0)
            Darwin.close(pair.1)
        }

        DispatchQueue.global().async {
            do {
                let (request, _) = try HTTPCodec.readRequest(fd: pair.1)
                XCTAssertEqual(request.path, "/shell")
                XCTAssertEqual(request.header("Upgrade"), "websocket")

                let response = "HTTP/1.1 101 Switching Protocols\r\n"
                    + "Upgrade: websocket\r\n"
                    + "Connection: Upgrade\r\n"
                    + "\r\n"
                    + "post-upgrade-bytes"
                try HTTPCodec.writeAll(fd: pair.1, data: Data(response.utf8))
                _ = Darwin.shutdown(pair.1, SHUT_WR)
            } catch {
                XCTFail("server failed: \(error)")
            }
        }

        let upgraded = try HTTPClient.performUpgradeRequest(
            fd: pair.0,
            path: "/shell",
            headers: HTTPHeaders([
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": "test-key"
            ])
        )

        XCTAssertEqual(upgraded.responseHead.status, .switchingProtocols)
        XCTAssertEqual(upgraded.responseHead.header("Upgrade"), "websocket")
        XCTAssertEqual(upgraded.prelude, Data("post-upgrade-bytes".utf8))
    }

    func testNilBodyRequestsEmitContentLengthZero() throws {
        let request = HTTPCodec.requestData(method: "GET", path: "/health")
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testUpgradeRequestsDoNotInjectContentLengthZero() throws {
        let request = HTTPCodec.requestData(
            method: "GET",
            path: "/shell",
            headers: HTTPHeaders([
                "Connection": "Upgrade",
                "Upgrade": "websocket",
            ])
        )
        let text = String(decoding: request, as: UTF8.self)
        XCTAssertFalse(text.contains("Content-Length: 0\r\n"))
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw HTTPError.readFailed(errno: errno)
        }
        return (fds[0], fds[1])
    }
}
