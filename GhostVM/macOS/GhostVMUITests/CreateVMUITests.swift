import XCTest

final class CreateVMUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting()

        // Open the create sheet
        let createButton = app.buttons["vmList.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testCreateSheetHasRequiredFields() {
        let cpuField = app.textFields["createVM.cpuField"]
        let memoryField = app.textFields["createVM.memoryField"]
        let diskField = app.textFields["createVM.diskField"]

        XCTAssertTrue(cpuField.waitForExistence(timeout: 3), "CPU field should exist")
        XCTAssertTrue(memoryField.exists, "Memory field should exist")
        XCTAssertTrue(diskField.exists, "Disk field should exist")
    }

    func testCancelDismissesSheet() {
        let cancelButton = app.buttons["createVM.cancelButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 3))
        cancelButton.click()

        // Sheet should dismiss — CPU field should no longer exist
        let cpuField = app.textFields["createVM.cpuField"]
        XCTAssertTrue(cpuField.waitForNonExistence(timeout: 3), "Sheet should dismiss after cancel")
    }

    func testCPUFieldAcceptsInput() {
        let cpuField = app.textFields["createVM.cpuField"]
        XCTAssertTrue(cpuField.waitForExistence(timeout: 3))

        cpuField.click()
        cpuField.typeKey("a", modifierFlags: .command) // select all
        cpuField.typeText("8")

        XCTAssertEqual(cpuField.value as? String, "8")
    }

    func testCreateButtonExists() {
        let createButton = app.buttons["createVM.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3), "Create button should exist in sheet")
    }
}
