import Foundation
import XCTest
import GhostFileKit
@testable import GhostVMKit

final class GuestPathProviderTests: XCTestCase {
    func testForwardsAllMutationsToGuestClient() async throws {
        let client = MockGhostClient()
        let provider = GuestPathProvider(client: client, root: "/Users/guest/share")

        _ = try await provider.create(path: "folder", type: .directory, mode: 0o750)
        _ = try await provider.createSymbolicLink(path: "link", destination: "folder/file")
        _ = try await provider.write(path: "folder/file", offset: 7, data: Data("data".utf8))
        _ = try await provider.setAttributes(
            path: "folder/file",
            attributes: GhostFileProviderAttributes(mode: 0o600, size: 4)
        )
        _ = try await provider.rename(path: "folder/file", destinationPath: "folder/renamed")
        try await provider.remove(path: "folder/renamed")

        XCTAssertEqual(client.createdFileSystemItems.first?.path, "/Users/guest/share/folder")
        XCTAssertEqual(client.createdFileSystemItems.first?.type, .directory)
        XCTAssertEqual(client.createdFileSystemItems.first?.mode, 0o750)
        XCTAssertEqual(client.createdSymbolicLinks.first?.path, "/Users/guest/share/link")
        XCTAssertEqual(client.createdSymbolicLinks.first?.destination, "folder/file")
        XCTAssertEqual(client.fileWrites.first?.path, "/Users/guest/share/folder/file")
        XCTAssertEqual(client.fileWrites.first?.offset, 7)
        XCTAssertEqual(client.fileAttributeChanges.first?.attributes.mode, 0o600)
        XCTAssertEqual(client.fileAttributeChanges.first?.attributes.size, 4)
        XCTAssertEqual(client.renamedFileSystemItems.first?.destinationPath, "/Users/guest/share/folder/renamed")
        XCTAssertEqual(client.removedFileSystemItems, ["/Users/guest/share/folder/renamed"])
    }

    func testRejectsEscapingRelativePathsBeforeRPC() async {
        let client = MockGhostClient()
        let provider = GuestPathProvider(client: client, root: "/Users/guest/share")

        do {
            _ = try await provider.write(path: "../outside", offset: 0, data: Data())
            XCTFail("Expected invalid path")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EINVAL)
        } catch {
            XCTFail("Expected POSIX EINVAL, got \(error)")
        }
        XCTAssertTrue(client.fileWrites.isEmpty)
    }
}
