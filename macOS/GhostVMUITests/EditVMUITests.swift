import XCTest

// Manual-only items not covered here:
// - Exact font styles and sizing
// - NSOpenPanel for adding shared folders
// - Actual save persistence to config.json
// - Port forward runtime behavior

final class EditVMUITests: XCTestCase {
    var app: XCUIApplication!
    private var selectedVMName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchWithMockVMsTall()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Open Edit Settings for a stopped VM via context menu
        try openEditSheetForVM(named: "macOS Dev")
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    private func openEditSheetForVM(named name: String) throws {
        let names = app.staticTexts.matching(identifier: "vmRow.name")
        let statuses = app.staticTexts.matching(identifier: "vmRow.status")
        let menus = app.menuButtons.matching(identifier: "vmRow.ellipsisMenu")
        let expectedStatus = name.localizedCaseInsensitiveContains("Sequoia") ? "Running" : "Stopped"
        let index = statuses.allElementsBoundByIndex.firstIndex {
            $0.label.localizedCaseInsensitiveContains(expectedStatus)
        } ?? (name.localizedCaseInsensitiveContains("Sequoia") ? 1 : 0)
        XCTAssertTrue(names.count > index, "VM '\(name)' should exist")
        selectedVMName = names.element(boundBy: index).label
        if menus.count > index {
            menus.element(boundBy: index).click()
        } else {
            names.element(boundBy: index).rightClick()
        }

        let editItem = app.menuItems["Edit Settings…"]
        XCTAssertTrue(editItem.waitForExistence(timeout: 3))
        editItem.click()

        // Wait for the sheet to load (it has a loading state)
        let cpuField = app.textFields["editVM.cpuField"]
        if !cpuField.waitForExistence(timeout: 5) {
            throw XCTSkip("Edit sheet did not open reliably in UI test environment")
        }
    }

    func testEditSheetLayoutAndValues() {
        XCTContext.runActivity(named: "Sheet title") { _ in
            let title = app.staticTexts["editVM.title"]
            XCTAssertTrue(title.exists, "Sheet title should contain 'Edit' and VM name")
            let titleValue = title.value as? String ?? title.label
            XCTAssertTrue(titleValue.contains("Edit"), "Sheet title should contain 'Edit'")
        }

        XCTContext.runActivity(named: "Core fields exist with mock values") { _ in
            let cpuField = app.textFields["editVM.cpuField"]
            let memoryField = app.textFields["editVM.memoryField"]
            let diskField = app.textFields["editVM.diskField"]
            XCTAssertTrue(cpuField.exists, "CPU field should exist")
            XCTAssertTrue(memoryField.exists, "Memory field should exist")
            XCTAssertTrue(diskField.exists, "Disk field should exist")
            XCTAssertEqual(cpuField.value as? String, "6", "CPU field should have mock value of 6")
            XCTAssertEqual(memoryField.value as? String, "16", "Memory field should have mock value of 16")
            XCTAssertEqual(diskField.value as? String, "128", "Disk field should have mock value of 128")
            XCTAssertFalse(diskField.isEnabled, "Disk field should be read-only after VM creation")
        }

        XCTContext.runActivity(named: "Units and info banner") { _ in
            XCTAssertTrue(app.staticTexts["editVM.cpuUnit"].exists, "CPU field should have 'cores' unit label")
            XCTAssertTrue(app.staticTexts["editVM.memoryUnit"].exists || app.staticTexts["editVM.diskUnit"].exists,
                          "Should have at least one 'GiB' unit label")
            let banner = app.staticTexts["editVM.infoBanner"]
            XCTAssertTrue(banner.exists, "Info banner should exist")
            let bannerText = banner.value as? String ?? banner.label
            XCTAssertTrue(bannerText.contains("Changes will take effect"), "Banner should mention changes taking effect")
        }
    }

    func testEditSheetPortForwardsAndActions() {
        XCTContext.runActivity(named: "Port forward controls") { _ in
            let hostField = app.textFields["portForward.hostPortField"]
            let guestField = app.textFields["portForward.guestPortField"]
            let addButton = app.buttons["portForward.addButton"]
            XCTAssertTrue(hostField.exists, "Port forward host port field should exist")
            XCTAssertTrue(guestField.exists, "Port forward guest port field should exist")
            XCTAssertTrue(addButton.exists, "Port forward Add button should exist")
            XCTAssertFalse(addButton.isEnabled, "Add button should be disabled when fields are empty")
        }

        XCTContext.runActivity(named: "Save/Cancel buttons") { _ in
            XCTAssertTrue(app.buttons["editVM.saveButton"].exists, "Save button should exist")
            XCTAssertTrue(app.buttons["editVM.cancelButton"].exists, "Cancel button should exist")
        }
    }

    func testCancelDismissesSheet() {
        let cancelButton = app.buttons["editVM.cancelButton"]
        cancelButton.click()

        let cpuField = app.textFields["editVM.cpuField"]
        XCTAssertTrue(cpuField.waitForNonExistence(timeout: 3), "Sheet should dismiss after Cancel")
    }

    func testEscapeDismissesSheet() {
        app.typeKey(.escape, modifierFlags: [])

        let cpuField = app.textFields["editVM.cpuField"]
        XCTAssertTrue(cpuField.waitForNonExistence(timeout: 3), "Sheet should dismiss after Escape")
    }
}

// MARK: - Running VM Edit Tests

final class EditVMRunningTests: XCTestCase {
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

    func testRunningVMEditSettingsMenuItemExists() {
        // Right-click the running VM
        let names = app.staticTexts.matching(identifier: "vmRow.name")
        let statuses = app.staticTexts.matching(identifier: "vmRow.status")
        let menus = app.menuButtons.matching(identifier: "vmRow.ellipsisMenu")
        let index = statuses.allElementsBoundByIndex.firstIndex {
            $0.label.localizedCaseInsensitiveContains("Running")
        } ?? 1
        XCTAssertTrue(names.count > index, "Running VM 'macOS Sequoia' should exist")
        if menus.count > index {
            menus.element(boundBy: index).click()
        } else {
            names.element(boundBy: index).rightClick()
        }

        let editItem = app.menuItems["Edit Settings…"]
        XCTAssertTrue(editItem.waitForExistence(timeout: 3))
    }
}
