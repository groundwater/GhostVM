import XCTest

final class ScreenshotTests: XCTestCase {

    // MARK: - Empty State

    func testCaptureVMListEmpty() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "vm-list-empty"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - With VMs

    func testCaptureVMListWithVMs() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-with-vms"]
        app.launch()

        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "vm-list-with-vms"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Create VM Sheet

    func testCaptureCreateVMSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-with-vms"]
        app.launch()

        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Click the Create button
        let createButton = window.buttons["Create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.click()

        // Wait for the sheet content to appear (look for the Cancel button inside the sheet)
        let cancelButton = window.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "create-vm-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Settings Window

    func testCaptureSettingsWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let mainWindow = app.windows["GhostVM"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        // Open Settings via keyboard shortcut
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        let screenshot = settingsWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "settings-window"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Restore Images Window

    func testCaptureRestoreImagesWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let mainWindow = app.windows["GhostVM"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))

        // Click the Images button to open Restore Images window
        let imagesButton = mainWindow.buttons["Images"]
        XCTAssertTrue(imagesButton.waitForExistence(timeout: 3))
        imagesButton.click()

        let restoreWindow = app.windows["Restore Images"]
        XCTAssertTrue(restoreWindow.waitForExistence(timeout: 5))

        let screenshot = restoreWindow.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "restore-images"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Edit VM Sheet

    func testCaptureEditVMSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-with-vms", "--ui-testing-tall"]
        app.launch()

        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Right-click the second VM row (first is "Running" so Edit is disabled)
        let list = window.outlines.firstMatch.exists ? window.outlines.firstMatch : window.tables.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        let secondRow = list.cells.element(boundBy: 1)
        XCTAssertTrue(secondRow.waitForExistence(timeout: 3))
        secondRow.rightClick()

        // Click "Edit Settings…" in the context menu (U+2026 ellipsis)
        let editMenuItem = app.menuItems["Edit Settings\u{2026}"]
        XCTAssertTrue(editMenuItem.waitForExistence(timeout: 3))
        editMenuItem.click()

        // Wait for the sheet to appear (look for Save button)
        let saveButton = window.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))

        sleep(1)

        // Capture just the sheet, not the whole window with dimmed background
        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.exists)
        let screenshot = sheet.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "edit-vm-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Context Menu

    func testCaptureContextMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-with-vms"]
        app.launch()

        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Right-click the first VM row
        let list = window.outlines.firstMatch.exists ? window.outlines.firstMatch : window.tables.firstMatch
        if list.waitForExistence(timeout: 3) {
            let firstRow = list.cells.firstMatch
            if firstRow.waitForExistence(timeout: 3) {
                firstRow.rightClick()
                // Give menu time to appear
                sleep(1)
            }
        }

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "context-menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
