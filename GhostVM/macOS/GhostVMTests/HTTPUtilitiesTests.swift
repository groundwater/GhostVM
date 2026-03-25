import XCTest
@testable import GhostVMKit

/// Comprehensive tests for HTTPUtilities
///
/// These tests ensure:
/// - Query parameter parsing is correct (including URL encoding)
/// - HTTP status code mapping is accurate
/// - Request/response building is binary-safe
/// - No data corruption with NULL bytes or invalid UTF-8
final class HTTPUtilitiesTests: XCTestCase {

    // MARK: - Query Parsing Tests

    func testQueryParsing() {
        let path = "/api/v1/test?foo=bar"
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "foo"), "bar")
    }

    func testQueryParsingWithSpaces() {
        let path = "/api/v1/test?message=hello%20world"
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "message"), "hello world")
    }

    func testQueryParsingWithMultipleParams() {
        let path = "/api/v1/test?foo=bar&baz=qux&name=value"
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "foo"), "bar")
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "baz"), "qux")
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "name"), "value")
    }

    func testQueryParsingWithEncoding() {
        let path = "/api/v1/test?name=John%20Doe&email=test%40example.com"
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "name"), "John Doe")
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "email"), "test@example.com")
    }

    func testQueryParsingNoQueryString() {
        let path = "/api/v1/test"
        XCTAssertNil(HTTPUtilities.parseQuery(path, key: "foo"))
    }

    func testQueryParsingMissingKey() {
        let path = "/api/v1/test?foo=bar&baz=qux"
        XCTAssertNil(HTTPUtilities.parseQuery(path, key: "missing"))
    }

    func testBoolQueryParsing() {
        let path1 = "/test?flag=1"
        XCTAssertEqual(HTTPUtilities.parseBoolQuery(path1, key: "flag"), true)

        let path2 = "/test?flag=true"
        XCTAssertEqual(HTTPUtilities.parseBoolQuery(path2, key: "flag"), true)

        let path3 = "/test?flag=yes"
        XCTAssertEqual(HTTPUtilities.parseBoolQuery(path3, key: "flag"), true)

        let path4 = "/test?flag=0"
        XCTAssertEqual(HTTPUtilities.parseBoolQuery(path4, key: "flag"), false)

        let path5 = "/test?flag=false"
        XCTAssertEqual(HTTPUtilities.parseBoolQuery(path5, key: "flag"), false)

        let path6 = "/test?flag=no"
        XCTAssertEqual(HTTPUtilities.parseBoolQuery(path6, key: "flag"), false)

        let path7 = "/test?flag=invalid"
        XCTAssertNil(HTTPUtilities.parseBoolQuery(path7, key: "flag"))
    }

    // MARK: - Status Code Tests

    func testHTTPStatusMapping() {
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 200), .ok)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 201), .created)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 204), .noContent)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 400), .badRequest)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 401), .unauthorized)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 403), .forbidden)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 404), .notFound)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 405), .methodNotAllowed)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 408), .requestTimeout)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 500), .internalServerError)
    }

    func testHTTPStatusReasonPhrases() {
        XCTAssertEqual(HTTPUtilities.HTTPStatus.ok.reasonPhrase, "OK")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.created.reasonPhrase, "Created")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.noContent.reasonPhrase, "No Content")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.badRequest.reasonPhrase, "Bad Request")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.unauthorized.reasonPhrase, "Unauthorized")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.forbidden.reasonPhrase, "Forbidden")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.notFound.reasonPhrase, "Not Found")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.methodNotAllowed.reasonPhrase, "Method Not Allowed")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.requestTimeout.reasonPhrase, "Request Timeout")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.internalServerError.reasonPhrase, "Internal Server Error")
    }

    func testHTTPStatusUnknownCode() {
        // Unknown codes should fall back to internal server error
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 999), .internalServerError)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 418), .internalServerError) // I'm a teapot
    }

    // MARK: - Request Building Tests

    func testBuildBasicRequest() {
        let request = HTTPUtilities.buildRequest(method: "GET", path: "/test")
        let requestStr = String(data: request, encoding: .utf8)!

        XCTAssertTrue(requestStr.contains("GET /test HTTP/1.1"))
        XCTAssertTrue(requestStr.contains("Host: localhost"))
        XCTAssertTrue(requestStr.contains("Connection: close"))
        XCTAssertTrue(requestStr.hasSuffix("\r\n\r\n"))
    }

    func testBuildRequestWithHeaders() {
        let headers = [
            "Content-Type": "application/json",
            "Authorization": "Bearer token123"
        ]
        let request = HTTPUtilities.buildRequest(
            method: "POST",
            path: "/api/v1/test",
            headers: headers
        )
        let requestStr = String(data: request, encoding: .utf8)!

        XCTAssertTrue(requestStr.contains("POST /api/v1/test HTTP/1.1"))
        XCTAssertTrue(requestStr.contains("Content-Type: application/json"))
        XCTAssertTrue(requestStr.contains("Authorization: Bearer token123"))
    }

    func testBuildRequestWithBody() {
        let body = Data("{\"test\":\"value\"}".utf8)
        let request = HTTPUtilities.buildRequest(
            method: "POST",
            path: "/test",
            body: body
        )
        let requestStr = String(data: request, encoding: .utf8)!

        XCTAssertTrue(requestStr.contains("Content-Length: \(body.count)"))

        // Verify body is appended correctly
        let headerEnd = request.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))! // \r\n\r\n
        let bodyStart = headerEnd.upperBound
        let extractedBody = request[bodyStart...]
        XCTAssertEqual(extractedBody, body)
    }

    func testBuildRequestBinarySafe() {
        // Test with binary data containing NULL bytes and invalid UTF-8
        let binaryData = Data([0xFF, 0x00, 0xFE, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF])
        let request = HTTPUtilities.buildRequest(
            method: "POST",
            path: "/test",
            body: binaryData
        )

        // Find the body in the request
        let headerEnd = request.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))! // \r\n\r\n
        let bodyStart = headerEnd.upperBound
        let extractedBody = request[bodyStart...]

        // Verify binary data is preserved exactly
        XCTAssertEqual(extractedBody, binaryData)
    }

    // MARK: - Response Building Tests

    func testBuildJSONResponse() {
        let json = Data("{\"status\":\"ok\"}".utf8)
        let response = HTTPUtilities.buildJSONResponse(json)
        let responseStr = String(data: response, encoding: .utf8)!

        XCTAssertTrue(responseStr.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(responseStr.contains("Content-Type: application/json"))
        XCTAssertTrue(responseStr.contains("Content-Length: \(json.count)"))

        // Verify body
        let headerEnd = response.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))!
        let bodyStart = headerEnd.upperBound
        let extractedBody = response[bodyStart...]
        XCTAssertEqual(extractedBody, json)
    }

    func testBuildErrorResponse() {
        let response = HTTPUtilities.buildErrorResponse(
            status: .notFound,
            message: "Resource not found"
        )
        let responseStr = String(data: response, encoding: .utf8)!

        XCTAssertTrue(responseStr.contains("HTTP/1.1 404 Not Found"))
        XCTAssertTrue(responseStr.contains("Content-Type: application/json"))

        // Verify error message in body
        let headerEnd = response.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))!
        let bodyStart = headerEnd.upperBound
        let body = response[bodyStart...]
        let json = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["error"] as? String, "Resource not found")
    }

    func testBuildResponseBinarySafe() {
        // Test response with binary body
        let binaryBody = Data([0xFF, 0x00, 0xFE, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF])
        let response = HTTPUtilities.buildResponse(
            status: .ok,
            contentType: "application/octet-stream",
            body: binaryBody
        )

        // Verify status line
        let responseStr = String(data: response.prefix(upTo: response.firstIndex(of: 0x0d)!), encoding: .utf8)!
        XCTAssertEqual(responseStr, "HTTP/1.1 200 OK")

        // Verify binary body is preserved
        let headerEnd = response.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))!
        let bodyStart = headerEnd.upperBound
        let extractedBody = response[bodyStart...]
        XCTAssertEqual(extractedBody, binaryBody)
    }

    // MARK: - Binary Safety Tests (CRITICAL)

    func testBinaryBodyWithNullBytes() {
        let binaryData = Data([0xFF, 0x00, 0xFE, 0x00, 0x01])
        let request = HTTPUtilities.buildRequest(
            method: "POST",
            path: "/test",
            body: binaryData
        )

        // Verify binary data is preserved (especially NULL bytes at positions 1 and 3)
        let headerEnd = request.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))!
        let bodyStart = headerEnd.upperBound
        let extractedBody = request[bodyStart...]
        XCTAssertEqual(extractedBody, binaryData)

        // Verify specific NULL bytes
        XCTAssertEqual(extractedBody[extractedBody.startIndex + 1], 0x00)
        XCTAssertEqual(extractedBody[extractedBody.startIndex + 3], 0x00)
    }

    func testBinaryBodyWithInvalidUTF8() {
        // Create data with invalid UTF-8 sequences
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA])
        let request = HTTPUtilities.buildRequest(
            method: "POST",
            path: "/test",
            body: invalidUTF8
        )

        // Must not crash or corrupt data
        let headerEnd = request.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))!
        let bodyStart = headerEnd.upperBound
        let extractedBody = request[bodyStart...]
        XCTAssertEqual(extractedBody, invalidUTF8)
    }

    func testLargeBody() {
        // Test with a larger binary body (simulate file transfer)
        let largeData = Data(repeating: 0xAB, count: 1024 * 1024) // 1 MB
        let request = HTTPUtilities.buildRequest(
            method: "POST",
            path: "/upload",
            headers: ["Content-Type": "application/octet-stream"],
            body: largeData
        )

        // Verify Content-Length header
        let headerEnd = request.range(of: Data([0x0d, 0x0a, 0x0d, 0x0a]))!
        let headerData = request[request.startIndex..<headerEnd.lowerBound]
        let requestStr = String(data: headerData, encoding: .utf8)!
        XCTAssertTrue(requestStr.contains("Content-Length: \(largeData.count)"))

        // Verify body size
        let bodyStart = headerEnd.upperBound
        let extractedBody = request[bodyStart...]
        XCTAssertEqual(extractedBody.count, largeData.count)
    }

    func testMultipleHeadersPreservation() {
        let headers = [
            "X-Custom-1": "value1",
            "X-Custom-2": "value2",
            "X-Custom-3": "value3",
            "Content-Type": "application/json",
            "Authorization": "Bearer token"
        ]
        let request = HTTPUtilities.buildRequest(
            method: "POST",
            path: "/test",
            headers: headers
        )
        let requestStr = String(data: request, encoding: .utf8)!

        for (key, value) in headers {
            XCTAssertTrue(requestStr.contains("\(key): \(value)"), "Header \(key): \(value) not found")
        }
    }

    func testResponseWithDifferentStatusCodes() {
        let body = Data("test".utf8)

        let okResponse = HTTPUtilities.buildResponse(status: .ok, contentType: "text/plain", body: body)
        XCTAssertTrue(String(data: okResponse, encoding: .utf8)!.contains("200 OK"))

        let createdResponse = HTTPUtilities.buildResponse(status: .created, contentType: "text/plain", body: body)
        XCTAssertTrue(String(data: createdResponse, encoding: .utf8)!.contains("201 Created"))

        let notFoundResponse = HTTPUtilities.buildResponse(status: .notFound, contentType: "text/plain", body: body)
        XCTAssertTrue(String(data: notFoundResponse, encoding: .utf8)!.contains("404 Not Found"))

        let serverErrorResponse = HTTPUtilities.buildResponse(status: .internalServerError, contentType: "text/plain", body: body)
        XCTAssertTrue(String(data: serverErrorResponse, encoding: .utf8)!.contains("500 Internal Server Error"))
    }
}
