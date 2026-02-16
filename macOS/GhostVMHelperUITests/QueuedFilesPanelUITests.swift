import XCTest

final class QueuedFilesPanelUITests: XCTestCase {

    private func launchWithFileCount(_ count: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--show-file-transfer",
            "--queued-file-count", "\(count)"
        ]
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
}
