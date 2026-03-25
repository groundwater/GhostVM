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

    /// Launch the app with mock VMs populated in the list.
    static func launchWithMockVMs() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-with-vms"]
        app.launch()
        return app
    }

    /// Launch the app with mock VMs and a taller window (for Edit VM sheet).
    static func launchWithMockVMsTall() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-testing-with-vms", "--ui-testing-tall"]
        app.launch()
        return app
    }
}
