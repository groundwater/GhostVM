import XCTest
@testable import GhostVMKit

final class VMConfigStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("VMConfigStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func makeConfig() -> VMStoredConfig {
        let now = Date()
        return VMStoredConfig(
            version: 1,
            createdAt: now,
            modifiedAt: now,
            cpus: 4,
            memoryBytes: 8 * 1024 * 1024 * 1024,
            diskBytes: 64 * 1024 * 1024 * 1024,
            restoreImagePath: "/path/to/restore.ipsw",
            hardwareModelPath: "HardwareModel.bin",
            machineIdentifierPath: "MachineIdentifier.bin",
            auxiliaryStoragePath: "AuxiliaryStorage.bin",
            diskPath: "disk.img",
            sharedFolderPath: nil,
            sharedFolderReadOnly: true,
            installed: true,
            lastInstallBuild: "24A123",
            lastInstallVersion: "15.0",
            lastInstallDate: now,
            legacyName: nil
        )
    }

    func testLoadAndSaveRoundTrip() throws {
        let layout = VMFileLayout(bundleURL: tempDir)
        let store = VMConfigStore(layout: layout)
        let config = makeConfig()

        try store.save(config)
        let loaded = try store.load()

        XCTAssertEqual(loaded.version, config.version)
        XCTAssertEqual(loaded.cpus, config.cpus)
        XCTAssertEqual(loaded.memoryBytes, config.memoryBytes)
        XCTAssertEqual(loaded.diskBytes, config.diskBytes)
        XCTAssertEqual(loaded.installed, config.installed)
        XCTAssertEqual(loaded.lastInstallBuild, config.lastInstallBuild)
    }

    func testSaveUpdatesModifiedAt() throws {
        let layout = VMFileLayout(bundleURL: tempDir)
        let store = VMConfigStore(layout: layout)
        var config = makeConfig()
        let originalDate = config.modifiedAt

        // Wait briefly to ensure time difference
        config.modifiedAt = Date(timeIntervalSince1970: 0)
        try store.save(config)
        let loaded = try store.load()

        // save() sets modifiedAt to Date(), which should be after our zeroed date
        XCTAssertGreaterThan(loaded.modifiedAt, Date(timeIntervalSince1970: 0))
    }

    func testLoadFromMissingFileThrows() {
        let missingDir = tempDir.appendingPathComponent("nonexistent.GhostVM")
        let layout = VMFileLayout(bundleURL: missingDir)
        let store = VMConfigStore(layout: layout)

        XCTAssertThrowsError(try store.load())
    }

    func testLoadFromCorruptJSONThrows() throws {
        let layout = VMFileLayout(bundleURL: tempDir)
        let store = VMConfigStore(layout: layout)

        try "not valid json".write(to: layout.configURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try store.load())
    }

    func testSaveCreatesFile() throws {
        let layout = VMFileLayout(bundleURL: tempDir)
        let store = VMConfigStore(layout: layout)
        let config = makeConfig()

        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.configURL.path))
        try store.save(config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.configURL.path))
    }
}
