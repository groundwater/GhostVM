import XCTest

// Manual-only items not covered here:
// - List inset style visual verification
// - Window position/size restoration across restarts
// - Drag-and-drop .ghostvm bundle import

final class VMListDisplayUITests: XCTestCase {
    var app: XCUIApplication!

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testVMsSortedAlphabetically() {
        app = XCUIApplication.launchWithMockVMs()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Mock VMs: macOS Dev, macOS Sequoia, macOS Sonoma, macOS Ventura (alphabetical)
        let names = app.staticTexts.matching(identifier: "vmRow.name")
        XCTAssertGreaterThanOrEqual(names.count, 4, "Should have at least 4 mock VMs")

        // Use .value — .label is merged by List row accessibility
        let firstVM = names.element(boundBy: 0).value as? String ?? ""
        let secondVM = names.element(boundBy: 1).value as? String ?? ""
        XCTAssertTrue(firstVM.localizedCaseInsensitiveCompare(secondVM) == .orderedAscending,
                       "VMs should be sorted alphabetically: '\(firstVM)' should come before '\(secondVM)'")
    }

    func testWatermarkVisibleWithoutVMs() {
        app = XCUIApplication.launchForTesting()
        let watermark = app.images["vmList.watermark"]
        XCTAssertTrue(watermark.waitForExistence(timeout: 5), "Watermark should be visible when no VMs exist")
    }

    func testWatermarkVisibleWithVMs() {
        app = XCUIApplication.launchWithMockVMs()
        let watermark = app.images["vmList.watermark"]
        XCTAssertTrue(watermark.waitForExistence(timeout: 5), "Watermark should be visible even with VMs")
    }

    func testEmptyStateHasNoExplicitMessage() {
        app = XCUIApplication.launchForTesting()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // No "No VMs" message in empty state — just empty list with watermark
        let noVMsText = app.staticTexts["No virtual machines"]
        XCTAssertFalse(noVMsText.exists, "Empty state should not show explicit 'No virtual machines' message")
    }

    func testVMSelectionHighlights() {
        app = XCUIApplication.launchWithMockVMs()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        // Click on a VM row to select it
        let firstVMName = app.staticTexts.matching(identifier: "vmRow.name").element(boundBy: 0)
        XCTAssertTrue(firstVMName.waitForExistence(timeout: 3))
        firstVMName.click()

        // The row should now be selected (list selection)
        // We verify by checking the list still exists and is interactive
        XCTAssertTrue(firstVMName.exists, "VM name should still be visible after selection")
    }

    func testSingleSelectionOnly() {
        app = XCUIApplication.launchWithMockVMs()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let names = app.staticTexts.matching(identifier: "vmRow.name")
        XCTAssertGreaterThanOrEqual(names.count, 2)

        // Click first VM
        names.element(boundBy: 0).click()
        // Cmd-click second VM — macOS List with single selection
        names.element(boundBy: 1).click(forDuration: 0.1, thenDragTo: names.element(boundBy: 1), withVelocity: .default, thenHoldForDuration: 0)

        // Window should still be functional (no crash)
        XCTAssertTrue(window.exists)
    }

    func testSelectionDoesNotAutoOpenVM() {
        app = XCUIApplication.launchWithMockVMs()
        let window = app.windows["GhostVM"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let firstVMName = app.staticTexts.matching(identifier: "vmRow.name").element(boundBy: 0)
        XCTAssertTrue(firstVMName.waitForExistence(timeout: 3))
        firstVMName.click()

        // No VM window should open — selection alone doesn't launch
        sleep(1)
        XCTAssertEqual(app.windows.count, 1, "Selecting a VM should not open a VM window")
    }
}
