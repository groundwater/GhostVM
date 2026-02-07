import XCTest

final class SettingsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting()

        // Open settings via Cmd+,
        app.typeKey(",", modifierFlags: .command)
        // Wait for the settings window
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testSettingsWindowShowsAllFields() {
        let vmPathField = app.textFields["settings.vmPathField"]
        let ipswPathField = app.textFields["settings.ipswPathField"]
        let feedURLField = app.textFields["settings.feedURLField"]

        XCTAssertTrue(vmPathField.waitForExistence(timeout: 3), "VM path field should exist")
        XCTAssertTrue(ipswPathField.exists, "IPSW path field should exist")
        XCTAssertTrue(feedURLField.exists, "Feed URL field should exist")
    }

    func testVerifyButtonExists() {
        let verifyButton = app.buttons["settings.verifyButton"]
        XCTAssertTrue(verifyButton.waitForExistence(timeout: 3), "Verify button should exist")
    }

    func testCaptureKeysToggleExists() {
        // The capture system keys toggle should be present in settings
        let toggle = app.checkBoxes.matching(NSPredicate(format: "label CONTAINS 'Capture system keys'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "Capture system keys toggle should exist")
    }
}
