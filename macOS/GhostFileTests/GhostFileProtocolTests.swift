import Foundation
import GhostHTTP
import XCTest
@testable import GhostFile

final class GhostFileProtocolTests: XCTestCase {
    func testMountInstancesIdentifyOtherwiseIdenticalNetworkVolumes() throws {
        let first = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let second = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let base = "ghostfile://example.local:443/v1/shares/99999999-8888-7777-6666-555555555555"
        let firstURL = try XCTUnwrap(URL(string: "\(base)?mount_instance=\(first.uuidString)"))
        let secondURL = try XCTUnwrap(URL(string: "\(base)?mount_instance=\(second.uuidString)"))

        XCTAssertEqual(GhostFileProtocol.mountInstanceID(from: firstURL), first)
        XCTAssertEqual(GhostFileProtocol.mountInstanceID(from: secondURL), second)
        XCTAssertNotEqual(
            GhostFileProtocol.mountInstanceID(from: firstURL),
            GhostFileProtocol.mountInstanceID(from: secondURL)
        )
        XCTAssertNil(GhostFileProtocol.mountInstanceID(from: try XCTUnwrap(URL(string: base))))
    }

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

final class GhostFileBonjourLeaseTests: XCTestCase {
    func testAdvertisedTTLIsShortAndHeartbeatRefreshesBeforeExpiry() {
        XCTAssertEqual(GhostFileBonjourLease.advertisedTTL, 6)
        XCTAssertLessThan(
            GhostFileBonjourLease.heartbeatInterval,
            .seconds(GhostFileBonjourLease.advertisedTTL)
        )
    }

    func testTTLParsingBoundsUntrustedAdvertisements() {
        XCTAssertEqual(GhostFileBonjourLease.ttl(from: [:]), 15)
        XCTAssertEqual(GhostFileBonjourLease.ttl(from: ["ttl": Data("1".utf8)]), 4)
        XCTAssertEqual(GhostFileBonjourLease.ttl(from: ["ttl": Data("6".utf8)]), 6)
        XCTAssertEqual(GhostFileBonjourLease.ttl(from: ["ttl": Data("600".utf8)]), 60)
        XCTAssertEqual(GhostFileBonjourLease.ttl(from: ["ttl": Data("invalid".utf8)]), 15)
    }

    func testLeaseExpiresAtAdvertisedTTL() {
        let lastSeen = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(GhostFileBonjourLease.isExpired(
            lastSeen: lastSeen,
            ttl: 6,
            now: Date(timeIntervalSince1970: 1_005.999)
        ))
        XCTAssertTrue(GhostFileBonjourLease.isExpired(
            lastSeen: lastSeen,
            ttl: 6,
            now: Date(timeIntervalSince1970: 1_006)
        ))
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
