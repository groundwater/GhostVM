import Foundation
import AppKit

enum AppIconAdapter {
    @MainActor
    static func updateIcon(for mode: DemoIconMode) {
        let app = NSApplication.shared
        let name: String?

        switch mode {
        case .system:
            // Use the default application icon from the bundle.
            name = NSImage.applicationIconName
        case .light:
            name = "ghostvm"
        case .dark:
            name = "ghostvm-dark"
        }

        if let name, let image = NSImage(named: name) {
            app.applicationIconImage = image
        }
    }
}

