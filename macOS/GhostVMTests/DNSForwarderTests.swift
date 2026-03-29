import XCTest
@testable import GhostVMKit

final class DNSForwarderTests: XCTestCase {

    /// Build a minimal DNS query for "example.com" type A.
    func buildDNSQuery() -> Data {
        var query = Data()
        // Header: ID=0x1234, flags=0x0100 (standard query), QDCOUNT=1
        query.append(contentsOf: [0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        // Question: example.com, type A, class IN
        query.append(contentsOf: [7]) // length of "example"
        query.append(contentsOf: "example".utf8)
        query.append(contentsOf: [3]) // length of "com"
        query.append(contentsOf: "com".utf8)
        query.append(contentsOf: [0]) // root label
        query.append(contentsOf: [0x00, 0x01]) // type A
        query.append(contentsOf: [0x00, 0x01]) // class IN
        return query
    }

    func testBlockedMode() {
        let forwarder = DNSForwarder(mode: .blocked, queue: DispatchQueue(label: "test.dns"))
        let query = buildDNSQuery()

        let expectation = expectation(description: "DNS blocked response")
        forwarder.handleQuery(query) { response in
            XCTAssertNotNil(response)
            if let response = response {
                // Check QR bit is set (response)
                XCTAssertTrue(response[2] & 0x80 != 0, "QR bit should be set")
                // Check RCODE is 3 (NXDOMAIN)
                XCTAssertEqual(response[3] & 0x0F, 3, "RCODE should be NXDOMAIN")
                // Check transaction ID preserved
                XCTAssertEqual(response[0], 0x12)
                XCTAssertEqual(response[1], 0x34)
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testBlockedModeTruncatedQuery() {
        let forwarder = DNSForwarder(mode: .blocked, queue: DispatchQueue(label: "test.dns"))
        let truncated = Data([0x12, 0x34]) // too short

        let expectation = expectation(description: "DNS blocked truncated")
        forwarder.handleQuery(truncated) { response in
            XCTAssertNil(response, "Should return nil for truncated query")
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testCustomModeWithEmptyServers() {
        let forwarder = DNSForwarder(mode: .custom([]), queue: DispatchQueue(label: "test.dns"))
        let query = buildDNSQuery()

        let expectation = expectation(description: "DNS custom empty")
        forwarder.handleQuery(query) { response in
            XCTAssertNotNil(response)
            // Should get NXDOMAIN when no servers configured
            if let response = response {
                XCTAssertEqual(response[3] & 0x0F, 3)
            }
            expectation.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testStop() {
        let forwarder = DNSForwarder(mode: .blocked, queue: DispatchQueue(label: "test.dns"))
        forwarder.stop() // should not crash
    }
}
