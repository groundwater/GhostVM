import XCTest

// Manual-only items not covered here:
// - VM icon exact 64x64 pixel size
// - Status text colors (green for Running, orange for Paused)
// - Font styles (.headline, .caption, .subheadline)

final class VMRowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchWithMockVMs()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testRowShowsVMName() {
        let names = app.staticTexts.matching(identifier: "vmRow.name")
        XCTAssertGreaterThanOrEqual(names.count, 1, "At least one VM name should be visible")

        // Verify one of the known mock VM names is present
        let allLabels = (0..<names.count).map { names.element(boundBy: $0).label }
        XCTAssertTrue(allLabels.contains("macOS Sequoia"), "Should contain 'macOS Sequoia' mock VM")
    }

    func testRowShowsOSVersion() {
        let versions = app.staticTexts.matching(identifier: "vmRow.osVersion")
        XCTAssertGreaterThanOrEqual(versions.count, 1, "At least one OS version should be visible")

        let allLabels = (0..<versions.count).map { versions.element(boundBy: $0).label }
        XCTAssertTrue(allLabels.contains("macOS 15.2"), "Should contain 'macOS 15.2' version for Sequoia")
    }

    func testRowShowsStatusText() {
        let statuses = app.staticTexts.matching(identifier: "vmRow.status")
        XCTAssertGreaterThanOrEqual(statuses.count, 1, "At least one status label should be visible")

        let allLabels = (0..<statuses.count).map { statuses.element(boundBy: $0).label }
        XCTAssertTrue(allLabels.contains("Running") || allLabels.contains("Stopped") || allLabels.contains("Suspended"),
                       "Should contain a known status value")
    }

    func testPlayButtonForInstalledVM() {
        let playButtons = app.buttons.matching(identifier: "vmRow.playButton")
        XCTAssertGreaterThanOrEqual(playButtons.count, 1, "Installed VMs should have play buttons")
    }

    func testInstallButtonForUninstalledVM() {
        let installButtons = app.buttons.matching(identifier: "vmRow.installButton")
        XCTAssertGreaterThanOrEqual(installButtons.count, 1, "Uninstalled VMs should have install buttons")
    }

    func testEllipsisMenuExists() {
        let menus = app.buttons.matching(identifier: "vmRow.ellipsisMenu")
        XCTAssertGreaterThanOrEqual(menus.count, 1, "Each VM row should have an ellipsis menu button")
    }
}
