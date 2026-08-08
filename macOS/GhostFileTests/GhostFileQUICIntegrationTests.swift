import Foundation
import Network
import XCTest
@testable import GhostFile
@testable import GhostFileKit

final class GhostFileHTTP3IntegrationTests: XCTestCase {
    func testInstalledGhostVMFSMountReadsLiveLoopbackShare() async throws {
        let extensionURL = URL(
            fileURLWithPath: "/Applications/GhostVM.app/Contents/Extensions/GhostVMFS.appex",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            throw XCTSkip("GhostVMFS is not installed")
        }

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostvm-fskit-mount-tests-\(UUID().uuidString)", isDirectory: true)
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostvm-fskit-mounted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Data("mounted through GhostVMFS".utf8)
            .write(to: fixture.appendingPathComponent("proof.txt"))
        defer {
            try? FileManager.default.removeItem(at: fixture)
            try? FileManager.default.removeItem(at: mountPoint)
        }

        let accessKey = "ghostvm-fskit-mount-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostVMFSMountTest",
                accessKey: accessKey,
                readOnly: true,
                visibility: .loopbackOnly,
                advertisesBonjour: false
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        var components = try XCTUnwrap(URLComponents(url: shareURL, resolvingAgainstBaseURL: false))
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "access_key", value: accessKey),
            URLQueryItem(name: "mount_instance", value: UUID().uuidString.lowercased()),
        ]
        let resourceURL = try XCTUnwrap(components.url)

        let mount = Process()
        let mountOutput = Pipe()
        mount.executableURL = URL(fileURLWithPath: "/sbin/mount")
        mount.arguments = [
            "-F", "-t", "ghostvm",
            "-o", "rdonly,nobrowse,nodev,nosuid",
            resourceURL.absoluteString,
            mountPoint.path,
        ]
        mount.standardOutput = mountOutput
        mount.standardError = mountOutput
        try mount.run()
        mount.waitUntilExit()
        let mountDetail = String(
            data: mountOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(mount.terminationStatus, 0, mountDetail)
        guard mount.terminationStatus == 0 else { return }
        defer {
            let unmount = Process()
            unmount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            unmount.arguments = [mountPoint.path]
            try? unmount.run()
            unmount.waitUntilExit()
        }

        XCTAssertEqual(
            try String(contentsOf: mountPoint.appendingPathComponent("proof.txt"), encoding: .utf8),
            "mounted through GhostVMFS"
        )
    }

    func testLoopbackOnlyShareProducesAuthenticatedReadOnlyResource() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-loopback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = UUID().uuidString
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "LoopbackTest",
                accessKey: accessKey,
                readOnly: true,
                visibility: .loopbackOnly,
                advertisesBonjour: false
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        XCTAssertEqual(shareURL.host, "127.0.0.1")
        XCTAssertNotEqual(shareURL.port, 0)
        let resourceURL = try loopbackResourceURL(shareURL: shareURL, accessKey: accessKey)
        let client = try GhostFileHTTP3Client(resourceURL: resourceURL)
        let capabilities = try await client.capabilities()
        XCTAssertTrue(capabilities.readOnly)
    }

    func testWritableShareMutatesFilesEndToEndAndSwitchesReadOnlyLive() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-write-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "write-integration-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "WritableTest",
                accessKey: accessKey,
                readOnly: false
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        let client = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey)
        )
        let writableCapabilities = try await client.capabilities()
        XCTAssertFalse(writableCapabilities.readOnly)

        _ = try await client.create(path: "folder", type: .directory, mode: 0o750)
        let created = try await client.create(path: "folder/data.bin", type: .file, mode: 0o640)
        let payload = Data((0..<(2 * GhostFileProtocol.maximumWriteLength + 123)).map { UInt8($0 & 0xff) })
        _ = try await client.write(path: "folder/data.bin", offset: 0, data: payload)
        XCTAssertEqual(try Data(contentsOf: fixture.appendingPathComponent("folder/data.bin")), payload)

        _ = try await client.create(path: "folder/concurrent.bin", type: .file, mode: 0o640)
        let concurrentChunks = (0..<3).map { index in
            Data(repeating: UInt8(0x40 + index), count: GhostFileProtocol.maximumWriteLength)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, chunk) in concurrentChunks.enumerated() {
                group.addTask {
                    _ = try await client.write(
                        path: "folder/concurrent.bin",
                        offset: UInt64(index * GhostFileProtocol.maximumWriteLength),
                        data: chunk
                    )
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.appendingPathComponent("folder/concurrent.bin")),
            concurrentChunks.reduce(into: Data()) { $0.append($1) }
        )
        try await client.remove(path: "folder/concurrent.bin")

        _ = try await client.setAttributes(
            path: "folder/data.bin",
            attributes: GhostFileSetAttributesRequest(mode: 0o600, size: 257)
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: fixture.appendingPathComponent("folder/data.bin").path
            )[.size] as? NSNumber,
            NSNumber(value: 257)
        )

        let renamed = try await client.rename(
            path: "folder/data.bin",
            destinationPath: "folder/renamed.bin"
        )
        XCTAssertEqual(renamed.objectID, created.objectID)
        _ = try await client.createSymbolicLink(path: "folder/link", destination: "renamed.bin")
        let linkDestination = try await client.readSymbolicLink(path: "folder/link")
        XCTAssertEqual(linkDestination, "renamed.bin")
        let remoteContents = try await client.read(
            path: "folder/renamed.bin",
            offset: 0,
            length: 257
        )
        XCTAssertEqual(remoteContents, payload.prefix(257))

        try await client.remove(path: "folder/link")
        try await client.remove(path: "folder/renamed.bin")
        try await client.remove(path: "folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("folder").path))

        await MainActor.run { server.setReadOnly(true) }
        let readOnlyCapabilities = try await client.capabilities()
        XCTAssertTrue(readOnlyCapabilities.readOnly)
        do {
            _ = try await client.create(path: "must-not-exist", type: .file, mode: 0o600)
            XCTFail("A live read-only share accepted a create")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(error.code, Int(EROFS))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("must-not-exist").path))
    }

    func testPublishedShareURLConnectsThroughResolvedBonjourHost() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-share-url-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "bonjour-share-url-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "URLTest-\(UUID().uuidString)",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        guard var components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false) else {
            throw TestError.missingShareURL
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "access_key", value: accessKey)
        ]
        let resourceURL = try XCTUnwrap(components.url)
        let client = try GhostFileHTTP3Client(resourceURL: resourceURL)
        let capabilities = try await client.capabilities()
        let expectedShareID = await MainActor.run { server.shareID }

        XCTAssertEqual(capabilities.shareID, expectedShareID)
        XCTAssertEqual(shareURL.host?.hasSuffix(".local"), true)
        XCTAssertNotEqual(shareURL.host, "connectivity-check.warp-svc.local")
    }

    func testMismatchedPublicKeyPinRejectsPeerBeforeAccessKeyIsSent() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-pin-mismatch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "must-not-cross-an-untrusted-connection"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "PinMismatchTest",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        var resourceComponents = try XCTUnwrap(URLComponents(
            url: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey),
            resolvingAgainstBaseURL: false
        ))
        let unrelatedIdentity = try GhostFileTLSIdentity.make()
        resourceComponents.queryItems = resourceComponents.queryItems?.map { item in
            item.name == GhostFileProtocol.publicKeyPinQueryName
                ? URLQueryItem(name: item.name, value: unrelatedIdentity.publicKeyPin)
                : item
        }
        let client = try GhostFileHTTP3Client(
            resourceURL: try XCTUnwrap(resourceComponents.url),
            connectionTimeout: .seconds(2),
            requestTimeout: .seconds(2)
        )

        do {
            _ = try await client.capabilities()
            XCTFail("A client accepted a server with the wrong public key")
        } catch {}
        let receivedRequestCount = await MainActor.run { server.requestCount }
        XCTAssertEqual(receivedRequestCount, 0, "The access key was sent before peer authentication")
    }

    func testSavedLinkSurvivesCertificateReissueWithPersistentPrivateKey() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-persistent-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let shareID = UUID()
        let accessKey = "persistent-identity-key"
        let initialIdentity = try GhostFileTLSIdentity.make()
        let storedPrivateKey = initialIdentity.privateKeyRepresentation
        let firstServer = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "PersistentIdentityTest",
                accessKey: accessKey,
                shareID: shareID,
                tlsIdentity: initialIdentity
            )
            try server.start()
            return server
        }
        let savedShareURL = try await waitForShareURL(firstServer)
        let firstClient = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: savedShareURL, accessKey: accessKey)
        )
        let firstCapabilities = try await firstClient.capabilities()
        XCTAssertEqual(firstCapabilities.shareID, shareID)

        await MainActor.run { firstServer.stop() }
        try await waitForShareToStop(firstServer)

        // Reissue a new self-signed certificate from the persisted per-share
        // private key. The old saved link must still authenticate it.
        let reissuedIdentity = try GhostFileTLSIdentity.make(
            privateKeyRepresentation: storedPrivateKey
        )
        XCTAssertNotEqual(initialIdentity.certificatePEM, reissuedIdentity.certificatePEM)
        XCTAssertEqual(initialIdentity.publicKeyPin, reissuedIdentity.publicKeyPin)
        let savedPort = try XCTUnwrap(savedShareURL.port).magnitude
        let secondServer = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "PersistentIdentityTest",
                accessKey: accessKey,
                shareID: shareID,
                tlsIdentity: reissuedIdentity
            )
            try server.start(preferredPort: UInt16(savedPort))
            return server
        }
        defer { Task { @MainActor in secondServer.stop() } }
        _ = try await waitForShareURL(secondServer)

        let reconnectedClient = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: savedShareURL, accessKey: accessKey)
        )
        let reconnectedCapabilities = try await reconnectedClient.capabilities()
        XCTAssertEqual(reconnectedCapabilities.shareID, shareID)
    }

    func testClientReconnectsAfterHTTP3ConnectionLoss() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-reconnect-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("reconnected".utf8).write(to: fixture.appendingPathComponent("hello.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "reconnect-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "ReconnectTest",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        let client = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey)
        )
        _ = try await client.capabilities()

        await client.invalidateTransportForTesting()

        let metadata = try await client.metadata(path: "hello.txt")
        let contents = try await client.read(path: "hello.txt", offset: 0, length: 64)
        XCTAssertEqual(metadata.size, UInt64(contents.count))
        XCTAssertEqual(contents, Data("reconnected".utf8))
    }

    func testTimedOutStreamDoesNotReplaceHTTP3Connection() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-timeout-retry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("fresh connection".utf8).write(to: fixture.appendingPathComponent("hello.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let delay = GhostFileOneShotRequestDelay()
        let accessKey = "timeout-retry-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "TimeoutRetryTest",
                accessKey: accessKey,
                requestDelay: { request in
                    guard request.operation == "metadata", request.path == "hello.txt",
                          await delay.consume() else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        let client = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey),
            connectionTimeout: .seconds(2),
            requestTimeout: .milliseconds(150)
        )

        let initialTransport = await client.transportLogIDForTesting()
        let originalTransport = try XCTUnwrap(initialTransport)
        do {
            _ = try await client.metadata(path: "hello.txt")
            XCTFail("The delayed request unexpectedly completed before its deadline")
        } catch {}
        let firstInvocationCount = await delay.invocationCount
        let transportAfterTimeout = await client.transportLogIDForTesting()
        XCTAssertEqual(firstInvocationCount, 1, "A stream timeout retried the request automatically")
        XCTAssertEqual(
            transportAfterTimeout,
            originalTransport,
            "A stream timeout replaced the entire QUIC connection"
        )

        let metadata = try await client.metadata(path: "hello.txt")
        XCTAssertEqual(metadata.size, UInt64(Data("fresh connection".utf8).count))
        let invocationCount = await delay.invocationCount
        let finalTransport = await client.transportLogIDForTesting()
        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(finalTransport, originalTransport)
    }

    func testUnresponsiveQUICPeerFailsWithinConnectionDeadline() async throws {
        let queue = DispatchQueue(label: "org.ghostvm.ghostfile.tests.silent-udp")
        let listener = try NWListener(using: .udp, on: .any)
        let ready = expectation(description: "silent UDP listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            // Accept UDP datagrams but intentionally never answer the QUIC handshake.
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)
        guard let port = listener.port else { throw TestError.missingShareURL }

        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: "deadline-test",
            publicKeyPin: "not-a-real-pin",
            resourceBasePath: "/v1/shares/00000000-0000-0000-0000-000000000001",
            connectionTimeout: .milliseconds(250),
            requestTimeout: .seconds(1)
        )

        let clock = ContinuousClock()
        let started = clock.now
        do {
            _ = try await transport.request(
                operation: "capabilities",
                relativePath: nil,
                offset: nil,
                length: nil
            )
            XCTFail("An unresponsive QUIC peer unexpectedly completed a request")
        } catch {
            XCTAssertLessThan(started.duration(to: clock.now), .seconds(2))
        }
    }

    func testCancellingRequestDuringQUICHandshakeFinishesPromptly() async throws {
        let queue = DispatchQueue(label: "org.ghostvm.ghostfile.tests.cancel-handshake-udp")
        let listener = try NWListener(using: .udp, on: .any)
        let ready = expectation(description: "silent UDP listener ready")
        let receivedInitialDatagram = expectation(description: "silent peer received initial QUIC datagram")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            // A UDP listener creates this flow only after the client's first
            // datagram arrives. Keep the peer silent so the QUIC handshake
            // remains pending at a deterministic cancellation point.
            receivedInitialDatagram.fulfill()
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 2)
        guard let port = listener.port else { throw TestError.missingShareURL }

        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: "cancel-handshake-test",
            publicKeyPin: "not-a-real-pin",
            resourceBasePath: "/v1/shares/00000000-0000-0000-0000-000000000001",
            connectionTimeout: .seconds(10),
            requestTimeout: .seconds(10)
        )

        let completed = expectation(description: "handshake-waiting request completed after cancellation")
        let requestTask = Task { () -> GhostFileCancellationOutcome in
            defer { completed.fulfill() }
            do {
                _ = try await transport.request(
                    operation: "capabilities",
                    relativePath: nil,
                    offset: nil,
                    length: nil
                )
                return .succeeded
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(String(describing: error))
            }
        }

        await fulfillment(of: [receivedInitialDatagram], timeout: 2)
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        requestTask.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
        let cancellationLatency = cancelledAt.duration(to: clock.now)

        // Unblock the deliberately broken implementation after the timeout
        // assertion so the test never waits for the ten-second deadline.
        await transport.invalidateForTesting()
        let outcome = await requestTask.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(
            cancellationLatency,
            .milliseconds(500),
            "Caller cancellation remained stuck in QUIC handshake readiness"
        )
    }

    func testSmallFileInlineCacheExpiresAndRefreshes() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let fileURL = fixture.appendingPathComponent("tiny.txt")
        try Data("before".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "quic-cache-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileCacheIntegration",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        let client = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey)
        )
        let listing = try await client.directory(path: "")
        XCTAssertEqual(listing.inlineContents?.first(where: { $0.name == "tiny.txt" })?.data, Data("before".utf8))

        try Data("after!".utf8).write(to: fileURL, options: .atomic)
        let cachedContents = try await client.read(path: "tiny.txt", offset: 0, length: 64)
        XCTAssertEqual(cachedContents, Data("before".utf8))

        try await Task.sleep(for: .milliseconds(5_100))
        let refreshed = try await client.metadata(path: "tiny.txt")
        XCTAssertEqual(refreshed.size, 6)
        let refreshedContents = try await client.read(path: "tiny.txt", offset: 0, length: 64)
        XCTAssertEqual(refreshedContents, Data("after!".utf8))
    }

    func testZeroCacheTTLReadsAtomicHostReplacementImmediately() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-live-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let fileURL = fixture.appendingPathComponent("live.txt")
        try Data("before".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "quic-live-cache-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileLiveCacheIntegration",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        var components = try XCTUnwrap(URLComponents(
            url: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey),
            resolvingAgainstBaseURL: false
        ))
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: GhostFileProtocol.cacheTTLQueryName, value: "0"))
        components.queryItems = queryItems
        let client = try GhostFileHTTP3Client(resourceURL: try XCTUnwrap(components.url))

        let initialContents = try await client.read(path: "live.txt", offset: 0, length: 64)
        XCTAssertEqual(initialContents, Data("before".utf8))
        try Data("after!".utf8).write(to: fileURL, options: .atomic)
        let replacedContents = try await client.read(path: "live.txt", offset: 0, length: 64)
        XCTAssertEqual(replacedContents, Data("after!".utf8))
    }

    func testDesktopSizedDirectoryListingCompletesOnOneHTTP3Connection() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-large-directory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        // The real Desktop failure returned roughly 22 KiB. Use enough long
        // directory names to force the response across multiple UDP send
        // batches without introducing file-content I/O into this test.
        for index in 0..<128 {
            let name = String(format: "%03d-%@", index, String(repeating: "directory-entry-", count: 5))
            try FileManager.default.createDirectory(
                at: fixture.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let accessKey = "large-directory-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "LargeDirectoryTest",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        let client = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey),
            connectionTimeout: .seconds(2),
            requestTimeout: .seconds(2)
        )
        let initialTransport = await client.transportLogIDForTesting()
        let originalTransport = try XCTUnwrap(initialTransport)
        let started = ContinuousClock.now
        let listing = try await client.directory(path: "")
        let elapsed = started.duration(to: .now)
        let finalTransport = await client.transportLogIDForTesting()

        XCTAssertEqual(listing.entries.count, 128)
        XCTAssertEqual(finalTransport, originalTransport)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testDesktopSizedDirectoryListingSurvivesMinimumQUICPathMTU() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-minimum-pmtu-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        for index in 0..<128 {
            let name = String(format: "%03d-%@", index, String(repeating: "directory-entry-", count: 5))
            try FileManager.default.createDirectory(
                at: fixture.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
        }

        let accessKey = "minimum-pmtu-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "MinimumPMTUTest",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForLoopbackShareURL(server)
        guard let serverPortValue = shareURL.port,
              let serverPort = NWEndpoint.Port(rawValue: UInt16(serverPortValue)),
              var components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false) else {
            throw TestError.missingShareURL
        }
        let proxy = try GhostFilePathMTUProxy(upstreamPort: serverPort, maximumDatagramSize: 1_200)
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        components.host = "127.0.0.1"
        components.port = Int(proxyPort.rawValue)
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "access_key", value: accessKey)
        ]
        let resourceURL = try XCTUnwrap(components.url)
        let client = try GhostFileHTTP3Client(
            resourceURL: resourceURL,
            connectionTimeout: .seconds(2),
            requestTimeout: .seconds(2)
        )

        let listing = try await client.directory(path: "")
        XCTAssertEqual(listing.entries.count, 128)
        XCTAssertGreaterThan(proxy.droppedDatagramCount, 0, "The PMTU proxy did not reject a probe")
    }

    func testBulkTransferBenchmarkWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GHOSTFILE_RUN_BULK_BENCHMARK"] == "1" else {
            throw XCTSkip("Set GHOSTFILE_RUN_BULK_BENCHMARK=1 to run the HTTP/3 bulk benchmark")
        }
        guard let fixturePath = environment["GHOSTFILE_BENCHMARK_FILE"] else {
            throw XCTSkip("Set GHOSTFILE_BENCHMARK_FILE to the source fixture path")
        }

        let fixtureURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
        let payload = try Data(contentsOf: fixtureURL, options: .mappedIfSafe)
        let accessKey = "quic-bulk-benchmark-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixtureURL.deletingLastPathComponent(),
                shareName: "GhostFileHTTP3BulkBenchmark",
                accessKey: accessKey
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        let resourceURL = try loopbackResourceURL(
            shareURL: shareURL,
            accessKey: accessKey
        )
        let client = try GhostFileHTTP3Client(resourceURL: resourceURL)
        let relativePath = fixtureURL.lastPathComponent
        let chunkSize = GhostFileProtocol.maximumReadLength
        let chunks = stride(from: 0, to: payload.count, by: chunkSize).map { offset in
            (offset: offset, length: min(chunkSize, payload.count - offset))
        }

        // Establish the connection before either timed transfer.
        _ = try await client.read(path: relativePath, offset: 0, length: 1)

        let sequential = try await timedTransfer {
            var responses: [(Int, Data)] = []
            responses.reserveCapacity(chunks.count)
            for chunk in chunks {
                let data = try await client.read(
                    path: relativePath,
                    offset: UInt64(chunk.offset),
                    length: chunk.length
                )
                responses.append((chunk.offset, data))
            }
            return responses
        }
        try verify(sequential.result, against: payload)

        let parallel = try await timedTransfer {
            var responses: [(Int, Data)] = []
            responses.reserveCapacity(chunks.count)
            for batchStart in stride(from: 0, to: chunks.count, by: 16) {
                let batchEnd = min(batchStart + 16, chunks.count)
                try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for chunk in chunks[batchStart..<batchEnd] {
                        group.addTask {
                            let data = try await client.read(
                                path: relativePath,
                                offset: UInt64(chunk.offset),
                                length: chunk.length
                            )
                            return (chunk.offset, data)
                        }
                    }
                    for try await response in group {
                        responses.append(response)
                    }
                }
            }
            return responses
        }
        try verify(parallel.result, against: payload)

        printBenchmark("direct HTTP/3 sequential", bytes: payload.count, seconds: sequential.seconds)
        printBenchmark("direct HTTP/3 16-stream", bytes: payload.count, seconds: parallel.seconds)
    }

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
                  let pin = components.queryItems?.first(where: { $0.name == "pk" })?.value else {
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

    func testTimedOutRequestDoesNotPoisonSiblingHTTP3Streams() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-quic-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("still responsive".utf8).write(to: fixture.appendingPathComponent("hello.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let accessKey = "quic-timeout-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileHTTP3Timeout",
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
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForShareURL(server)
        guard let portNumber = shareURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
              let pin = components.queryItems?.first(where: { $0.name == "pk" })?.value else {
            throw TestError.missingShareURL
        }
        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: accessKey,
            publicKeyPin: pin,
            resourceBasePath: shareURL.path,
            connectionTimeout: .seconds(2),
            requestTimeout: .milliseconds(250)
        )

        do {
            _ = try await transport.request(
                operation: "metadata",
                relativePath: "slow.txt",
                offset: nil,
                length: nil
            )
            XCTFail("The deliberately stalled request unexpectedly completed")
        } catch {}

        let response = try await transport.request(
            operation: "metadata",
            relativePath: "hello.txt",
            offset: nil,
            length: nil
        )
        XCTAssertEqual(response.status, 200)
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
        let resourceURL = try loopbackResourceURL(shareURL: shareURL, accessKey: accessKey)
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

    func testRequestsWaitForHTTP3StreamCreditInsteadOfFailing() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-quic-stream-credit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("stream credit".utf8).write(to: fixture.appendingPathComponent("hello.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let gate = GhostFileRequestGate()
        let accessKey = "quic-stream-credit-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileHTTP3StreamCredit-\(UUID().uuidString)",
                accessKey: accessKey,
                requestDelay: { request in
                    guard request.operation == "metadata" else { return }
                    await gate.wait()
                }
            )
            try server.start()
            return server
        }
        defer { Task { @MainActor in server.stop() } }

        let shareURL = try await waitForLoopbackShareURL(server)
        guard let portNumber = shareURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
              let pin = components.queryItems?.first(where: { $0.name == "pk" })?.value else {
            throw TestError.missingShareURL
        }
        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: accessKey,
            publicKeyPin: pin,
            resourceBasePath: shareURL.path,
            requestTimeout: .seconds(5)
        )

        _ = try await transport.request(
            operation: "capabilities",
            relativePath: nil,
            offset: nil,
            length: nil
        )

        let release = Task {
            try await Task.sleep(for: .milliseconds(250))
            await gate.open()
        }
        defer { release.cancel() }

        let results = await withTaskGroup(of: Result<Int, Error>.self) { group in
            for _ in 0..<80 {
                group.addTask {
                    do {
                        return .success(try await transport.request(
                            operation: "metadata",
                            relativePath: "hello.txt",
                            offset: nil,
                            length: nil
                        ).status)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        let statuses = results.compactMap { try? $0.get() }
        let failures = results.compactMap { result -> String? in
            guard case .failure(let error) = result else { return nil }
            return String(describing: error)
        }
        XCTAssertEqual(failures, [], "Requests failed instead of waiting for HTTP/3 stream credit")
        XCTAssertEqual(statuses.count, 80)
        XCTAssertTrue(statuses.allSatisfy { $0 == 200 })
    }

    func testCancellingOpenedRequestFinishesPromptly() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-quic-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("cancel me".utf8).write(to: fixture.appendingPathComponent("cancel.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let gate = GhostFileRequestGate()
        let accessKey = "quic-cancellation-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileHTTP3Cancellation-\(UUID().uuidString)",
                accessKey: accessKey,
                requestDelay: { request in
                    guard request.operation == "metadata", request.path == "cancel.txt" else { return }
                    await gate.wait()
                }
            )
            try server.start()
            return server
        }
        defer {
            Task {
                await gate.open()
                await MainActor.run { server.stop() }
            }
        }

        let shareURL = try await waitForLoopbackShareURL(server)
        guard let portNumber = shareURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
              let pin = components.queryItems?.first(where: { $0.name == "pk" })?.value else {
            throw TestError.missingShareURL
        }
        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: accessKey,
            publicKeyPin: pin,
            resourceBasePath: shareURL.path,
            requestTimeout: .seconds(10)
        )

        let completed = expectation(description: "cancelled HTTP/3 request completed")
        let requestTask = Task { () -> GhostFileCancellationOutcome in
            defer { completed.fulfill() }
            do {
                _ = try await transport.request(
                    operation: "metadata",
                    relativePath: "cancel.txt",
                    offset: nil,
                    length: nil
                )
                return .succeeded
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(String(describing: error))
            }
        }

        await gate.waitForArrival()
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        requestTask.cancel()
        await fulfillment(of: [completed], timeout: 0.5)
        let cancellationLatency = cancelledAt.duration(to: clock.now)

        // Always release the server barrier so a broken implementation can
        // drain cleanly after the timeout assertion instead of leaking a task.
        await gate.open()
        let outcome = await requestTask.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(
            cancellationLatency,
            .milliseconds(500),
            "Caller cancellation waited for the HTTP/3 response or request deadline"
        )
    }

    func testCancellingOpenedRequestCancelsServerRoutingWithoutBlockingSibling() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-quic-server-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("cancel me".utf8).write(to: fixture.appendingPathComponent("cancel.txt"))
        try Data("still responsive".utf8).write(to: fixture.appendingPathComponent("sibling.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let gate = GhostFileRequestGate()
        let serverRoutingCancelled = expectation(description: "server routing task cancelled after peer reset")
        let accessKey = "quic-server-cancellation-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileHTTP3ServerCancellation-\(UUID().uuidString)",
                accessKey: accessKey,
                requestDelay: { request in
                    guard request.operation == "metadata", request.path == "cancel.txt" else { return }
                    await withTaskCancellationHandler {
                        await gate.wait()
                    } onCancel: {
                        serverRoutingCancelled.fulfill()
                    }
                }
            )
            try server.start()
            return server
        }
        defer {
            Task {
                await gate.open()
                await MainActor.run { server.stop() }
            }
        }

        let shareURL = try await waitForLoopbackShareURL(server)
        guard let portNumber = shareURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
              let pin = components.queryItems?.first(where: { $0.name == "pk" })?.value else {
            throw TestError.missingShareURL
        }
        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: accessKey,
            publicKeyPin: pin,
            resourceBasePath: shareURL.path
        )

        let slowRequest = Task { () -> GhostFileCancellationOutcome in
            do {
                _ = try await transport.request(
                    operation: "metadata",
                    relativePath: "cancel.txt",
                    offset: nil,
                    length: nil
                )
                return .succeeded
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(String(describing: error))
            }
        }

        await gate.waitForArrival()
        slowRequest.cancel()
        let slowOutcome = await slowRequest.value
        XCTAssertEqual(slowOutcome, .cancelled)

        let sibling = try await transport.request(
            operation: "metadata",
            relativePath: "sibling.txt",
            offset: nil,
            length: nil
        )
        XCTAssertEqual(sibling.status, 200)

        await fulfillment(of: [serverRoutingCancelled], timeout: 0.5)
        await gate.open()
    }

    func testStoppingShareNotifiesInFlightHTTP3RequestBeforeItsDeadline() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-quic-share-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try Data("stop me".utf8).write(to: fixture.appendingPathComponent("stop.txt"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let gate = GhostFileRequestGate()
        let accessKey = "quic-share-stop-key"
        let server = try await MainActor.run {
            let server = GhostFileShareServer(
                rootURL: fixture,
                shareName: "GhostFileHTTP3ShareStop-\(UUID().uuidString)",
                accessKey: accessKey,
                requestDelay: { request in
                    guard request.operation == "metadata", request.path == "stop.txt" else { return }
                    await gate.wait()
                }
            )
            try server.start()
            return server
        }
        defer {
            Task {
                await gate.open()
                await MainActor.run { server.stop() }
            }
        }

        let shareURL = try await waitForLoopbackShareURL(server)
        let client = try GhostFileHTTP3Client(
            resourceURL: loopbackResourceURL(shareURL: shareURL, accessKey: accessKey),
            connectionTimeout: .seconds(2),
            requestTimeout: .seconds(4)
        )

        let request = Task { () -> GhostFileCancellationOutcome in
            do {
                _ = try await client.metadata(path: "stop.txt")
                return .succeeded
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(String(describing: error))
            }
        }

        await gate.waitForArrival()
        let clock = ContinuousClock()
        let stoppedAt = clock.now
        await MainActor.run { server.stop() }
        let outcome = await request.value
        let elapsed = stoppedAt.duration(to: clock.now)

        await gate.open()
        guard case .failed = outcome else {
            return XCTFail("An in-flight request unexpectedly survived share shutdown: \(outcome)")
        }
        XCTAssertLessThan(
            elapsed,
            .seconds(3),
            "The client learned about share shutdown only from its request deadline"
        )
    }

    private enum TestError: Error {
        case missingShareURL
        case shareDidNotStop
        case responseMismatch
    }

    private func loopbackResourceURL(shareURL: URL, accessKey: String) throws -> URL {
        guard var components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false) else {
            throw TestError.missingShareURL
        }
        components.host = "127.0.0.1"
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "access_key", value: accessKey)
        ]
        guard let url = components.url else { throw TestError.missingShareURL }
        return url
    }

    private func timedTransfer<Result>(
        _ operation: () async throws -> Result
    ) async rethrows -> (seconds: Double, result: Result) {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await operation()
        let elapsed = started.duration(to: clock.now)
        let components = elapsed.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return (seconds, result)
    }

    private func verify(_ responses: [(Int, Data)], against payload: Data) throws {
        var expectedOffset = 0
        for (offset, data) in responses.sorted(by: { $0.0 < $1.0 }) {
            guard offset == expectedOffset, offset + data.count <= payload.count else {
                throw TestError.responseMismatch
            }
            guard payload[offset..<(offset + data.count)].elementsEqual(data) else {
                throw TestError.responseMismatch
            }
            expectedOffset += data.count
        }
        guard expectedOffset == payload.count else {
            throw TestError.responseMismatch
        }
    }

    private func printBenchmark(_ label: String, bytes: Int, seconds: Double) {
        let throughput = Double(bytes) / seconds / (1024 * 1024)
        print("GHOSTFILE_BENCHMARK \(label): \(String(format: "%.1f", throughput)) MiB/s " +
              "(\(String(format: "%.3f", seconds)) s)")
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

    private func waitForLoopbackShareURL(_ server: GhostFileShareServer) async throws -> URL {
        for _ in 0..<200 {
            if let url = await MainActor.run(body: { server.loopbackShareURLForTesting }) {
                return url
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.missingShareURL
    }

    private func waitForShareToStop(_ server: GhostFileShareServer) async throws {
        for _ in 0..<500 {
            let stopped = await MainActor.run { !server.isRunning && server.port == 0 }
            if stopped { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestError.shareDidNotStop
    }
}

private actor GhostFileOneShotRequestDelay {
    private(set) var invocationCount = 0
    private var shouldDelay = true

    func consume() -> Bool {
        invocationCount += 1
        defer { shouldDelay = false }
        return shouldDelay
    }
}

private actor GhostFileRequestGate {
    private var isOpen = false
    private var hasArrival = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if !hasArrival {
            hasArrival = true
            let currentArrivalWaiters = arrivalWaiters
            arrivalWaiters.removeAll()
            currentArrivalWaiters.forEach { $0.resume() }
        }
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrival() async {
        guard !hasArrival else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private enum GhostFileCancellationOutcome: Equatable {
    case succeeded
    case cancelled
    case failed(String)
}

private final class GhostFilePathMTUProxy: @unchecked Sendable {
    private let upstreamPort: NWEndpoint.Port
    private let maximumDatagramSize: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.ghostvm.ghostfile.tests.pmtu-proxy")
    private let lock = NSLock()
    private var downstream: NWConnection?
    private var upstream: NWConnection?
    private var dropped = 0

    init(upstreamPort: NWEndpoint.Port, maximumDatagramSize: Int) throws {
        self.upstreamPort = upstreamPort
        self.maximumDatagramSize = maximumDatagramSize
        listener = try NWListener(using: .udp, on: .any)
    }

    var droppedDatagramCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            let completion = GhostFileProxyStartCompletion(continuation: continuation)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port {
                        completion.succeed(port)
                    }
                case .failed(let error):
                    completion.fail(error)
                case .cancelled:
                    completion.fail(CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock()
        let downstream = self.downstream
        let upstream = self.upstream
        self.downstream = nil
        self.upstream = nil
        lock.unlock()
        downstream?.cancel()
        upstream?.cancel()
    }

    private func accept(_ downstream: NWConnection) {
        let upstream = NWConnection(host: "127.0.0.1", port: upstreamPort, using: .udp)
        lock.lock()
        guard self.downstream == nil else {
            lock.unlock()
            downstream.cancel()
            return
        }
        self.downstream = downstream
        self.upstream = upstream
        lock.unlock()

        downstream.start(queue: queue)
        upstream.start(queue: queue)
        forward(from: downstream, to: upstream)
        forward(from: upstream, to: downstream)
    }

    private func forward(from source: NWConnection, to destination: NWConnection) {
        source.receiveMessage { [weak self, weak source, weak destination] content, _, _, error in
            guard let self, let source, let destination, error == nil, let content else { return }
            if content.count <= self.maximumDatagramSize {
                destination.send(content: content, completion: .contentProcessed { _ in })
            } else {
                self.lock.lock()
                self.dropped += 1
                self.lock.unlock()
            }
            self.forward(from: source, to: destination)
        }
    }
}

private final class GhostFileProxyStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint.Port, Error>?

    init(continuation: CheckedContinuation<NWEndpoint.Port, Error>) {
        self.continuation = continuation
    }

    func succeed(_ port: NWEndpoint.Port) {
        complete(.success(port))
    }

    func fail(_ error: Error) {
        complete(.failure(error))
    }

    private func complete(_ result: Result<NWEndpoint.Port, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
