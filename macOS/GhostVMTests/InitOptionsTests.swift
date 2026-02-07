import XCTest
@testable import GhostVMKit

final class InitOptionsTests: XCTestCase {
    func testDefaultValues() {
        let options = InitOptions()
        XCTAssertEqual(options.cpus, 4)
        XCTAssertEqual(options.memoryGiB, 8)
        XCTAssertEqual(options.diskGiB, 64)
        XCTAssertNil(options.restoreImagePath)
        XCTAssertNil(options.sharedFolderPath)
        XCTAssertFalse(options.sharedFolderWritable)
        XCTAssertTrue(options.sharedFolders.isEmpty)
    }

    func testCustomValues() {
        let options = InitOptions(
            cpus: 8,
            memoryGiB: 16,
            diskGiB: 128,
            restoreImagePath: "/path/to/restore.ipsw",
            sharedFolderPath: "/Users/test/shared",
            sharedFolderWritable: true
        )
        XCTAssertEqual(options.cpus, 8)
        XCTAssertEqual(options.memoryGiB, 16)
        XCTAssertEqual(options.diskGiB, 128)
        XCTAssertEqual(options.restoreImagePath, "/path/to/restore.ipsw")
        XCTAssertEqual(options.sharedFolderPath, "/Users/test/shared")
        XCTAssertTrue(options.sharedFolderWritable)
    }

    func testLinuxInitOptionsDefaults() {
        let options = LinuxInitOptions()
        XCTAssertEqual(options.cpus, 4)
        XCTAssertEqual(options.memoryGiB, 8)
        XCTAssertEqual(options.diskGiB, 64)
        XCTAssertNil(options.isoPath)
        XCTAssertTrue(options.sharedFolders.isEmpty)
    }

    func testLinuxInitOptionsCustom() {
        let folder = SharedFolderConfig(path: "/tmp/share")
        let options = LinuxInitOptions(
            cpus: 2,
            memoryGiB: 4,
            diskGiB: 32,
            isoPath: "/path/to/linux.iso",
            sharedFolders: [folder]
        )
        XCTAssertEqual(options.cpus, 2)
        XCTAssertEqual(options.isoPath, "/path/to/linux.iso")
        XCTAssertEqual(options.sharedFolders.count, 1)
    }
}
