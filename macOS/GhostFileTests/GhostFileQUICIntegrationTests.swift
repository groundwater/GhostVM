import Foundation
import Network
import XCTest
@testable import GhostFile

final class GhostFileHTTP3IntegrationTests: XCTestCase {
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
            resourceBasePath: "/v1/shares/00000000-0000-0000-0000-000000000001"
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
        // assertion instead of waiting for the QUIC idle timeout.
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
              let pin = components.queryItems?.first(where: { $0.name == "tls_pin" })?.value else {
            throw TestError.missingShareURL
        }
        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: accessKey,
            publicKeyPin: pin,
            resourceBasePath: shareURL.path
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

        let shareURL = try await waitForShareURL(server)
        guard let portNumber = shareURL.port,
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)),
              let components = URLComponents(url: shareURL, resolvingAgainstBaseURL: false),
              let pin = components.queryItems?.first(where: { $0.name == "tls_pin" })?.value else {
            throw TestError.missingShareURL
        }
        let transport = try GhostFileHTTP3Transport(
            host: "127.0.0.1",
            port: port,
            accessKey: accessKey,
            publicKeyPin: pin,
            resourceBasePath: shareURL.path
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

        await gate.open()
        let outcome = await requestTask.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(cancellationLatency, .milliseconds(500))
    }

    private enum TestError: Error {
        case missingShareURL
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
