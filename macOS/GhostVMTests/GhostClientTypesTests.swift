import XCTest
@testable import GhostVMKit

final class GhostClientTypesTests: XCTestCase {
    func testClipboardGetResponseWithData() throws {
        let response = ClipboardGetResponse(data: Data("hello".utf8), type: "public.utf8-plain-text")
        XCTAssertEqual(response.content, "hello")
        XCTAssertEqual(response.type, "public.utf8-plain-text")
        XCTAssertEqual(response.data, Data("hello".utf8))
    }

    func testClipboardGetResponseWithNils() throws {
        let response = ClipboardGetResponse(data: nil, type: nil)
        XCTAssertNil(response.content)
        XCTAssertNil(response.type)
        XCTAssertNil(response.data)
    }

    func testClipboardGetResponseBinaryData() throws {
        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47])
        let response = ClipboardGetResponse(data: pngHeader, type: "public.png")
        XCTAssertEqual(response.type, "public.png")
        XCTAssertEqual(response.data, pngHeader)
        XCTAssertNil(response.content) // binary data won't decode as UTF-8
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

    func testClipboardGetResponseConvenienceContent() throws {
        // UTF-8 text data should produce non-nil content
        let response = ClipboardGetResponse(data: Data("test content".utf8), type: "public.utf8-plain-text")
        XCTAssertEqual(response.content, "test content")

        // Empty data should produce empty content
        let empty = ClipboardGetResponse(data: Data(), type: "public.utf8-plain-text")
        XCTAssertEqual(empty.content, "")
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
        mock.clipboardData = Data("test".utf8)

        let response = try await mock.getClipboard()
        XCTAssertEqual(response.content, "test")
        XCTAssertEqual(mock.getClipboardCallCount, 1)

        try await mock.setClipboard(data: Data("new".utf8), type: "public.utf8-plain-text")
        XCTAssertEqual(mock.setClipboardCalls.count, 1)
        XCTAssertEqual(String(data: mock.setClipboardCalls[0].data, encoding: .utf8), "new")

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
