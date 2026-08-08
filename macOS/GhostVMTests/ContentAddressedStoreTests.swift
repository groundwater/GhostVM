import Foundation
import XCTest
@testable import GhostVMKit

final class ContentAddressedStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostVM-ContentStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPutPublishesAtDigestPath() async throws {
        let store = ContentAddressedStore(rootURL: temporaryDirectory)
        let data = Data("hello".utf8)

        let digest = try await store.put(data)
        let url = try await store.blobURL(for: digest)
        let containsBlob = await store.contains(digest)

        XCTAssertEqual(digest.description, "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertTrue(containsBlob)
    }

    func testDuplicatePutReusesBlob() async throws {
        let store = ContentAddressedStore(rootURL: temporaryDirectory)
        let data = Data("same blob".utf8)

        let first = try await store.put(data)
        let second = try await store.put(data)

        XCTAssertEqual(first, second)
        let files = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory.appendingPathComponent("blobs/sha256"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
    }

    func testImportRejectsDigestMismatchAndCleansIngest() async throws {
        let store = ContentAddressedStore(rootURL: temporaryDirectory)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostVM-ContentSource-\(UUID().uuidString)")
        try Data("actual".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let expected = ContentDigest.sha256(Data("expected".utf8))
        do {
            try await store.importBlob(at: sourceURL, expectedDigest: expected)
            XCTFail("Expected digest mismatch")
        } catch let error as ContentStoreError {
            guard case .digestMismatch(let reportedExpected, _) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(reportedExpected, expected)
        }

        let ingest = temporaryDirectory.appendingPathComponent("ingest")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ingest.path), [])
    }

    func testDigestValidation() throws {
        XCTAssertThrowsError(try ContentDigest("sha512:abcd"))
        XCTAssertThrowsError(try ContentDigest("sha256:abcd"))
        XCTAssertNoThrow(try ContentDigest("sha256:" + String(repeating: "a", count: 64)))
    }

    func testDigestCodableUsesOCIString() throws {
        let digest = ContentDigest.sha256(Data("hello".utf8))
        let encoded = try JSONEncoder().encode(digest)
        let decoded = try JSONDecoder().decode(ContentDigest.self, from: encoded)

        XCTAssertEqual(String(data: encoded, encoding: .utf8), #""sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824""#)
        XCTAssertEqual(decoded, digest)
    }
}
