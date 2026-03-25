import XCTest

final class HelperScreenshotTests: XCTestCase {

    // MARK: - Helper Window

    func testCaptureHelperWindow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--wallpaper", "Desktop-Redwood"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        sleep(1)

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "helper-window"
        attachment.lifetime = .keepAlways
        add(attachment)
        ScreenshotExporter.save(screenshot, name: "helper-window")
    }

    // MARK: - Helper Window with VS Code content

    func testCaptureHelperWindowCode() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--wallpaper", "Desktop-Redwood", "--content-image", "Window-Code"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        sleep(1)

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "helper-window-code"
        attachment.lifetime = .keepAlways
        add(attachment)
        ScreenshotExporter.save(screenshot, name: "helper-window-code")
    }

    // MARK: - Helper Window with Terminal content

    func testCaptureHelperWindowTerminal() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--wallpaper", "Desktop-Redwood", "--content-image", "Window-Terminal"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        sleep(1)

        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "helper-window-terminal"
        attachment.lifetime = .keepAlways
        add(attachment)
        ScreenshotExporter.save(screenshot, name: "helper-window-terminal")
    }

    // MARK: - Clipboard Permission Prompt

    func testCaptureClipboardPrompt() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-clipboard-prompt"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5))

        let screenshot = popover.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "clipboard-permission"
        attachment.lifetime = .keepAlways
        add(attachment)
        ScreenshotExporter.save(screenshot, name: "clipboard-permission")
    }

    // MARK: - Port Forward Notification

    func testCapturePortForward() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-port-forward"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5))

        let screenshot = popover.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "port-forward-notification"
        attachment.lifetime = .keepAlways
        add(attachment)
        ScreenshotExporter.save(screenshot, name: "port-forward-notification")
    }

    // MARK: - File Transfer Prompt

    func testCaptureFileTransfer() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-file-transfer"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5))

        let screenshot = popover.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "file-transfer-prompt"
        attachment.lifetime = .keepAlways
        add(attachment)
        ScreenshotExporter.save(screenshot, name: "file-transfer-prompt")
    }

    // MARK: - Shared Folders

    func testCaptureSharedFolders() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--show-shared-folders"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let sheet = window.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        let screenshot = sheet.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "shared-folders"
        attachment.lifetime = .keepAlways
        add(attachment)
        ScreenshotExporter.save(screenshot, name: "shared-folders")
    }
}
