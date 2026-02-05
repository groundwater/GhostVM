import AppKit
import Foundation

/// GhostVMHelper - Lightweight helper app that provides a separate Dock icon for each VM.
///
/// Launch arguments:
///   --vm-uuid <uuid>    The unique identifier for this VM
///   --vm-name <name>    The display name for this VM
///
/// Communication (via DistributedNotificationCenter):
///   - Posts "com.ghostvm.helper.activated.<uuid>" when Dock icon clicked
///   - Listens for "com.ghostvm.helper.quit.<uuid>" to terminate
///   - Listens for "com.ghostvm.helper.ping" and responds with "com.ghostvm.helper.pong.<uuid>"
///
final class HelperAppDelegate: NSObject, NSApplicationDelegate {
    private var vmUUID: String = ""
    private var vmName: String = ""
    private let center = DistributedNotificationCenter.default()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Parse command line arguments
        let args = ProcessInfo.processInfo.arguments
        if let uuidIndex = args.firstIndex(of: "--vm-uuid"), uuidIndex + 1 < args.count {
            vmUUID = args[uuidIndex + 1]
        }
        if let nameIndex = args.firstIndex(of: "--vm-name"), nameIndex + 1 < args.count {
            vmName = args[nameIndex + 1]
        }

        guard !vmUUID.isEmpty else {
            NSLog("GhostVMHelper: Missing --vm-uuid argument, exiting")
            NSApp.terminate(nil)
            return
        }

        NSLog("GhostVMHelper: Started for VM '\(vmName)' (UUID: \(vmUUID))")

        // Set activation policy to show in Dock
        NSApp.setActivationPolicy(.regular)

        // Listen for quit signal from main app
        center.addObserver(
            self,
            selector: #selector(handleQuitNotification),
            name: NSNotification.Name("com.ghostvm.helper.quit.\(vmUUID)"),
            object: nil
        )

        // Listen for ping requests (for health checks)
        center.addObserver(
            self,
            selector: #selector(handlePingNotification),
            name: NSNotification.Name("com.ghostvm.helper.ping"),
            object: nil
        )

        // Notify main app that we're ready
        center.postNotificationName(
            NSNotification.Name("com.ghostvm.helper.ready.\(vmUUID)"),
            object: nil,
            userInfo: ["pid": ProcessInfo.processInfo.processIdentifier],
            deliverImmediately: true
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !vmUUID.isEmpty else { return }

        NSLog("GhostVMHelper: Dock icon clicked for VM '\(vmName)'")

        // Notify main app to bring VM window to focus
        center.postNotificationName(
            NSNotification.Name("com.ghostvm.helper.activated.\(vmUUID)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running even without windows - we're Dock-only
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // This is called when Dock icon is clicked while app is already active
        applicationDidBecomeActive(Notification(name: .init("reopen")))
        return true
    }

    @objc private func handleQuitNotification(_ notification: Notification) {
        NSLog("GhostVMHelper: Received quit notification for VM '\(vmName)'")
        NSApp.terminate(nil)
    }

    @objc private func handlePingNotification(_ notification: Notification) {
        // Respond to ping with our UUID
        center.postNotificationName(
            NSNotification.Name("com.ghostvm.helper.pong.\(vmUUID)"),
            object: nil,
            userInfo: ["pid": ProcessInfo.processInfo.processIdentifier],
            deliverImmediately: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("GhostVMHelper: Terminating for VM '\(vmName)'")
        center.removeObserver(self)
    }
}

// Main entry point
let delegate = HelperAppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
