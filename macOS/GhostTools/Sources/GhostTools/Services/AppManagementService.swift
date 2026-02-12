import AppKit

/// Service for managing running applications in the guest
final class AppManagementService {
    static let shared = AppManagementService()
    private init() {}

    struct AppInfo: Codable {
        let name: String
        let bundleId: String
        let pid: Int32
        let isActive: Bool
    }

    /// List running GUI apps (those with a Dock icon)
    func listApps() -> [AppInfo] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app in
                AppInfo(
                    name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                    bundleId: app.bundleIdentifier ?? "",
                    pid: app.processIdentifier,
                    isActive: app.processIdentifier == frontmost
                )
            }
    }

    /// Launch an app by bundle identifier
    func launchApp(bundleId: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            success = error == nil
            semaphore.signal()
        }
        semaphore.wait()
        return success
    }

    /// Activate (bring to front) an app by bundle identifier
    func activateApp(bundleId: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            return false
        }
        return app.activate()
    }

    /// Quit an app by bundle identifier
    func quitApp(bundleId: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            return false
        }
        return app.terminate()
    }
}
