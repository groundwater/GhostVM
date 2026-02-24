import XCTest

// Manual-only items not covered here:
// - VM lifecycle (actual start/stop/suspend operations)
// - Keyboard shortcuts requiring active VM (Cmd+R, Cmd+Option+S, Cmd+Option+Q)

final class ContextMenuUITests: XCTestCase {
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

    // MARK: - Context Menu Item Existence

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

    private func assertMenuItemsExist(_ titles: [String], timeout: TimeInterval = 3) {
        for title in titles {
            XCTAssertTrue(app.menuItems[title].waitForExistence(timeout: timeout), "Context menu should have \(title) item")
        }
    }

    func testStoppedVMContextMenuItems() {
        openContextMenuForVM(named: "macOS Dev") // Stopped VM
        assertMenuItemsExist([
            "Start",
            "Boot to Recovery",
            "Edit Settings…",
            "Rename…",
            "Clone…",
            "Show in Finder",
            "Remove from List",
            "Delete",
            "Snapshots"
        ])
    }

    func testRunningVMContextMenuItems() {
        openContextMenuForVM(named: "macOS Sequoia") // Running
        assertMenuItemsExist([
            "Start",
            "Suspend",
            "Shut Down",
            "Terminate"
        ])
    }
}
