import XCTest

final class ParseBytesTests: XCTestCase {
    func testPlainNumber() throws {
        XCTAssertEqual(try parseBytes(from: "1024"), 1024)
        XCTAssertEqual(try parseBytes(from: "0"), 0)
    }

    func testPlainNumberWithDefaultUnit() throws {
        // defaultUnit is a multiplier for plain numbers
        let gib: UInt64 = 1 << 30
        XCTAssertEqual(try parseBytes(from: "8", defaultUnit: gib), 8 * gib)
    }

    func testGigabytes() throws {
        let gib: UInt64 = 1 << 30
        XCTAssertEqual(try parseBytes(from: "8G"), 8 * gib)
        XCTAssertEqual(try parseBytes(from: "8g"), 8 * gib)
        XCTAssertEqual(try parseBytes(from: "8GB"), 8 * gib)
        XCTAssertEqual(try parseBytes(from: "8gb"), 8 * gib)
    }

    func testMegabytes() throws {
        let mib: UInt64 = 1 << 20
        XCTAssertEqual(try parseBytes(from: "512M"), 512 * mib)
        XCTAssertEqual(try parseBytes(from: "512m"), 512 * mib)
        XCTAssertEqual(try parseBytes(from: "512MB"), 512 * mib)
    }

    func testKilobytes() throws {
        let kib: UInt64 = 1 << 10
        XCTAssertEqual(try parseBytes(from: "64K"), 64 * kib)
        XCTAssertEqual(try parseBytes(from: "64KB"), 64 * kib)
    }

    func testTerabytes() throws {
        let tib: UInt64 = 1 << 40
        XCTAssertEqual(try parseBytes(from: "1T"), tib)
        XCTAssertEqual(try parseBytes(from: "2TB"), 2 * tib)
    }

    func testInvalidInput() {
        XCTAssertThrowsError(try parseBytes(from: "abc"))
        XCTAssertThrowsError(try parseBytes(from: "G"))
        XCTAssertThrowsError(try parseBytes(from: ""))
    }
}

final class SanitizedSnapshotNameTests: XCTestCase {
    func testValidName() throws {
        XCTAssertEqual(try sanitizedSnapshotName("clean"), "clean")
        XCTAssertEqual(try sanitizedSnapshotName("before-update"), "before-update")
        XCTAssertEqual(try sanitizedSnapshotName("snapshot_2024"), "snapshot_2024")
    }

    func testRejectsForwardSlash() {
        XCTAssertThrowsError(try sanitizedSnapshotName("foo/bar"))
        XCTAssertThrowsError(try sanitizedSnapshotName("/absolute"))
    }

    func testAllowsBackslash() throws {
        // Backslash is allowed (only forward slash is rejected)
        XCTAssertEqual(try sanitizedSnapshotName("foo\\bar"), "foo\\bar")
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try sanitizedSnapshotName(""))
    }
}

final class StandardizedAbsolutePathTests: XCTestCase {
    func testExpandsTilde() {
        let result = standardizedAbsolutePath("~/Documents")
        XCTAssertFalse(result.hasPrefix("~"))
        XCTAssertTrue(result.hasPrefix("/"))
        XCTAssertTrue(result.hasSuffix("/Documents"))
    }

    func testAbsolutePathUnchanged() {
        let result = standardizedAbsolutePath("/usr/local/bin")
        XCTAssertEqual(result, "/usr/local/bin")
    }

    func testRemovesTrailingSlash() {
        let result = standardizedAbsolutePath("/usr/local/")
        XCTAssertEqual(result, "/usr/local")
    }

    func testResolvesDoubleDots() {
        let result = standardizedAbsolutePath("/usr/local/../bin")
        XCTAssertEqual(result, "/usr/bin")
    }
}

final class VMStoredConfigTests: XCTestCase {
    func testEncodeDecode() throws {
        let now = Date()
        let config = VMStoredConfig(
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

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VMStoredConfig.self, from: data)

        XCTAssertEqual(decoded.version, config.version)
        XCTAssertEqual(decoded.cpus, config.cpus)
        XCTAssertEqual(decoded.memoryBytes, config.memoryBytes)
        XCTAssertEqual(decoded.diskBytes, config.diskBytes)
        XCTAssertEqual(decoded.restoreImagePath, config.restoreImagePath)
        XCTAssertEqual(decoded.installed, config.installed)
        XCTAssertEqual(decoded.lastInstallBuild, config.lastInstallBuild)
    }

    func testLegacyNameKey() throws {
        // "name" key in JSON should map to legacyName
        let json = """
        {
            "version": 1,
            "createdAt": 0,
            "modifiedAt": 0,
            "cpus": 2,
            "memoryBytes": 4294967296,
            "diskBytes": 34359738368,
            "restoreImagePath": "/restore.ipsw",
            "hardwareModelPath": "HardwareModel.bin",
            "machineIdentifierPath": "MachineIdentifier.bin",
            "auxiliaryStoragePath": "AuxiliaryStorage.bin",
            "diskPath": "disk.img",
            "sharedFolderReadOnly": true,
            "installed": false,
            "name": "OldVMName"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let config = try decoder.decode(VMStoredConfig.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(config.legacyName, "OldVMName")
    }
}

final class VMFileLayoutTests: XCTestCase {
    func testURLGeneration() {
        let bundleURL = URL(fileURLWithPath: "/Users/test/VMs/MyVM.GhostVM")
        let layout = VMFileLayout(bundleURL: bundleURL)

        XCTAssertEqual(layout.configURL.path, "/Users/test/VMs/MyVM.GhostVM/config.json")
        XCTAssertEqual(layout.diskURL.path, "/Users/test/VMs/MyVM.GhostVM/disk.img")
        XCTAssertEqual(layout.hardwareModelURL.path, "/Users/test/VMs/MyVM.GhostVM/HardwareModel.bin")
        XCTAssertEqual(layout.machineIdentifierURL.path, "/Users/test/VMs/MyVM.GhostVM/MachineIdentifier.bin")
        XCTAssertEqual(layout.auxiliaryStorageURL.path, "/Users/test/VMs/MyVM.GhostVM/AuxiliaryStorage.bin")
        XCTAssertEqual(layout.pidFileURL.path, "/Users/test/VMs/MyVM.GhostVM/vmctl.pid")
        XCTAssertEqual(layout.snapshotsDirectoryURL.path, "/Users/test/VMs/MyVM.GhostVM/Snapshots")
    }
}

final class VMLockOwnerTests: XCTestCase {
    func testCLIOwner() {
        let owner = VMLockOwner.cli(12345)
        XCTAssertEqual(owner.pid, 12345)
        XCTAssertFalse(owner.isEmbedded)
    }

    func testEmbeddedOwner() {
        let owner = VMLockOwner.embedded(67890)
        XCTAssertEqual(owner.pid, 67890)
        XCTAssertTrue(owner.isEmbedded)
    }

    func testReadWriteRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let pidFile = tempDir.appendingPathComponent("test-\(UUID()).pid")

        defer { try? FileManager.default.removeItem(at: pidFile) }

        // Test CLI owner
        let cliOwner = VMLockOwner.cli(11111)
        try writeVMLockOwner(cliOwner, to: pidFile)
        XCTAssertEqual(readVMLockOwner(from: pidFile), cliOwner)

        // Test embedded owner
        let embeddedOwner = VMLockOwner.embedded(22222)
        try writeVMLockOwner(embeddedOwner, to: pidFile)
        XCTAssertEqual(readVMLockOwner(from: pidFile), embeddedOwner)
    }

    func testReadNonexistent() {
        let bogusURL = URL(fileURLWithPath: "/nonexistent/path/to/pid")
        XCTAssertNil(readVMLockOwner(from: bogusURL))
    }

    func testParseFormats() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let pidFile = tempDir.appendingPathComponent("test-\(UUID()).pid")

        defer { try? FileManager.default.removeItem(at: pidFile) }

        // Plain PID (CLI format)
        try "12345\n".write(to: pidFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(readVMLockOwner(from: pidFile), .cli(12345))

        // Embedded format
        try "embedded:67890\n".write(to: pidFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(readVMLockOwner(from: pidFile), .embedded(67890))

        // Invalid format
        try "garbage\n".write(to: pidFile, atomically: true, encoding: .utf8)
        XCTAssertNil(readVMLockOwner(from: pidFile))
    }
}
