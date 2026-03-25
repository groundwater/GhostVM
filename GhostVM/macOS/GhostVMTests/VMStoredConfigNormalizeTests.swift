import XCTest
@testable import GhostVMKit

final class VMStoredConfigNormalizeTests: XCTestCase {
    private func makeConfig(
        restoreImagePath: String = "/restore.ipsw",
        hardwareModelPath: String = "HardwareModel.bin",
        machineIdentifierPath: String = "MachineIdentifier.bin",
        auxiliaryStoragePath: String = "AuxiliaryStorage.bin",
        diskPath: String = "disk.img",
        sharedFolderPath: String? = nil,
        sharedFolders: [SharedFolderConfig] = [],
        legacyName: String? = nil
    ) -> VMStoredConfig {
        let now = Date()
        return VMStoredConfig(
            version: 1,
            createdAt: now,
            modifiedAt: now,
            cpus: 4,
            memoryBytes: 8 * 1024 * 1024 * 1024,
            diskBytes: 64 * 1024 * 1024 * 1024,
            restoreImagePath: restoreImagePath,
            hardwareModelPath: hardwareModelPath,
            machineIdentifierPath: machineIdentifierPath,
            auxiliaryStoragePath: auxiliaryStoragePath,
            diskPath: diskPath,
            sharedFolderPath: sharedFolderPath,
            sharedFolderReadOnly: true,
            sharedFolders: sharedFolders,
            installed: true,
            lastInstallBuild: nil,
            lastInstallVersion: nil,
            lastInstallDate: nil,
            legacyName: legacyName
        )
    }

    func testRelativePathsStayRelative() {
        var config = makeConfig()
        let layout = VMFileLayout(bundleURL: URL(fileURLWithPath: "/Users/test/VMs/MyVM.GhostVM"))
        let changed = config.normalize(relativeTo: layout)
        XCTAssertFalse(changed)
        XCTAssertEqual(config.diskPath, "disk.img")
        XCTAssertEqual(config.hardwareModelPath, "HardwareModel.bin")
    }

    func testAbsolutePathsInsideBundleBecomeRelative() {
        var config = makeConfig(
            diskPath: "/Users/test/VMs/MyVM.GhostVM/disk.img"
        )
        let layout = VMFileLayout(bundleURL: URL(fileURLWithPath: "/Users/test/VMs/MyVM.GhostVM"))
        let changed = config.normalize(relativeTo: layout)
        XCTAssertTrue(changed)
        XCTAssertEqual(config.diskPath, "disk.img")
    }

    func testSharedFolderPathsExpandTilde() {
        var config = makeConfig(
            sharedFolderPath: "~/Desktop"
        )
        let layout = VMFileLayout(bundleURL: URL(fileURLWithPath: "/Users/test/VMs/MyVM.GhostVM"))
        let changed = config.normalize(relativeTo: layout)
        XCTAssertTrue(changed)
        XCTAssertFalse(config.sharedFolderPath!.hasPrefix("~"))
        XCTAssertTrue(config.sharedFolderPath!.hasPrefix("/"))
    }

    func testReturnsFlagAccuracy() {
        var config = makeConfig()
        let layout = VMFileLayout(bundleURL: URL(fileURLWithPath: "/Users/test/VMs/MyVM.GhostVM"))
        // Config with already-normalized paths should return false
        let changed = config.normalize(relativeTo: layout)
        XCTAssertFalse(changed)
    }

    func testLegacyNameCleared() {
        var config = makeConfig(legacyName: "OldName")
        let layout = VMFileLayout(bundleURL: URL(fileURLWithPath: "/Users/test/VMs/MyVM.GhostVM"))
        let changed = config.normalize(relativeTo: layout)
        XCTAssertTrue(changed)
        XCTAssertNil(config.legacyName)
    }

    func testSharedFoldersNormalized() {
        var config = makeConfig(
            sharedFolders: [SharedFolderConfig(path: "~/Documents")]
        )
        let layout = VMFileLayout(bundleURL: URL(fileURLWithPath: "/Users/test/VMs/MyVM.GhostVM"))
        let changed = config.normalize(relativeTo: layout)
        XCTAssertTrue(changed)
        XCTAssertFalse(config.sharedFolders[0].path.hasPrefix("~"))
    }
}
