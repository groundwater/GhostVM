import XCTest

// Manual-only items not covered here:
// - Button style (.borderedProminent) verification
// - Exact button positioning/spacing

final class HeaderBarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testCreateButtonIsVisibleAndHittable() {
        let createButton = app.buttons["vmList.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5), "Create button should be visible")
        XCTAssertTrue(createButton.isHittable, "Create button should be hittable")
    }

    func testImagesButtonIsVisible() {
        let imagesButton = app.buttons["vmList.imagesButton"]
        XCTAssertTrue(imagesButton.waitForExistence(timeout: 5), "Images button should be visible")
        XCTAssertTrue(imagesButton.isHittable, "Images button should be hittable")
    }

    func testCreateButtonOpensSheet() {
        let createButton = app.buttons["vmList.createButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.click()

        let cpuField = app.textFields["createVM.cpuField"]
        XCTAssertTrue(cpuField.waitForExistence(timeout: 3), "Create VM sheet should open with CPU field")
    }

    func testImagesButtonOpensRestoreImagesWindow() {
        let imagesButton = app.buttons["vmList.imagesButton"]
        XCTAssertTrue(imagesButton.waitForExistence(timeout: 5))
        imagesButton.click()

        let restoreWindow = app.windows["Restore Images"]
        XCTAssertTrue(restoreWindow.waitForExistence(timeout: 3), "Restore Images window should open")
    }

    func testCreateAndImagesButtonsCoexist() {
        let createButton = app.buttons["vmList.createButton"]
        let imagesButton = app.buttons["vmList.imagesButton"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        XCTAssertTrue(imagesButton.exists, "Both Create and Images buttons should exist simultaneously")
    }
}
