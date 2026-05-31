import XCTest
@testable import GhostVMKit

final class HTTPUtilitiesTests: XCTestCase {
    func testQueryParsing() {
        let path = "/api/v1/test?foo=bar&message=hello%20world"
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "foo"), "bar")
        XCTAssertEqual(HTTPUtilities.parseQuery(path, key: "message"), "hello world")
        XCTAssertEqual(HTTPUtilities.parseQuery("/api/v1/test?token=a=b%3D", key: "token"), "a=b=")
        XCTAssertNil(HTTPUtilities.parseQuery("/api/v1/test", key: "foo"))
    }

    func testBoolQueryParsing() {
        XCTAssertEqual(HTTPUtilities.parseBoolQuery("/test?flag=1", key: "flag"), true)
        XCTAssertEqual(HTTPUtilities.parseBoolQuery("/test?flag=false", key: "flag"), false)
        XCTAssertNil(HTTPUtilities.parseBoolQuery("/test?flag=invalid", key: "flag"))
    }

    func testHTTPStatusMapping() {
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 200), .ok)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 404), .notFound)
        XCTAssertEqual(HTTPUtilities.HTTPStatus.from(code: 999), .internalServerError)
    }

    func testHTTPStatusReasonPhrases() {
        XCTAssertEqual(HTTPUtilities.HTTPStatus.ok.reasonPhrase, "OK")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.methodNotAllowed.reasonPhrase, "Method Not Allowed")
        XCTAssertEqual(HTTPUtilities.HTTPStatus.internalServerError.reasonPhrase, "Internal Server Error")
    }
}
