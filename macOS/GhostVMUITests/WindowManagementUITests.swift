import XCTest

final class WindowManagementUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testMainWindowExists() {
        let mainWindow = app.windows["GhostVM"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5), "Main window should exist")
    }

    func testSettingsWindowCanBeClosed() {
        // Open settings
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Close it via Cmd+W
        app.typeKey("w", modifierFlags: .command)

        // Settings window should close
        XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3), "Settings window should close after Cmd+W")
    }

    func testMultipleWindowsCanOpen() {
        // Open settings
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Main window should still exist
        let mainWindow = app.windows["GhostVM"]
        XCTAssertTrue(mainWindow.exists, "Main window should remain open alongside settings")
    }
}
