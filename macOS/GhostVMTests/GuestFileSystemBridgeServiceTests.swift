import XCTest
@testable import GhostFileKit

@MainActor
final class GuestFileSystemBridgeServiceTests: XCTestCase {
    func testRegistrationCreatesAuthenticatedLoopbackGhostFileResource() async throws {
        let client = MockGhostClient()
        let bridge = GuestFileSystemBridgeService()
        try bridge.start(client: client)
        defer { bridge.stop() }

        let export = try await bridge.registerExport(guestPath: "/tmp", readOnly: true)
        let url = export.resourceURL
        XCTAssertEqual(url.scheme, "ghostfile")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertNotEqual(url.port, 0)

        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.filter { $0.name == "pk" }.count, 1)
        XCTAssertEqual(items.filter { $0.name == "access_key" }.count, 1)
        XCTAssertEqual(
            items.first { $0.name == GhostFileProtocol.cacheTTLQueryName }?.value,
            String(GhostFileProtocol.defaultCacheTTLSeconds)
        )
        XCTAssertEqual(items.filter { $0.name == "mount_instance" }.count, 1)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.name == "access_key" }?.value).isEmpty)

        bridge.unregisterExport(id: export.id)
    }

    @MainActor
    func testRegisteredExportIncludesRequestedCacheTTL() async throws {
        let bridge = GuestFileSystemBridgeService()
        let client = MockGhostClient()
        try bridge.start(client: client)
        defer { bridge.stop() }

        let export = try await bridge.registerExport(
            guestPath: "/tmp",
            readOnly: true,
            cacheTTLSeconds: 0
        )
        let items = try XCTUnwrap(
            URLComponents(url: export.resourceURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(items.first { $0.name == GhostFileProtocol.cacheTTLQueryName }?.value, "0")
        bridge.unregisterExport(id: export.id)
    }

    func testRegistrationAcceptsWritableExport() async throws {
        let client = MockGhostClient()
        let bridge = GuestFileSystemBridgeService()
        try bridge.start(client: client)
        defer { bridge.stop() }

        let export = try await bridge.registerExport(guestPath: "/tmp", readOnly: false)
        XCTAssertEqual(export.resourceURL.scheme, "ghostfile")
        let mountClient = try GhostFileHTTP3Client(resourceURL: export.resourceURL)
        let capabilities = try await mountClient.capabilities()
        XCTAssertFalse(capabilities.readOnly)
        _ = try await mountClient.create(path: "created", type: .file, mode: 0o600)
        XCTAssertEqual(client.createdFileSystemItems.first?.path, "/tmp/created")
        bridge.unregisterExport(id: export.id)
    }

    func testRegistrationRejectsInvalidGuestPaths() async throws {
        let bridge = GuestFileSystemBridgeService()
        try bridge.start(client: MockGhostClient())
        defer { bridge.stop() }

        await XCTAssertThrowsErrorAsync {
            _ = try await bridge.registerExport(guestPath: "relative", readOnly: true)
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
