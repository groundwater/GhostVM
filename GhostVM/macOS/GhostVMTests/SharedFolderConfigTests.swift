import XCTest
@testable import GhostVMKit

final class SharedFolderConfigTests: XCTestCase {
    func testNormalizeExpandsTilde() {
        var config = SharedFolderConfig(path: "~/Documents")
        let changed = config.normalize()
        XCTAssertTrue(changed)
        XCTAssertFalse(config.path.hasPrefix("~"))
        XCTAssertTrue(config.path.hasPrefix("/"))
        XCTAssertTrue(config.path.hasSuffix("/Documents"))
    }

    func testNormalizeResolvesDoubleDots() {
        var config = SharedFolderConfig(path: "/usr/local/../bin")
        let changed = config.normalize()
        XCTAssertTrue(changed)
        XCTAssertEqual(config.path, "/usr/bin")
    }

    func testAbsolutePathUnchanged() {
        var config = SharedFolderConfig(path: "/usr/local/bin")
        let changed = config.normalize()
        XCTAssertFalse(changed)
        XCTAssertEqual(config.path, "/usr/local/bin")
    }

    func testReturnsTrueWhenChanged() {
        var config = SharedFolderConfig(path: "~/Desktop")
        XCTAssertTrue(config.normalize())
    }

    func testReturnsFalseWhenUnchanged() {
        var config = SharedFolderConfig(path: "/Users/test/Desktop")
        XCTAssertFalse(config.normalize())
    }

    func testCodableRoundTrip() throws {
        let config = SharedFolderConfig(path: "/Users/test/shared", readOnly: false)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SharedFolderConfig.self, from: data)
        XCTAssertEqual(decoded.path, config.path)
        XCTAssertEqual(decoded.readOnly, config.readOnly)
        XCTAssertEqual(decoded.id, config.id)
    }

    func testDefaultReadOnly() {
        let config = SharedFolderConfig(path: "/tmp")
        XCTAssertTrue(config.readOnly)
    }
}
