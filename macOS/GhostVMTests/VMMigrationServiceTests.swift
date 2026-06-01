import XCTest
@testable import GhostVMKit

final class VMMigrationServiceTests: XCTestCase {
    func testRejectsDestinationThatMatchesSourcePath() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeMinimalBundle(named: "Source.GhostVM", in: root)
        let service = VMMigrationService()

        XCTAssertThrowsError(try service.validateDestination(source: source, destination: source)) { error in
            guard case VMMigrationService.MigrationError.destinationMatchesSource = error else {
                return XCTFail("Expected destinationMatchesSource, got \(error)")
            }
        }
    }

    func testCancelDoesNotRemoveChosenDestination() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeMinimalBundle(named: "Source.GhostVM", in: root)
        let destination = root.appendingPathComponent("Destination.GhostVM")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try "keep".write(to: marker, atomically: true, encoding: .utf8)

        let service = VMMigrationService()
        XCTAssertThrowsError(try service.migrate(
            source: source,
            destination: destination,
            progressHandler: { _, _ in service.cancel() }
        )) { error in
            guard case VMMigrationService.MigrationError.cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostvm-migration-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeMinimalBundle(named name: String, in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let disk = bundle.appendingPathComponent("disk.img")
        try Data(repeating: 0, count: 4).write(to: disk)
        return bundle
    }
}
