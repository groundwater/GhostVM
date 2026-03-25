import XCTest
@testable import GhostVMKit

final class URLUtilitiesTests: XCTestCase {

    // MARK: - filterWebURLs

    func testFilterAllowsHTTP() {
        let result = URLUtilities.filterWebURLs(["http://example.com"])
        XCTAssertEqual(result, ["http://example.com"])
    }

    func testFilterAllowsHTTPS() {
        let result = URLUtilities.filterWebURLs(["https://example.com"])
        XCTAssertEqual(result, ["https://example.com"])
    }

    func testFilterCaseInsensitiveScheme() {
        let urls = ["HTTP://example.com", "HTTPS://example.com", "Http://example.com"]
        let result = URLUtilities.filterWebURLs(urls)
        XCTAssertEqual(result, urls)
    }

    func testFilterRejectsFTP() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["ftp://example.com"]), [])
    }

    func testFilterRejectsFile() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["file:///etc/passwd"]), [])
    }

    func testFilterRejectsJavascript() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["javascript:alert(1)"]), [])
    }

    func testFilterRejectsData() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["data:text/html,<h1>hi</h1>"]), [])
    }

    func testFilterRejectsSSH() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["ssh://host"]), [])
    }

    func testFilterRejectsMailto() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["mailto:user@example.com"]), [])
    }

    func testFilterRejectsTel() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["tel:+1234567890"]), [])
    }

    func testFilterRejectsNoScheme() {
        XCTAssertEqual(URLUtilities.filterWebURLs(["example.com"]), [])
    }

    func testFilterRejectsEmptyString() {
        XCTAssertEqual(URLUtilities.filterWebURLs([""]), [])
    }

    func testFilterEmptyArray() {
        XCTAssertEqual(URLUtilities.filterWebURLs([]), [])
    }

    func testFilterMixedValidAndInvalid() {
        let urls = [
            "https://good.com",
            "ftp://bad.com",
            "http://also-good.com",
            "javascript:void(0)",
            "",
        ]
        let result = URLUtilities.filterWebURLs(urls)
        XCTAssertEqual(result, ["https://good.com", "http://also-good.com"])
    }

    func testFilterPreservesFullURL() {
        let url = "https://example.com/path/to/page?query=value&other=123#fragment"
        let result = URLUtilities.filterWebURLs([url])
        XCTAssertEqual(result, [url])
    }

    // MARK: - truncateMiddle

    func testTruncateShorterThanMax() {
        XCTAssertEqual(URLUtilities.truncateMiddle("hello", maxLength: 10), "hello")
    }

    func testTruncateExactlyMax() {
        XCTAssertEqual(URLUtilities.truncateMiddle("hello", maxLength: 5), "hello")
    }

    func testTruncateOneOverMax() {
        // "abcdef" (6 chars), maxLength 5 → half = 2, "ab…ef"
        let result = URLUtilities.truncateMiddle("abcdef", maxLength: 5)
        XCTAssertEqual(result, "ab\u{2026}ef")
        XCTAssertEqual(result.count, 5)
    }

    func testTruncateMuchLonger() {
        let long = "https://example.com/very/long/path/to/something/important"
        let result = URLUtilities.truncateMiddle(long, maxLength: 20)
        XCTAssertTrue(result.contains("\u{2026}"))
        // half = (20-1)/2 = 9, so 9 prefix + 1 ellipsis + 9 suffix = 19 chars
        XCTAssertEqual(result.count, 19)
    }

    func testTruncateEmptyString() {
        XCTAssertEqual(URLUtilities.truncateMiddle("", maxLength: 10), "")
    }

    func testTruncateUsesUnicodeEllipsis() {
        let result = URLUtilities.truncateMiddle("0123456789", maxLength: 5)
        XCTAssertTrue(result.contains("\u{2026}"))
        XCTAssertFalse(result.contains("..."))
    }
}
