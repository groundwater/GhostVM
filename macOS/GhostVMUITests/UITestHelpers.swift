import XCTest

/// Shared helpers for GhostVM UI tests.
extension XCUIApplication {
    /// Launch the app in UI testing mode with a clean, empty VM list.
    static func launchForTesting() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        return app
    }
}
