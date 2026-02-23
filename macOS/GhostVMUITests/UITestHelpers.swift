import XCTest

/// Shared helpers for GhostVM UI tests.
extension XCUIApplication {
    /// Launch the app in UI testing mode with a clean, empty VM list.
    static func launchForTesting(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + extraArguments
        app.launch()
        return app
    }
}
