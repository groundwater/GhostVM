import XCTest

final class VMStartErrorUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.launchForTesting(extraArguments: [
            "--ui-testing-with-vms",
            "--ui-testing-force-start-error",
            "Bridged network interface 'stale-iface-id' is not available on this Mac."
        ])
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testStartFailureDisplaysExplicitBridgedInterfaceError() {
        let playButton = app.buttons["vmRow.playButton"].firstMatch
        XCTAssertTrue(playButton.waitForExistence(timeout: 5), "Expected at least one VM play button")
        playButton.click()

        let title = app.staticTexts["Failed to Start VM"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Expected VM start error overlay title")

        let message = app.staticTexts["Bridged network interface 'stale-iface-id' is not available on this Mac."]
        XCTAssertTrue(message.waitForExistence(timeout: 5), "Expected explicit bridged interface error message")
    }
}
