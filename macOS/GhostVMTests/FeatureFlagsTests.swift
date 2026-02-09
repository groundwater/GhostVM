import XCTest
@testable import GhostVMKit

final class FeatureFlagsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var flags: FeatureFlags!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        flags = FeatureFlags(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
        defaults = nil
        flags = nil
        super.tearDown()
    }

    func testDefaultFlagIsFalse() {
        XCTAssertFalse(flags.isEnabled("nonexistent"))
    }

    func testSetAndGetFlag() {
        flags.setEnabled("foo", value: true)
        XCTAssertTrue(flags.isEnabled("foo"))

        flags.setEnabled("foo", value: false)
        XCTAssertFalse(flags.isEnabled("foo"))
    }

    func testFlagDescriptorHasNonEmptyFields() {
        for flag in FeatureFlags.allFlags {
            XCTAssertFalse(flag.key.isEmpty)
            XCTAssertFalse(flag.displayName.isEmpty)
            XCTAssertFalse(flag.description.isEmpty)
        }
    }
}
