import XCTest

enum ScreenshotExporter {
    /// Saves a screenshot PNG to the sandbox temp directory as <name>.png.
    /// The Makefile finds these via the sandbox container path.
    static func save(_ screenshot: XCUIScreenshot, name: String) {
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GhostVM-Screenshots")
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let outputURL = outputDir.appendingPathComponent("\(name).png")
        let data = screenshot.pngRepresentation
        do {
            try data.write(to: outputURL)
            // Print the path so the Makefile can find it
            print("SCREENSHOT_EXPORTED: \(outputURL.path)")
            NSLog("ScreenshotExporter: Saved %@ (%d bytes)", outputURL.path, data.count)
        } catch {
            NSLog("ScreenshotExporter: Failed to save %@: %@", name, error.localizedDescription)
        }
    }
}
