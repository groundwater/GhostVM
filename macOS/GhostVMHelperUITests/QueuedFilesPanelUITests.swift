import XCTest

final class QueuedFilesPanelUITests: XCTestCase {

    private func launchWithFileCount(_ count: Int, stripPanelItems: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        var args = [
            "--ui-testing",
            "--show-file-transfer",
            "--queued-file-count", "\(count)"
        ]
        if stripPanelItems {
            args.append("--strip-panel-items")
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    /// Find a file row label by its accessibility identifier within the popover's scroll view.
    private func row(_ index: Int, in popover: XCUIElement) -> XCUIElement {
        popover.scrollViews["queuedFiles.scrollView"].staticTexts["queuedFiles.row.\(index)"]
    }

    // MARK: - Single File

    func testSingleFileNoScroll() {
        let app = launchWithFileCount(1)

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Popover should appear")

        XCTAssertTrue(popover.staticTexts["1 file ready to download"].exists,
                       "Subtitle should show singular form")

        let row0 = row(0, in: popover)
        XCTAssertTrue(row0.waitForExistence(timeout: 2), "Row 0 should exist")
        XCTAssertTrue(row0.isHittable, "Row 0 should be visible (hittable)")
    }

    // MARK: - Five Files

    func testFiveFilesNoScroll() {
        let app = launchWithFileCount(5)

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Popover should appear")

        XCTAssertTrue(popover.staticTexts["5 files ready to download"].exists,
                       "Subtitle should show 5 files")

        for i in 0..<5 {
            let r = row(i, in: popover)
            XCTAssertTrue(r.waitForExistence(timeout: 2), "Row \(i) should exist")
            XCTAssertTrue(r.isHittable, "Row \(i) should be visible (hittable)")
        }
    }

    // MARK: - Ten Files

    func testTenFilesNoScroll() {
        let app = launchWithFileCount(10)

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Popover should appear")

        XCTAssertTrue(popover.staticTexts["10 files ready to download"].exists,
                       "Subtitle should show 10 files")

        for i in 0..<10 {
            let r = row(i, in: popover)
            XCTAssertTrue(r.waitForExistence(timeout: 2), "Row \(i) should exist")
            XCTAssertTrue(r.isHittable, "Row \(i) should be visible (hittable)")
        }
    }

    // MARK: - Fifteen Files (Scrolling)

    func testFifteenFilesScrolls() {
        let app = launchWithFileCount(15)

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Popover should appear")

        XCTAssertTrue(popover.staticTexts["15 files ready to download"].exists,
                       "Subtitle should show 15 files")

        // First 10 rows should be visible
        for i in 0..<10 {
            let r = row(i, in: popover)
            XCTAssertTrue(r.waitForExistence(timeout: 2), "Row \(i) should exist")
            XCTAssertTrue(r.isHittable, "Row \(i) should be visible (hittable)")
        }

        // Last row should exist but NOT be hittable (clipped by scroll view)
        let lastRow = row(14, in: popover)
        XCTAssertTrue(lastRow.exists, "Row 14 should exist in the hierarchy")
        XCTAssertFalse(lastRow.isHittable, "Row 14 should NOT be hittable (off-screen, needs scroll)")
    }

    // MARK: - Sheet Fallback (toolbar items stripped)

    func testSheetFallbackWhenToolbarItemMissing() {
        let app = launchWithFileCount(3, stripPanelItems: true)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Sheet should appear when toolbar item is removed")

        XCTAssertTrue(sheet.staticTexts["3 files ready to download"].exists,
                       "Subtitle should show 3 files")

        XCTAssertTrue(sheet.buttons["queuedFiles.saveButton"].waitForExistence(timeout: 2),
                       "Save button should exist in sheet")
        XCTAssertTrue(sheet.buttons["queuedFiles.declineButton"].exists,
                       "Decline button should exist in sheet")
    }

    func testSheetFallbackShowsFileRows() {
        let app = launchWithFileCount(5, stripPanelItems: true)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Sheet should appear")

        XCTAssertTrue(sheet.staticTexts["5 files ready to download"].exists,
                       "Subtitle should show 5 files")

        // Verify file rows are present in the sheet
        for i in 0..<5 {
            let fileRow = sheet.staticTexts["queuedFiles.row.\(i)"]
            XCTAssertTrue(fileRow.waitForExistence(timeout: 2), "Row \(i) should exist in sheet")
        }
    }
}
