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

    func testMutationLifecycle() throws {
        let createdURL = directory.appendingPathComponent("created.txt")
        var response = try route(
            method: .POST,
            path: "/api/v1/fs/create",
            body: try JSONEncoder().encode(FSCreateRequest(path: createdURL.path, type: .file, mode: 0o640))
        )
        XCTAssertEqual(response.status, .ok)

        response = try route(
            method: .PATCH,
            path: "/api/v1/fs/write",
            query: [
                URLQueryItem(name: "path", value: createdURL.path),
                URLQueryItem(name: "offset", value: "2"),
            ],
            body: Data("abc".utf8)
        )
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(try Data(contentsOf: createdURL), Data([0, 0]) + Data("abc".utf8))

        response = try route(
            method: .PATCH,
            path: "/api/v1/fs/attributes",
            body: try JSONEncoder().encode(FSSetAttributesRequest(
                path: createdURL.path,
                attributes: FSFileAttributes(
                    mode: 0o600,
                    size: 4,
                    modifiedSeconds: 1_700_000_000,
                    modifiedNanoseconds: 0,
                    accessedSeconds: nil,
                    accessedNanoseconds: nil
                )
            ))
        )
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(try Data(contentsOf: createdURL).count, 4)
        let attributes = try FileManager.default.attributesOfItem(atPath: createdURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.uint32Value, 0o600)

        let renamedURL = directory.appendingPathComponent("renamed.txt")
        response = try route(
            method: .POST,
            path: "/api/v1/fs/rename",
            body: try JSONEncoder().encode(FSRenameRequest(
                path: createdURL.path,
                destinationPath: renamedURL.path
            ))
        )
        XCTAssertEqual(response.status, .ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))

        let linkURL = directory.appendingPathComponent("created-link")
        response = try route(
            method: .POST,
            path: "/api/v1/fs/symlink",
            body: try JSONEncoder().encode(FSSymbolicLinkRequest(
                path: linkURL.path,
                destination: "renamed.txt"
            ))
        )
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path), "renamed.txt")

        response = try route(
            method: .DELETE,
            path: "/api/v1/fs/remove",
            query: [URLQueryItem(name: "path", value: renamedURL.path)]
        )
        XCTAssertEqual(response.status, .noContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedURL.path))
    }

    func testCreateDirectoryAndPreservePOSIXError() throws {
        let newDirectory = directory.appendingPathComponent("new-directory", isDirectory: true)
        let requestBody = try JSONEncoder().encode(FSCreateRequest(
            path: newDirectory.path,
            type: .directory,
            mode: 0o750
        ))
        XCTAssertEqual(
            try route(method: .POST, path: "/api/v1/fs/create", body: requestBody).status,
            .ok
        )

        let duplicate = try route(method: .POST, path: "/api/v1/fs/create", body: requestBody)
        XCTAssertEqual(duplicate.status, .conflict)
        let payload = try JSONDecoder().decode(GuestFilesystemErrorResponse.self, from: responseData(duplicate))
        XCTAssertEqual(payload.errno, EEXIST)
    }

    func testReadErrorPreservesPOSIXError() throws {
        let response = try route(
            path: "/api/v1/fs/metadata",
            query: [URLQueryItem(name: "path", value: directory.appendingPathComponent("missing").path)]
        )
        XCTAssertEqual(response.status, .notFound)
        let payload = try JSONDecoder().decode(GuestFilesystemErrorResponse.self, from: responseData(response))
        XCTAssertEqual(payload.errno, ENOENT)
    }

    private func route(
        method: HTTPMethod = .GET,
        path: String,
        query: [URLQueryItem] = [],
        body: Data = Data()
    ) throws -> HTTPResponse {
        var components = URLComponents()
        components.path = path
        components.queryItems = query
        let request = HTTPRequest(method: method, path: components.string!, headers: [:])
        let reader = BodyReader(fd: -1, framing: .knownLength(body.count), prelude: body)
        return try Router().route(request: request, body: reader)
    }

    private func responseData(_ response: HTTPResponse) throws -> Data {
        guard case .bytes(let data) = response.body else {
            throw XCTSkip("Expected an in-memory response body")
        }
        return data
    }
}
