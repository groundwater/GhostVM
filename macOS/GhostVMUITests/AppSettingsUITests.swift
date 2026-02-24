import XCTest

// Manual-only items not covered here:
// - NSOpenPanel for Browse button
// - Sparkle updater persistence
// - Actual feed URL verification network request

final class AppSettingsUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting()

        // Open settings via Cmd+,
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testSettingsWindowAndControls() {
        XCTContext.runActivity(named: "Settings opens via keyboard") { _ in
            let settingsWindow = app.windows["Settings"]
            XCTAssertTrue(settingsWindow.exists, "Settings window should be open via Cmd+,")
        }

        XCTContext.runActivity(named: "Core settings controls exist") { _ in
            XCTAssertTrue(app.textFields["settings.vmPathField"].waitForExistence(timeout: 3), "VMs folder field should exist")
            XCTAssertTrue(app.buttons["settings.browseVMsButton"].waitForExistence(timeout: 3), "Browse button should exist for VMs folder")
            XCTAssertTrue(app.textFields["settings.ipswPathField"].waitForExistence(timeout: 3), "IPSW cache field should exist")
            XCTAssertTrue(app.textFields["settings.feedURLField"].waitForExistence(timeout: 3), "Feed URL field should exist")
            XCTAssertTrue(app.buttons["settings.verifyButton"].waitForExistence(timeout: 3), "Verify button should exist")
        }

        XCTContext.runActivity(named: "App icon picker exists") { _ in
            let picker = app.descendants(matching: .any)["settings.appIconPicker"]
            if picker.waitForExistence(timeout: 3) {
                XCTAssertTrue(picker.exists, "App icon picker should exist")
            } else {
                let settingsWindow = app.windows["Settings"]
                let fallbackButtons = settingsWindow.buttons.matching(NSPredicate(format: "identifier == ''"))
                XCTAssertGreaterThanOrEqual(fallbackButtons.count, 3, "App icon picker should expose buttons")
            }
        }

        XCTContext.runActivity(named: "App icon picker exposes options") { _ in
            let picker = app.descendants(matching: .any)["settings.appIconPicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 3), "App icon picker should exist")
            let buttonCount = picker.buttons.count
            let radioCount = picker.radioButtons.count
            if buttonCount > 0 || radioCount > 0 {
                XCTAssertEqual(max(buttonCount, radioCount), 3, "App icon picker should have exactly three options")
            } else {
                XCTAssertGreaterThan(picker.descendants(matching: .any).count, 0, "App icon picker should expose accessibility children")
            }
        }

        XCTContext.runActivity(named: "Auto-update toggle exists") { _ in
            let toggle = app.checkBoxes["settings.autoUpdateToggle"]
            if toggle.waitForExistence(timeout: 3) {
                XCTAssertTrue(toggle.exists)
            } else {
                let toggleByLabel = app.checkBoxes["Automatically check for updates"]
                XCTAssertTrue(toggleByLabel.waitForExistence(timeout: 3), "Auto-update toggle should exist")
            }
        }
    }

    func testSettingsOpensViaMenu() {
        // Close the current settings window first
        app.typeKey("w", modifierFlags: .command)
        sleep(1)

        // Open via menu
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["GhostVM"].click()
        let settingsItem = app.menuItems["Settings…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 3))
        settingsItem.click()

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings should open via menu")
    }
}
