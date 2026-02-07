import XCTest

final class VMListUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testAppLaunchShowsMainWindow() {
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window should appear")
    }

    func testCreateButtonExists() {
        let createButton = app.buttons["vmList.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Create button should exist")
        XCTAssertTrue(createButton.isHittable, "Create button should be hittable")
    }

    func testCreateButtonOpensSheet() {
        let createButton = app.buttons["vmList.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()

        // Verify the sheet appears with Create VM fields
        let cpuField = app.textFields["createVM.cpuField"]
        XCTAssertTrue(cpuField.waitForExistence(timeout: 3), "CPU field should appear in create sheet")
    }

    func testEmptyListOnFreshLaunch() {
        // With --ui-testing flag, no VM rows should be present
        let playButton = app.buttons["vmRow.playButton"]
        XCTAssertFalse(playButton.exists, "No VM rows should exist in clean state")
    }

    func testSettingsOpensViaKeyboard() {
        // Cmd+, opens settings window
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings window should open via Cmd+,")
    }
}
