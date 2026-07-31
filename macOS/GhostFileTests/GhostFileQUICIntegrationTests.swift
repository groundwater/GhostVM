import Foundation
import Network
import XCTest
@testable import GhostFile

final class GhostFileHTTP3IntegrationTests: XCTestCase {
    func testPausedRequestDoesNotBlockAnotherRequestOnSameHTTP3Connection() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-quic-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("hello over HTTP/3".utf8).write(to: fixture.appendingPathComponent("hello.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "quic-integration-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileHTTP3Integration",
                accessKey: accessKey,
                requestDelay: { request in
                    if request.path == "slow.txt" {
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            )
            try server.start()
            return server
        }

        let shareURL = try await waitForShareURL(server)
        let connectionDetails = try { () -> (NWEndpoint.Port, String) in
            guard let portNumber = shareURL.port,
                  let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
                  let components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
                  let pin = components.queryItems?.first(where: { $0.name == "tls_pin" })?.value else {
                throw TestError.missingShareURL
            }
            return (port, pin)
        }()
        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: connectionDetails.0,
            accessKey: accessKey,
            publicKeyPin: connectionDetails.1,
            resourceBasePath: shareURL.path
        )

        async let pausedResponse = transport.request(
            operation: "metadata",
            relativePath: "slow.txt",
            offset: nil,
            length: nil
        )
        try await Task.sleep(for: .milliseconds(100))

        let clock = ContinuousClock()
        let started = clock.now
        let fastResponse = try await transport.request(
            operation: "metadata",
            relativePath: "hello.txt",
            offset: nil,
            length: nil
        )
        let elapsed = started.duration(to: clock.now)

        XCTAssertEqual(fastResponse.status, 200)
        XCTAssertLessThan(elapsed, .seconds(1), "A paused HTTP/3 request blocked an independent stream")
        _ = try await pausedResponse
        await MainActor.run { server.stop() }
    }

    func testConcurrentRangeReadsUseOneHTTP3Connection() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-quic-load-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: fixture.appendingPathComponent("payload.bin"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "quic-load-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileHTTP3Load",
                accessKey: accessKey
            )
            try server.start()
            return server
        }

        let shareURL = try await waitForShareURL(server)
        let resourceURL = try { () -> URL in
            guard var components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false) else {
                throw TestError.missingShareURL
            }
            components.host = "127.0.0.1"
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "access_key", value: accessKey)
            ]
            guard let url = components.url else { throw TestError.missingShareURL }
            return url
        }()
        let client = try GhostFileHTTP3Client(resourceURL: resourceURL)

        let chunkSize = 64 * 1024
        try await withThrowingTaskGroup(of: Void.self) { group in
            for chunkIndex in 0..<32 {
                group.addTask {
                    let offset = chunkIndex * chunkSize
                    let data = try await client.read(
                        path: "payload.bin",
                        offset: UInt64(offset),
                        length: chunkSize
                    )
                    XCTAssertEqual(data, payload.subdata(in: offset..<(offset + chunkSize)))
                }
            }
            try await group.waitForAll()
        }
        await MainActor.run { server.stop() }
    }

    private enum TestError: Error {
        case missingShareURL
    }

    private func waitForShareURL(_ server: GhostFileShareServer) async throws -> URL {
        for _ in 0..<200 {
            if let url = await MainActor.run(body: { server.shareURL }) {
                return url
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.missingShareURL
    }
}
