import XCTest
@testable import GhostVMKit

final class GhostClientTypesTests: XCTestCase {
    func testClipboardGetResponseDecode() throws {
        let json = """
        {"content": "hello", "type": "public.utf8-plain-text", "changeCount": 5}
        """
        let response = try JSONDecoder().decode(ClipboardGetResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.content, "hello")
        XCTAssertEqual(response.type, "public.utf8-plain-text")
        XCTAssertEqual(response.changeCount, 5)
    }

    func testClipboardGetResponseWithNulls() throws {
        let json = """
        {"content": null, "type": null, "changeCount": null}
        """
        let response = try JSONDecoder().decode(ClipboardGetResponse.self, from: json.data(using: .utf8)!)
        XCTAssertNil(response.content)
        XCTAssertNil(response.type)
        XCTAssertNil(response.changeCount)
    }

    func testFileReceiveResponseDecode() throws {
        let json = """
        {"path": "/Users/guest/Downloads/file.txt"}
        """
        let response = try JSONDecoder().decode(FileReceiveResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.path, "/Users/guest/Downloads/file.txt")
    }

    func testFileListResponseDecode() throws {
        let json = """
        {"files": ["a.txt", "b.png", "c.pdf"]}
        """
        let response = try JSONDecoder().decode(FileListResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.files, ["a.txt", "b.png", "c.pdf"])
    }

    func testFileListResponseEmpty() throws {
        let json = """
        {"files": []}
        """
        let response = try JSONDecoder().decode(FileListResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.files.isEmpty)
    }

    func testClipboardPostRequestEncode() throws {
        let request = ClipboardPostRequest(content: "test content")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ClipboardPostRequest.self, from: data)
        XCTAssertEqual(decoded.content, "test content")
        XCTAssertEqual(decoded.type, "public.utf8-plain-text")
    }

    func testGhostClientErrorDescriptions() {
        let errors: [GhostClientError] = [
            .notConnected,
            .noContent,
            .invalidResponse(404),
            .encodingError,
            .decodingError,
            .connectionFailed("test reason"),
            .timeout,
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) has nil errorDescription")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testURLListResponseDecode() throws {
        let json = """
        {"urls": ["https://example.com", "https://test.com"]}
        """
        let response = try JSONDecoder().decode(URLListResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.urls.count, 2)
    }

    func testLogListResponseDecode() throws {
        let json = """
        {"logs": ["log entry 1", "log entry 2"]}
        """
        let response = try JSONDecoder().decode(LogListResponse.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(response.logs.count, 2)
    }

    func testMockGhostClientProtocolConformance() async throws {
        let mock = MockGhostClient()
        mock.clipboardContent = "test"

        let response = try await mock.getClipboard()
        XCTAssertEqual(response.content, "test")
        XCTAssertEqual(mock.getClipboardCallCount, 1)

        try await mock.setClipboard(content: "new", type: "text")
        XCTAssertEqual(mock.setClipboardCalls.count, 1)
        XCTAssertEqual(mock.setClipboardCalls[0].content, "new")

        let healthy = await mock.checkHealth()
        XCTAssertTrue(healthy)
    }

    func testMockGhostClientThrows() async {
        let mock = MockGhostClient()
        mock.shouldThrow = GhostClientError.notConnected

        do {
            _ = try await mock.getClipboard()
            XCTFail("Expected error")
        } catch {
            // Expected
        }
    }
}
