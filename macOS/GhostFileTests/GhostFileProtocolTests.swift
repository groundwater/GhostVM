import Foundation
import GhostHTTP
import XCTest
@testable import GhostFile

final class GhostFileProtocolTests: XCTestCase {
    func testRelativePathValidationRejectsEscapes() {
        XCTAssertEqual(GhostFilePath.validatedComponents("folder/file.txt"), ["folder", "file.txt"])
        XCTAssertEqual(GhostFilePath.validatedComponents(""), [])
        XCTAssertNil(GhostFilePath.validatedComponents("../secret"))
        XCTAssertNil(GhostFilePath.validatedComponents("folder/../secret"))
        XCTAssertNil(GhostFilePath.validatedComponents("/absolute"))
        XCTAssertNil(GhostFilePath.validatedComponents("bad\0name"))
    }

    func testByteRangeIsBoundedToProtocolMaximum() {
        XCTAssertEqual(
            GhostFileByteRange.parse("bytes=4-9", fileSize: 20, maximumLength: 1024),
            .init(offset: 4, length: 6)
        )
        XCTAssertEqual(
            GhostFileByteRange.parse("bytes=10-", fileSize: 100, maximumLength: 8),
            .init(offset: 10, length: 8)
        )
        XCTAssertNil(GhostFileByteRange.parse("bytes=20-30", fileSize: 20, maximumLength: 8))
        XCTAssertNil(GhostFileByteRange.parse("items=0-1", fileSize: 20, maximumLength: 8))
    }
}

final class GhostFileShareRouterTests: XCTestCase {
    private var directory: URL!
    private var router: GhostFileShareRouter!
    private let shareID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let accessKey = "demo-access-key"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abcdefghij".utf8).write(to: directory.appendingPathComponent("sample.txt"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: true
        )
        router = GhostFileShareRouter(
            rootURL: directory,
            shareID: shareID,
            shareName: "DemoShare",
            accessKey: accessKey
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCapabilitiesRequireAccessKey() throws {
        let path = "\(GhostFileProtocol.shareBasePath(id: shareID))/capabilities"
        let unauthorized = router.route(.init(method: .GET, path: path))
        XCTAssertEqual(unauthorized.status, .unauthorized)

        let authorized = router.route(request(method: .GET, path: path))
        XCTAssertEqual(authorized.status, .ok)
        let capabilities = try JSONDecoder().decode(GhostFileCapabilities.self, from: bodyData(authorized))
        XCTAssertEqual(capabilities.shareID, shareID)
        XCTAssertTrue(capabilities.readOnly)
        XCTAssertEqual(capabilities.transports, [GhostFileProtocol.transport])
    }

    func testMetadataAndDirectoryListing() throws {
        let metadataResponse = router.route(request(
            method: .GET,
            path: operationPath("metadata", relativePath: "sample.txt")
        ))
        XCTAssertEqual(metadataResponse.status, .ok)
        let metadata = try JSONDecoder().decode(GhostFileMetadata.self, from: bodyData(metadataResponse))
        XCTAssertEqual(metadata.name, "sample.txt")
        XCTAssertEqual(metadata.type, .file)
        XCTAssertEqual(metadata.size, 10)

        let listingResponse = router.route(request(
            method: .GET,
            path: operationPath("directory", relativePath: "")
        ))
        XCTAssertEqual(listingResponse.status, .ok)
        let listing = try JSONDecoder().decode(GhostFileDirectoryListing.self, from: bodyData(listingResponse))
        XCTAssertEqual(listing.entries.map(\.name), ["folder", "sample.txt"])
        XCTAssertNotEqual(listing.verifier, 0)
        XCTAssertEqual(listing.inlineContents?.map(\.name), ["sample.txt"])
        XCTAssertEqual(listing.inlineContents?.first?.data, Data("abcdefghij".utf8))
        XCTAssertEqual(listing.inlineContents?.first?.etag, listing.entries.last?.etag)
    }

    func testDirectoryListingBoundsInlineContent() throws {
        let oversized = Data(repeating: 0x41, count: GhostFileProtocol.maximumInlineFileLength + 1)
        try oversized.write(to: directory.appendingPathComponent("oversized.bin"))

        let listingResponse = router.route(request(
            method: .GET,
            path: operationPath("directory", relativePath: "")
        ))
        XCTAssertEqual(listingResponse.status, .ok)
        let listing = try JSONDecoder().decode(GhostFileDirectoryListing.self, from: bodyData(listingResponse))
        XCTAssertTrue(listing.entries.contains(where: { $0.name == "oversized.bin" }))
        XCTAssertFalse(listing.inlineContents?.contains(where: { $0.name == "oversized.bin" }) ?? false)
    }

    func testRangeReadStreamsOnlyRequestedBytes() throws {
        let response = router.route(request(
            method: .GET,
            path: operationPath("content", relativePath: "sample.txt"),
            extraHeaders: ["Range": "bytes=2-5"]
        ))
        XCTAssertEqual(response.status, .partialContent)
        XCTAssertEqual(response.headers["Content-Range"], "bytes 2-5/10")
        XCTAssertEqual(String(data: try bodyData(response), encoding: .utf8), "cdef")
    }

    func testTraversalIsRejected() {
        let response = router.route(request(
            method: .GET,
            path: operationPath("metadata", relativePath: "../secret")
        ))
        XCTAssertEqual(response.status, .badRequest)
    }

    private func request(
        method: HTTPMethod,
        path: String,
        extraHeaders: [String: String] = [:]
    ) -> HTTPRequestHead {
        var headers = extraHeaders
        headers["Authorization"] = "Bearer \(accessKey)"
        return HTTPRequestHead(method: method, path: path, headers: HTTPHeaders(headers))
    }

    private func operationPath(_ operation: String, relativePath: String) -> String {
        "\(GhostFileProtocol.shareBasePath(id: shareID))/\(operation)?\(GhostFilePath.percentEncodedQuery(relativePath))"
    }

    private func bodyData(_ response: GhostFileHTTPResponse) throws -> Data {
        switch response.body {
        case .empty:
            return Data()
        case .bytes(let data):
            return data
        case .fileRegion(let path, _, let offset, let length):
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            return try XCTUnwrap(handle.read(upToCount: length))
        }
    }
}

final class GhostFileTLSIdentityTests: XCTestCase {
    func testCreatesPinnedEphemeralIdentity() throws {
        let identity = try GhostFileTLSIdentity.make()
        XCTAssertFalse(identity.publicKeyPin.isEmpty)
        XCTAssertFalse(identity.publicKeyPin.contains("="))
    }
}
