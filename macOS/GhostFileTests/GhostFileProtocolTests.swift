import Combine
import Foundation
import GhostHTTP
import XCTest
@testable import GhostFile
@testable import GhostFileKit

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

final class GhostFileMountHealthTests: XCTestCase {
    private let mountID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testHeartbeatSilenceOnlyDegradesHealthyMount() {
        let initial = snapshot(state: .online)
        XCTAssertEqual(initial.applying(.heartbeatMissed).state, .degraded)

        let errored = initial.applying(.operationFailed, detail: "timed out")
        XCTAssertEqual(errored.applying(.heartbeatMissed).state, .error)

        let offline = initial.applying(.peerClosed)
        XCTAssertEqual(offline.applying(.heartbeatMissed).state, .offline)
    }

    func testRealOperationFailureAndExplicitCloseRemainDistinct() {
        let initial = snapshot(state: .online)
        XCTAssertEqual(initial.applying(.operationFailed).state, .error)
        XCTAssertEqual(initial.applying(.peerClosed).state, .offline)
    }

    func testSuccessfulTrafficRestoresOnlineState() {
        XCTAssertEqual(snapshot(state: .degraded).applying(.heartbeatSucceeded).state, .online)
        XCTAssertEqual(snapshot(state: .error).applying(.operationSucceeded).state, .online)
        XCTAssertEqual(snapshot(state: .offline).applying(.heartbeatSucceeded).state, .online)
    }

    func testStaleOnlineSnapshotBecomesDegradedButNeverOffline() {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let initial = GhostFileMountHealthSnapshot(
            mountID: mountID,
            state: .online,
            detail: nil,
            updatedAt: updatedAt
        )
        XCTAssertEqual(
            initial.degradingIfStale(
                at: updatedAt.addingTimeInterval(GhostFileProtocol.heartbeatStaleAfter + 1)
            ).state,
            .degraded
        )
    }

    private func snapshot(state: GhostFileMountHealthState) -> GhostFileMountHealthSnapshot {
        GhostFileMountHealthSnapshot(
            mountID: mountID,
            state: state,
            detail: nil,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}

final class GhostFileBonjourLeaseTests: XCTestCase {
    func testDiscoveredShareProvidesStableDisplayMetadataAndWindowValue() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let share = DiscoveredGhostFileShare(
            id: id,
            name: "Studio Mac",
            host: "studio.local",
            port: 8049,
            readOnly: true,
            transport: GhostFileProtocol.transport,
            publicKeyPin: "test-pin"
        )

        XCTAssertEqual(share.serviceType, "_ghostfile._udp")
        XCTAssertEqual(share.url?.host, "studio.local")
        XCTAssertEqual(share.url?.port, 8049)
        XCTAssertTrue(try XCTUnwrap(share.url?.absoluteString).contains(id.uuidString))

        let encoded = try JSONEncoder().encode(share)
        XCTAssertEqual(try JSONDecoder().decode(DiscoveredGhostFileShare.self, from: encoded), share)
    }

    func testDiscoveryVisibilityHidesSelfSharesUnlessEnabled() {
        let localID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let remoteID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let shares = [
            DiscoveredGhostFileShare(
                id: localID,
                name: "This Mac",
                host: "this-mac.local",
                port: 8049,
                readOnly: true,
                transport: GhostFileProtocol.transport,
                publicKeyPin: "local-pin"
            ),
            DiscoveredGhostFileShare(
                id: remoteID,
                name: "Nearby Mac",
                host: "nearby.local",
                port: 8050,
                readOnly: true,
                transport: GhostFileProtocol.transport,
                publicKeyPin: "remote-pin"
            )
        ]

        XCTAssertEqual(
            GhostFileDiscoveryVisibility.visibleShares(
                from: shares,
                localShareIDs: [localID],
                discoverSelfShares: false
            ).map(\.id),
            [remoteID]
        )
        XCTAssertEqual(
            GhostFileDiscoveryVisibility.visibleShares(
                from: shares,
                localShareIDs: [localID],
                discoverSelfShares: true
            ),
            shares
        )
    }

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
        let ttl = GhostFileBonjourLease.advertisedTTL
        XCTAssertFalse(GhostFileBonjourLease.isExpired(
            lastSeen: lastSeen,
            ttl: ttl,
            now: lastSeen.addingTimeInterval(ttl - 0.001)
        ))
        XCTAssertTrue(GhostFileBonjourLease.isExpired(
            lastSeen: lastSeen,
            ttl: ttl,
            now: lastSeen.addingTimeInterval(ttl)
        ))
    }
}

@MainActor
final class GhostFileLibraryTests: XCTestCase {
    func testShareDefinitionRejectsEmptyAccessKey() throws {
        let library = GhostFileLibrary(
            configurationStorage: MemoryConfigurationStorage(),
            accessKeyStorage: MemoryAccessKeyStorage(),
            tlsPrivateKeyStorage: MemoryTLSPrivateKeyStorage()
        )
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-empty-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertThrowsError(try library.addShare(
            folderURL: folder,
            name: "Invalid",
            accessKey: "   "
        ))
        XCTAssertTrue(library.shares.isEmpty)
    }

    func testSharesPersistWithStableIdentityAndDeleteCleanly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-library-tests-\(UUID().uuidString)", isDirectory: true)
        let sharedFolder = root.appendingPathComponent("Shared Folder", isDirectory: true)
        let storageURL = root.appendingPathComponent("shares.json")
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configurationStorage = GhostFileShareJSONStorage(fileURL: storageURL)
        let keyStorage = MemoryAccessKeyStorage()
        let identityStorage = MemoryTLSPrivateKeyStorage()
        let library = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage
        )
        let saved = try library.addShare(
            folderURL: sharedFolder,
            name: "Test Share",
            preferredPort: 8049,
            accessKey: "test-key"
        )

        let reloaded = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage
        )
        XCTAssertEqual(reloaded.shares.map(\.id), [saved.id])
        XCTAssertEqual(reloaded.shares.first?.name, "Test Share")
        XCTAssertEqual(reloaded.shares.first?.preferredPort, 8049)
        XCTAssertEqual(try keyStorage.accessKey(for: saved.id), "test-key")
        XCTAssertEqual(
            try library.publicKeyPin(for: saved.id),
            try reloaded.publicKeyPin(for: saved.id)
        )

        reloaded.delete([saved.id])

        let afterDelete = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage
        )
        XCTAssertTrue(afterDelete.shares.isEmpty)
        XCTAssertNil(try keyStorage.accessKey(for: saved.id))
        XCTAssertNil(try identityStorage.privateKey(for: saved.id))
    }

    func testStartAndStopUseSavedShareIDAndPublishLiveStatus() throws {
        let sharedFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-runtime-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sharedFolder) }

        let configurationStorage = MemoryConfigurationStorage()
        let keyStorage = MemoryAccessKeyStorage()
        let identityStorage = MemoryTLSPrivateKeyStorage()
        var runtimes: [UUID: FakeShareRuntime] = [:]
        var observedIdentityPins: [String] = []
        let library = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage,
            serverFactory: { share, _, _, identity in
                let runtime = FakeShareRuntime()
                runtimes[share.id] = runtime
                observedIdentityPins.append(identity.publicKeyPin)
                return runtime
            }
        )
        let saved = try library.addShare(
            folderURL: sharedFolder,
            name: "Runtime Test",
            accessKey: "runtime-key"
        )

        XCTAssertEqual(library.status(for: saved.id), .stopped)
        library.start(saved.id)
        XCTAssertEqual(library.status(for: saved.id), .online)
        XCTAssertNotNil(runtimes[saved.id])
        XCTAssertEqual(runtimes[saved.id]?.preferredPort, saved.preferredPort)
        let firstRuntime = try XCTUnwrap(runtimes[saved.id])

        library.stop(saved.id)
        XCTAssertEqual(library.status(for: saved.id), .stopped)
        XCTAssertEqual(firstRuntime.stopCount, 1)

        library.start(saved.id)
        XCTAssertEqual(observedIdentityPins.count, 2)
        XCTAssertEqual(observedIdentityPins[0], observedIdentityPins[1])
    }

    func testExplicitIdentityRotationInvalidatesOldFingerprint() throws {
        let sharedFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-rotation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sharedFolder) }

        let library = GhostFileLibrary(
            configurationStorage: MemoryConfigurationStorage(),
            accessKeyStorage: MemoryAccessKeyStorage(),
            tlsPrivateKeyStorage: MemoryTLSPrivateKeyStorage()
        )
        let saved = try library.addShare(
            folderURL: sharedFolder,
            name: "Rotation Test",
            accessKey: "rotation-key"
        )
        let oldPin = try library.publicKeyPin(for: saved.id)

        library.rotateTLSIdentity(for: saved.id)

        XCTAssertNotEqual(try library.publicKeyPin(for: saved.id), oldPin)
    }

    func testReadOnlyChangePersistsAndUpdatesRunningServerImmediately() throws {
        let sharedFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-access-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sharedFolder) }

        let configurationStorage = MemoryConfigurationStorage()
        let keyStorage = MemoryAccessKeyStorage()
        let identityStorage = MemoryTLSPrivateKeyStorage()
        var runtime: FakeShareRuntime?
        let library = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage,
            serverFactory: { _, _, _, _ in
                let created = FakeShareRuntime()
                runtime = created
                return created
            }
        )
        let saved = try library.addShare(
            folderURL: sharedFolder,
            name: "Access Test",
            accessKey: "access-key"
        )
        library.start(saved.id)

        library.setReadOnly(false, for: saved.id)

        XCTAssertEqual(library.share(withID: saved.id)?.readOnly, false)
        XCTAssertEqual(runtime?.readOnlyValues, [false])
        let reloaded = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage
        )
        XCTAssertEqual(reloaded.share(withID: saved.id)?.readOnly, false)
    }

    func testEditingRunningShareRestartsWithUpdatedConfiguration() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-edit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let configurationStorage = MemoryConfigurationStorage()
        let keyStorage = MemoryAccessKeyStorage()
        let identityStorage = MemoryTLSPrivateKeyStorage()
        var runtimes: [FakeShareRuntime] = []
        let library = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage,
            serverFactory: { _, _, _, _ in
                let runtime = FakeShareRuntime()
                runtimes.append(runtime)
                return runtime
            }
        )
        let saved = try library.addShare(folderURL: folder, name: "Before", accessKey: "old-key")
        library.start(saved.id)

        try library.updateShare(
            saved.id,
            name: "After",
            preferredPort: 9000,
            accessKey: "new-key"
        )

        XCTAssertEqual(library.share(withID: saved.id)?.name, "After")
        XCTAssertEqual(library.share(withID: saved.id)?.preferredPort, 9000)
        XCTAssertEqual(try library.accessKey(for: saved.id), "new-key")
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertEqual(runtimes.first?.stopCount, 1)
        XCTAssertEqual(library.status(for: saved.id), .online)
    }

    func testFailedRunningShareEditRollsBackAndRestartsOriginal() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostfile-edit-rollback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let configurationStorage = MemoryConfigurationStorage()
        let keyStorage = MemoryAccessKeyStorage()
        let identityStorage = MemoryTLSPrivateKeyStorage()
        var runtimes: [FakeShareRuntime] = []
        let library = GhostFileLibrary(
            configurationStorage: configurationStorage,
            accessKeyStorage: keyStorage,
            tlsPrivateKeyStorage: identityStorage,
            serverFactory: { _, _, _, _ in
                let runtime = FakeShareRuntime()
                runtimes.append(runtime)
                return runtime
            }
        )
        let saved = try library.addShare(folderURL: folder, name: "Original", accessKey: "old-key")
        library.start(saved.id)
        configurationStorage.failSaves = true

        XCTAssertThrowsError(try library.updateShare(
            saved.id,
            name: "Should Roll Back",
            preferredPort: 9999,
            accessKey: "new-key"
        ))

        XCTAssertEqual(library.share(withID: saved.id)?.name, "Original")
        XCTAssertEqual(try library.accessKey(for: saved.id), "old-key")
        XCTAssertEqual(runtimes.count, 2)
        XCTAssertEqual(runtimes.first?.stopCount, 1)
        XCTAssertEqual(library.status(for: saved.id), .online)
    }
}

@MainActor
final class GhostFileMountLibraryTests: XCTestCase {
    func testMountDefinitionPersistsSanitizedURLAndKeySeparately() async throws {
        let storage = MemoryMountConfigurationStorage()
        let keys = MemoryAccessKeyStorage()
        let library = GhostFileMountLibrary(
            configurationStorage: storage,
            accessKeyStorage: keys
        )
        let shareID = UUID()
        let mountInstance = UUID()
        let saved = try library.addMount(
            name: "Build Cache",
            sourceURL: "ghostfile://build.local:8049/v1/shares/\(shareID.uuidString)?tls_pin=pin&access_key=secret&mount_instance=\(mountInstance.uuidString)",
            accessKey: "separate-key"
        )

        XCTAssertEqual(saved.shareID, shareID)
        XCTAssertFalse(saved.sourceURL.contains("access_key"))
        XCTAssertFalse(saved.sourceURL.contains("mount_instance"))
        XCTAssertTrue(saved.sourceURL.contains("tls_pin=pin"))
        XCTAssertEqual(try library.accessKey(for: saved.id), "separate-key")

        let reloaded = GhostFileMountLibrary(
            configurationStorage: storage,
            accessKeyStorage: keys
        )
        XCTAssertEqual(reloaded.mounts, [saved])

        await reloaded.delete([saved.id])
        XCTAssertTrue(reloaded.mounts.isEmpty)
        XCTAssertNil(try keys.accessKey(for: saved.id))
    }

    func testMountDefinitionRejectsNonGhostFileURL() {
        let library = GhostFileMountLibrary(
            configurationStorage: MemoryMountConfigurationStorage(),
            accessKeyStorage: MemoryAccessKeyStorage()
        )
        XCTAssertThrowsError(try library.addMount(
            name: "Invalid",
            sourceURL: "https://example.com/share",
            accessKey: "key"
        ))
    }

    func testMountDefinitionRejectsEmptyAccessKey() {
        let library = GhostFileMountLibrary(
            configurationStorage: MemoryMountConfigurationStorage(),
            accessKeyStorage: MemoryAccessKeyStorage()
        )
        XCTAssertThrowsError(try library.addMount(
            name: "Invalid",
            sourceURL: "ghostfile://example.local/v1/shares/\(UUID().uuidString)",
            accessKey: "   "
        ))
    }
}

private final class MemoryConfigurationStorage: GhostFileShareConfigurationStorage {
    private var savedShares: [SavedGhostFileShare] = []
    var failSaves = false

    func load() throws -> [SavedGhostFileShare] { savedShares }
    func save(_ shares: [SavedGhostFileShare]) throws {
        if failSaves { throw MemoryStorageError.saveFailed }
        savedShares = shares
    }
}

private final class MemoryMountConfigurationStorage: GhostFileMountConfigurationStorage {
    private var savedMounts: [SavedGhostFileMount] = []

    func load() throws -> [SavedGhostFileMount] { savedMounts }
    func save(_ mounts: [SavedGhostFileMount]) throws { savedMounts = mounts }
}

private enum MemoryStorageError: Error {
    case saveFailed
}

private final class MemoryAccessKeyStorage: GhostFileAccessKeyStorage {
    private var keys: [UUID: String] = [:]

    func accessKey(for shareID: UUID) throws -> String? { keys[shareID] }
    func setAccessKey(_ accessKey: String, for shareID: UUID) throws { keys[shareID] = accessKey }
    func removeAccessKey(for shareID: UUID) throws { keys[shareID] = nil }
}

private final class MemoryTLSPrivateKeyStorage: GhostFileTLSPrivateKeyStorage {
    private var keys: [UUID: Data] = [:]

    func privateKey(for shareID: UUID) throws -> Data? { keys[shareID] }
    func setPrivateKey(_ privateKey: Data, for shareID: UUID) throws { keys[shareID] = privateKey }
    func removePrivateKey(for shareID: UUID) throws { keys[shareID] = nil }
}

@MainActor
private final class FakeShareRuntime: ObservableObject, GhostFileShareRuntime {
    @Published var isRunning = false
    var shareURL: URL?
    var requestCount = 0
    var preferredPort: UInt16?
    var stopCount = 0
    var readOnlyValues: [Bool] = []

    func start(preferredPort: UInt16) throws {
        self.preferredPort = preferredPort
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    func setReadOnly(_ readOnly: Bool) {
        readOnlyValues.append(readOnly)
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

    func testCapabilitiesRequireAccessKey() async throws {
        let path = "\(GhostFileProtocol.shareBasePath(id: shareID))/capabilities"
        let unauthorized = await router.route(.init(method: .GET, path: path))
        XCTAssertEqual(unauthorized.status, .unauthorized)

        let authorized = await router.route(request(method: .GET, path: path))
        XCTAssertEqual(authorized.status, .ok)
        let capabilities = try JSONDecoder().decode(GhostFileCapabilities.self, from: bodyData(authorized))
        XCTAssertEqual(capabilities.shareID, shareID)
        XCTAssertTrue(capabilities.readOnly)
        XCTAssertEqual(capabilities.transports, [GhostFileProtocol.transport])
    }

    func testHealthIsAuthenticatedAndDoesNotTouchTheSharedFolder() async throws {
        let path = "\(GhostFileProtocol.shareBasePath(id: shareID))/health"
        let unauthorized = await router.route(.init(method: .GET, path: path))
        XCTAssertEqual(unauthorized.status, .unauthorized)

        let response = await router.route(request(method: .GET, path: path))
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(String(data: try bodyData(response), encoding: .utf8), "ok")
        XCTAssertEqual(response.headers["Cache-Control"], "no-store")
    }

    func testMetadataAndDirectoryListing() async throws {
        let metadataResponse = await router.route(request(
            method: .GET,
            path: operationPath("metadata", relativePath: "sample.txt")
        ))
        XCTAssertEqual(metadataResponse.status, .ok)
        let metadata = try JSONDecoder().decode(GhostFileMetadata.self, from: bodyData(metadataResponse))
        XCTAssertEqual(metadata.name, "sample.txt")
        XCTAssertEqual(metadata.type, .file)
        XCTAssertEqual(metadata.size, 10)

        let listingResponse = await router.route(request(
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

    func testDirectoryListingBoundsInlineContent() async throws {
        let oversized = Data(repeating: 0x41, count: GhostFileProtocol.maximumInlineFileLength + 1)
        try oversized.write(to: directory.appendingPathComponent("oversized.bin"))

        let listingResponse = await router.route(request(
            method: .GET,
            path: operationPath("directory", relativePath: "")
        ))
        XCTAssertEqual(listingResponse.status, .ok)
        let listing = try JSONDecoder().decode(GhostFileDirectoryListing.self, from: bodyData(listingResponse))
        XCTAssertTrue(listing.entries.contains(where: { $0.name == "oversized.bin" }))
        XCTAssertFalse(listing.inlineContents?.contains(where: { $0.name == "oversized.bin" }) ?? false)
    }

    func testRangeReadStreamsOnlyRequestedBytes() async throws {
        let response = await router.route(request(
            method: .GET,
            path: operationPath("content", relativePath: "sample.txt"),
            extraHeaders: ["Range": "bytes=2-5"]
        ))
        XCTAssertEqual(response.status, .partialContent)
        XCTAssertEqual(response.headers["Content-Range"], "bytes 2-5/10")
        XCTAssertEqual(String(data: try bodyData(response), encoding: .utf8), "cdef")
    }

    func testTraversalIsRejected() async {
        let response = await router.route(request(
            method: .GET,
            path: operationPath("metadata", relativePath: "../secret")
        ))
        XCTAssertEqual(response.status, .badRequest)
    }

    func testReadOnlyPolicyRejectsMutationAndCanChangeLive() async throws {
        let createPath = operationPath("create", relativePath: "created.txt")
        let payload = try JSONEncoder().encode(
            GhostFileCreateRequest(type: .file, mode: 0o640)
        )
        let rejectedCreate = await router.route(request(method: .POST, path: createPath), body: payload)
        XCTAssertEqual(rejectedCreate.status, .methodNotAllowed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("created.txt").path))

        router.setReadOnly(false)
        let capabilitiesPath = "\(GhostFileProtocol.shareBasePath(id: shareID))/capabilities"
        let capabilitiesResponse = await router.route(request(method: .GET, path: capabilitiesPath))
        let capabilities = try JSONDecoder().decode(
            GhostFileCapabilities.self,
            from: bodyData(capabilitiesResponse)
        )
        XCTAssertFalse(capabilities.readOnly)
        let acceptedCreate = await router.route(request(method: .POST, path: createPath), body: payload)
        XCTAssertEqual(acceptedCreate.status, .ok)
    }

    func testWritableMutationsCreateWriteResizeRenameSymlinkAndRemove() async throws {
        router.setReadOnly(false)

        let createDirectory = try JSONEncoder().encode(
            GhostFileCreateRequest(type: .directory, mode: 0o750)
        )
        let createDirectoryResponse = await router.route(
            request(method: .POST, path: operationPath("create", relativePath: "new")),
            body: createDirectory
        )
        XCTAssertEqual(createDirectoryResponse.status, .ok)

        let createFile = try JSONEncoder().encode(
            GhostFileCreateRequest(type: .file, mode: 0o640)
        )
        let createResponse = await router.route(
            request(method: .POST, path: operationPath("create", relativePath: "new/data.bin")),
            body: createFile
        )
        XCTAssertEqual(createResponse.status, .ok)
        let created = try JSONDecoder().decode(GhostFileMetadata.self, from: bodyData(createResponse))

        let writeResponse = await router.route(
            request(
                method: .PATCH,
                path: operationPath("content", relativePath: "new/data.bin"),
                extraHeaders: ["X-GhostFile-Offset": "3"]
            ),
            body: Data("hello".utf8)
        )
        XCTAssertEqual(writeResponse.status, .ok)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("new/data.bin")),
            Data([0, 0, 0]) + Data("hello".utf8)
        )

        let attributes = try JSONEncoder().encode(
            GhostFileSetAttributesRequest(mode: 0o600, size: 5)
        )
        let attributesResponse = await router.route(
            request(method: .PATCH, path: operationPath("attributes", relativePath: "new/data.bin")),
            body: attributes
        )
        XCTAssertEqual(attributesResponse.status, .ok)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("new/data.bin")),
            Data([0, 0, 0]) + Data("he".utf8)
        )

        let rename = try JSONEncoder().encode(
            GhostFileRenameRequest(destinationPath: "new/renamed.bin")
        )
        let renameResponse = await router.route(
            request(method: .POST, path: operationPath("rename", relativePath: "new/data.bin")),
            body: rename
        )
        XCTAssertEqual(renameResponse.status, .ok)
        let renamed = try JSONDecoder().decode(GhostFileMetadata.self, from: bodyData(renameResponse))
        XCTAssertEqual(renamed.objectID, created.objectID, "Renaming must preserve filesystem identity")

        let link = try JSONEncoder().encode(GhostFileSymbolicLinkRequest(destination: "renamed.bin"))
        let linkResponse = await router.route(
            request(method: .POST, path: operationPath("symlink", relativePath: "new/link")),
            body: link
        )
        XCTAssertEqual(linkResponse.status, .ok)
        let readLink = await router.route(request(
            method: .GET,
            path: operationPath("readlink", relativePath: "new/link")
        ))
        XCTAssertEqual(String(data: try bodyData(readLink), encoding: .utf8), "renamed.bin")

        let removeLink = await router.route(request(
            method: .DELETE,
            path: operationPath("remove", relativePath: "new/link")
        ))
        XCTAssertEqual(removeLink.status, .noContent)
        let removeFile = await router.route(request(
            method: .DELETE,
            path: operationPath("remove", relativePath: "new/renamed.bin")
        ))
        XCTAssertEqual(removeFile.status, .noContent)
        let removeDirectory = await router.route(request(
            method: .DELETE,
            path: operationPath("remove", relativePath: "new")
        ))
        XCTAssertEqual(removeDirectory.status, .noContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("new").path))
    }

    func testWritableMutationsRejectEscapingDestinationsAndConflicts() async throws {
        router.setReadOnly(false)
        let createFile = try JSONEncoder().encode(
            GhostFileCreateRequest(type: .file, mode: 0o600)
        )
        let existing = operationPath("create", relativePath: "sample.txt")
        let conflict = await router.route(request(method: .POST, path: existing), body: createFile)
        XCTAssertEqual(conflict.status, .conflict)
        XCTAssertEqual(
            try JSONDecoder().decode(GhostFileErrorPayload.self, from: bodyData(conflict)).errno,
            EEXIST
        )

        let escapingRename = try JSONEncoder().encode(
            GhostFileRenameRequest(destinationPath: "../escaped.txt")
        )
        let escapingRenameResponse = await router.route(
            request(method: .POST, path: operationPath("rename", relativePath: "sample.txt")),
            body: escapingRename
        )
        XCTAssertEqual(escapingRenameResponse.status, .badRequest)
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
    func testCreatesRestorablePublicKeyIdentity() throws {
        let identity = try GhostFileTLSIdentity.make()
        let restored = try GhostFileTLSIdentity.make(
            privateKeyRepresentation: identity.privateKeyRepresentation
        )
        XCTAssertEqual(identity.publicKeyPin, restored.publicKeyPin)
        XCTAssertTrue(identity.publicKeyPin.hasPrefix("p256-sha256-"))
        XCTAssertFalse(identity.publicKeyPin.contains("="))
        XCTAssertTrue(GhostFileProtocol.validPublicKeyPin(identity.publicKeyPin))
    }

    func testParsesNewAndLegacyPeerPinsWithoutAmbiguity() throws {
        let identity = try GhostFileTLSIdentity.make()
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let base = "ghostfile://example.local:8049/v1/shares/\(id.uuidString)"
        let modern = try XCTUnwrap(URL(string: "\(base)?pk=\(identity.publicKeyPin)"))
        let legacy = try XCTUnwrap(URL(string: "\(base)?tls_pin=legacy-certificate-pin"))
        let ambiguous = try XCTUnwrap(URL(string: "\(base)?pk=\(identity.publicKeyPin)&pk=\(identity.publicKeyPin)"))

        XCTAssertEqual(GhostFileProtocol.peerPin(from: modern), .publicKey(identity.publicKeyPin))
        XCTAssertEqual(GhostFileProtocol.peerPin(from: legacy), .legacyCertificate("legacy-certificate-pin"))
        XCTAssertNil(GhostFileProtocol.peerPin(from: ambiguous))
    }
}
