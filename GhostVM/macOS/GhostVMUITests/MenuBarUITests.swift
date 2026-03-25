import XCTest

// Manual-only items not covered here:
// - Keyboard shortcuts requiring active VM session (Cmd+R, Cmd+Option+S, Cmd+Option+Q)
// - Clipboard Sync submenu requires active VM session
// - Dock icon changes

final class MenuBarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testAboutMenuItemExists() {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["GhostVM"].click()
        let aboutItem = app.menuItems["About GhostVM"]
        XCTAssertTrue(aboutItem.waitForExistence(timeout: 3), "About GhostVM menu item should exist")
        // Dismiss menu
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsMenuItemExists() {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["GhostVM"].click()
        let settingsItem = app.menuItems["Settings…"]
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 3), "Settings menu item should exist")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testCheckForUpdatesMenuItemExists() {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["GhostVM"].click()
        let updateItem = app.menuItems["Check for Updates…"]
        XCTAssertTrue(updateItem.waitForExistence(timeout: 3), "Check for Updates menu item should exist")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testVMMenuExists() {
        let menuBar = app.menuBars.firstMatch
        let vmMenu = menuBar.menuBarItems["VM"]
        XCTAssertTrue(vmMenu.waitForExistence(timeout: 3), "VM menu should exist in menu bar")
        vmMenu.click()

        let startItem = app.menuItems["Start"]
        XCTAssertTrue(startItem.waitForExistence(timeout: 3), "VM menu should have Start item")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testVMMenuHasSuspendAndShutDown() {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["VM"].click()

        let suspendItem = app.menuItems["Suspend"]
        let shutDownItem = app.menuItems["Shut Down"]
        let terminateItem = app.menuItems["Terminate"]

        XCTAssertTrue(suspendItem.waitForExistence(timeout: 3), "VM menu should have Suspend")
        XCTAssertTrue(shutDownItem.exists, "VM menu should have Shut Down")
        XCTAssertTrue(terminateItem.exists, "VM menu should have Terminate")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testWindowMenuHasStandardItems() {
        let menuBar = app.menuBars.firstMatch
        let windowMenu = menuBar.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 3), "Window menu should exist")
        windowMenu.click()

        // Standard Window menu items
        let virtualMachinesItem = app.menuItems["Virtual Machines"]
        let restoreImagesItem = app.menuItems["Restore Images"]
        XCTAssertTrue(virtualMachinesItem.waitForExistence(timeout: 3), "Window menu should have Virtual Machines item")
        XCTAssertTrue(restoreImagesItem.exists, "Window menu should have Restore Images item")
        app.typeKey(.escape, modifierFlags: [])
    }
}
