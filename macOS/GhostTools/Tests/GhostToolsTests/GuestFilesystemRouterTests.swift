import Foundation
import XCTest
@testable import GhostTools

final class GuestFilesystemRouterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosttools-fs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("abcdef".utf8).write(to: directory.appendingPathComponent("sample.txt"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("sample-link").path,
            withDestinationPath: "sample.txt"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMetadataReturnsRegularFileAttributes() throws {
        let response = try route(
            path: "/api/v1/fs/metadata", query: [
                URLQueryItem(name: "path", value: directory.appendingPathComponent("sample.txt").path),
            ]
        )

        XCTAssertEqual(response.status, .ok)
        let metadata = try JSONDecoder().decode(GuestFileMetadata.self, from: responseData(response))
        XCTAssertEqual(metadata.name, "sample.txt")
        XCTAssertEqual(metadata.type, .file)
        XCTAssertEqual(metadata.size, 6)
        XCTAssertNotEqual(metadata.inode, 0)
    }

    func testListReturnsTypedEntries() throws {
        let response = try route(
            path: "/api/v1/fs/list", query: [URLQueryItem(name: "path", value: directory.path)]
        )

        XCTAssertEqual(response.status, .ok)
        let listing = try JSONDecoder().decode(GuestDirectoryMetadata.self, from: responseData(response))
        XCTAssertEqual(listing.entries.map(\.name), ["folder", "sample-link", "sample.txt"])
        XCTAssertEqual(listing.entries.map(\.type), [.directory, .symbolicLink, .file])
    }

    func testRangeReadReturnsRequestedBytes() throws {
        let response = try route(
            path: "/api/v1/fs/read", query: [
                URLQueryItem(name: "path", value: directory.appendingPathComponent("sample.txt").path),
                URLQueryItem(name: "offset", value: "2"),
                URLQueryItem(name: "length", value: "3"),
            ]
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(String(data: try responseData(response), encoding: .utf8), "cde")
    }

    func testRangeReadRejectsMoreThanOneMiB() throws {
        let response = try route(
            path: "/api/v1/fs/read", query: [
                URLQueryItem(name: "path", value: directory.appendingPathComponent("sample.txt").path),
                URLQueryItem(name: "offset", value: "0"),
                URLQueryItem(name: "length", value: String(1024 * 1024 + 1)),
            ]
        )

        XCTAssertEqual(response.status, .badRequest)
    }

    func testReadSymbolicLinkReturnsTarget() throws {
        let response = try route(
            path: "/api/v1/fs/readlink", query: [
                URLQueryItem(name: "path", value: directory.appendingPathComponent("sample-link").path),
            ]
        )

        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(String(data: try responseData(response), encoding: .utf8), "sample.txt")
    }

    private func route(path: String, query: [URLQueryItem]) throws -> HTTPResponse {
        var components = URLComponents()
        components.path = path
        components.queryItems = query
        let request = HTTPRequest(method: .GET, path: components.string!, headers: [:])
        let body = BodyReader(fd: -1, framing: .knownLength(0), prelude: Data())
        return try Router().route(request: request, body: body)
    }

    private func responseData(_ response: HTTPResponse) throws -> Data {
        guard case .bytes(let data) = response.body else {
            throw XCTSkip("Expected an in-memory response body")
        }
        return data
    }
}
