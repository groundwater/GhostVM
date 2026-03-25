import XCTest
@testable import GhostTools

final class AppVersionTests: XCTestCase {

    func testSameMajorMinorDifferentPatch() {
        XCTAssertTrue(AppVersion("1.82.100") < AppVersion("1.82.200"))
    }

    func testMinorVersionWins() {
        XCTAssertTrue(AppVersion("1.83.0") > AppVersion("1.82.9999999999"))
    }

    func testMajorVersionWins() {
        XCTAssertTrue(AppVersion("2.0.0") > AppVersion("1.99.9999999999"))
    }

    func testEquality() {
        XCTAssertEqual(AppVersion("1.82.1771275740"), AppVersion("1.82.1771275740"))
    }

    func testMissingComponentTreatedAsZero() {
        XCTAssertTrue(AppVersion("1.82") < AppVersion("1.82.1"))
    }

    func testInvalidVersion() {
        XCTAssertFalse(AppVersion("dev").isValid)
    }

    func testSingleComponentIsValid() {
        XCTAssertTrue(AppVersion("0").isValid)
    }

    func testDescription() {
        XCTAssertEqual(AppVersion("1.82.100").description, "1.82.100")
    }

    func testEqualVersionsNotLessThan() {
        let v = AppVersion("1.82.100")
        XCTAssertFalse(v < v)
    }
}
