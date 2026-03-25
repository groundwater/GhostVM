import XCTest
@testable import GhostVMKit

final class HTTPResponseParserTests: XCTestCase {
    func testParse200WithJSONBody() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"content\":\"hello\"}"
        let data = Data(raw.utf8)
        let (statusCode, body) = try HTTPResponseParser.parse(data)

        XCTAssertEqual(statusCode, 200)
        XCTAssertNotNil(body)

        let json = try JSONSerialization.jsonObject(with: body!) as? [String: Any]
        XCTAssertEqual(json?["content"] as? String, "hello")
    }

    func testParse204NoBody() throws {
        let raw = "HTTP/1.1 204 No Content\r\n\r\n"
        let data = Data(raw.utf8)
        let (statusCode, body) = try HTTPResponseParser.parse(data)

        XCTAssertEqual(statusCode, 204)
        // Body may be nil or empty data
        if let body = body {
            XCTAssertTrue(body.isEmpty)
        }
    }

    func testParse404() throws {
        let raw = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\n\r\nNot Found"
        let data = Data(raw.utf8)
        let (statusCode, body) = try HTTPResponseParser.parse(data)

        XCTAssertEqual(statusCode, 404)
        XCTAssertNotNil(body)
    }

    func testMalformedDataThrows() {
        let data = Data([0xFF, 0xFE, 0xFD]) // Not valid UTF-8
        XCTAssertThrowsError(try HTTPResponseParser.parse(data))
    }

    func testBinaryBodyPreservesBytes() throws {
        var rawData = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        let binaryBody = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        rawData.append(binaryBody)

        let (statusCode, body) = try HTTPResponseParser.parseBinary(rawData)

        XCTAssertEqual(statusCode, 200)
        XCTAssertEqual(body, binaryBody)
    }

    func testResponseWithMultipleHeaders() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Custom: value\r\nConnection: close\r\n\r\n{\"files\":[]}"
        let data = Data(raw.utf8)
        let (statusCode, body) = try HTTPResponseParser.parse(data)

        XCTAssertEqual(statusCode, 200)
        XCTAssertNotNil(body)
    }

    func testParseBinaryHeaderOnly() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: 0"
        let data = Data(raw.utf8)
        let (statusCode, body) = try HTTPResponseParser.parseBinary(data)

        XCTAssertEqual(statusCode, 200)
        XCTAssertNil(body)
    }

    func testEmptyBodyAfterSeparator() throws {
        let raw = "HTTP/1.1 200 OK\r\n\r\n"
        let data = Data(raw.utf8)
        let (statusCode, body) = try HTTPResponseParser.parse(data)

        XCTAssertEqual(statusCode, 200)
        // Empty body string converts to empty data
        if let body = body {
            XCTAssertTrue(body.isEmpty)
        }
    }
}
