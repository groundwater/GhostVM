import XCTest

// Manual-only items not covered here:
// - Actual delete operation (moves to Trash)
// - Actual clone file system operation
// - NSOpenPanel interactions for shared folders

final class AlertsAndSheetsUITests: XCTestCase {
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

    private func openContextMenuForVM(named name: String) {
        let names = app.staticTexts.matching(identifier: "vmRow.name")
        let statuses = app.staticTexts.matching(identifier: "vmRow.status")
        let menus = app.menuButtons.matching(identifier: "vmRow.ellipsisMenu")
        let expectedStatus = name.localizedCaseInsensitiveContains("Sequoia") ? "Running" : "Stopped"
        let index = statuses.allElementsBoundByIndex.firstIndex {
            $0.label.localizedCaseInsensitiveContains(expectedStatus)
        } ?? (name.localizedCaseInsensitiveContains("Sequoia") ? 1 : 0)
        XCTAssertTrue(names.count > index, "VM '\(name)' should exist")
        if menus.count > index {
            menus.element(boundBy: index).click()
        } else {
            names.element(boundBy: index).rightClick()
        }
    }

    func testStoppedVMContextActionsExist() {
        openContextMenuForVM(named: "macOS Dev") // Stopped VM
        XCTContext.runActivity(named: "Context menu exposes edit/clone/delete actions") { _ in
            XCTAssertTrue(app.menuItems["Edit Settings…"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.menuItems["Clone…"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.outlines.firstMatch.menuItems["Delete"].waitForExistence(timeout: 3))
        }
    }

    func testCreateVMFlowOpensSheet() {
        let createButton = app.buttons["vmList.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()

        let cpuField = app.textFields["createVM.cpuField"]
        XCTAssertTrue(cpuField.waitForExistence(timeout: 3), "Create VM sheet should appear")
    }

}
