import AppKit
import SwiftUI
import UserNotifications
import CoreServices

/// GhostTools version - reads from Info.plist; falls back to "dev" when running bare binary
let kGhostToolsVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

/// GhostTools build number (Unix timestamp) - used for update detection
let kGhostToolsBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

/// Target install location
let kApplicationsPath = "/Applications/GhostTools.app"

/// UserDefaults key for auto-start preference
private let kAutoStartEnabledKey = "org.ghostvm.ghosttools.autoStartEnabled"

/// Notification names
extension Notification.Name {
    static let autoStartPreferenceChanged = Notification.Name("autoStartPreferenceChanged")
    static let autoStartEnableRequested = Notification.Name("autoStartEnableRequested")
    static let autoStartDisableRequested = Notification.Name("autoStartDisableRequested")
}

/// GhostTools - Menu bar daemon for guest VM integration
/// Provides HTTP/1.1 server over vsock for host-guest communication
@main
struct GhostToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app with no main window
        Settings {
            EmptyView()
        }
    }
}

/// App delegate handles menu bar setup and server lifecycle
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var server: VsockServer?
    private var tunnelServer: TunnelServer?
    private var healthServer: HealthServer?
    private var isServerRunning = false
    private var isFilePickerOpen = false
    private var lockFileHandle: FileHandle?
    // Use bundle ID from Info.plist, fallback to hardcoded for compatibility
    private var bundleId: String {
        Bundle.main.bundleIdentifier ?? "com.yellowgreenfruit.com.ghostvm.guest-tools"
    }

    private lazy var lockFilePath: String = {
        return NSTemporaryDirectory() + bundleId + ".lock"
    }()

    /// Files queued for sending to host (accessor for FileService)
    private var filesToSend: [URL] {
        FileService.shared.listOutgoingFiles().compactMap { URL(fileURLWithPath: $0) }
    }

    // MARK: - Auto Start Preference

    /// Check if auto-start is explicitly enabled
    private var isAutoStartEnabled: Bool {
        UserDefaults.standard.object(forKey: kAutoStartEnabledKey) as? Bool ?? false
    }

    /// Check if the user explicitly set auto-start to false (not just absent/nil)
    private var isAutoStartExplicitlyDisabled: Bool {
        let value = UserDefaults.standard.object(forKey: kAutoStartEnabledKey)
        guard let boolValue = value as? Bool else { return false }
        return !boolValue
    }

    /// Set auto-start preference
    private func setAutoStartEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: kAutoStartEnabledKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // IMPORTANT: Ignore SIGPIPE signal
        //
        // When writing to a socket/pipe after the remote end has closed,
        // the OS sends SIGPIPE which terminates the process by default.
        // This happens during normal operation when:
        // - Host closes vsock connection
        // - TCP client disconnects mid-transfer
        //
        // By ignoring SIGPIPE, write() returns -1 with errno=EPIPE instead,
        // which our code handles gracefully. This is standard practice for
        // any application doing network I/O.
        signal(SIGPIPE, SIG_IGN)

        // Disable stdout buffering so logs appear immediately in launchd log files
        setbuf(stdout, nil)

        print("[GhostTools] Application launched")
        print("[GhostTools] Version: \(kGhostToolsVersion), Build: \(kGhostToolsBuild)")
        print("[GhostTools] Bundle path: \(Bundle.main.bundlePath)")

        // STEP 0: Singleton - terminate any other instances and take over
        // (Don't exit — the launch agent with KeepAlive would just restart us in a loop)
        terminateOtherInstances()

        // Acquire lock file (force-acquire since we just terminated others)
        if !acquireLockFile() {
            // Lock holder may not have exited yet — wait briefly and retry
            Thread.sleep(forTimeInterval: 1.0)
            if !acquireLockFile() {
                print("[GhostTools] Failed to acquire lock file after retry, exiting")
                NSApplication.shared.terminate(nil)
                return
            }
        }

        // STEP 1: Install LaunchAgent (only if explicitly enabled and running from /Applications)
        if isAutoStartEnabled {
            _ = installLaunchAgent()
        } else if isAutoStartExplicitlyDisabled {
            // Only uninstall if the user explicitly disabled auto-start.
            // When the key is absent (nil), leave any existing agent alone —
            // this prevents a race where a freshly-spawned KeepAlive instance
            // reads stale defaults and undoes the install.
            _ = uninstallLaunchAgent()
        }

        // STEP 4: Setup and start services
        setupMenuBar()
        print("[GhostTools] Menu bar setup complete")
        requestNotificationPermission()

        // Refresh menu when outgoing files change (e.g. host clears queue via DELETE)
        NotificationCenter.default.addObserver(forName: .outgoingFilesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateMenu()
        }

        // Handle auto-start enable/disable requests from permissions window
        NotificationCenter.default.addObserver(forName: .autoStartEnableRequested, object: nil, queue: .main) { [weak self] _ in
            self?.handleAutoStartEnableRequest()
        }
        NotificationCenter.default.addObserver(forName: .autoStartDisableRequested, object: nil, queue: .main) { [weak self] _ in
            self?.handleAutoStartDisableRequest()
        }

        startServer()
        startTunnelServer()
        startHealthServer()
        startEventPushServer()
        startPortScanner()
        startForegroundAppService()

        // Show settings window if any green dots are off (defer to next run loop)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if !PermissionsWindow.shared.allGranted(from: self) {
                PermissionsWindow.shared.show(from: self)
            }
        }
    }

    // MARK: - Installation

    /// Check if running from /Applications
    private func isRunningFromApplications() -> Bool {
        return Bundle.main.bundlePath == kApplicationsPath
    }

    /// Copy the running app bundle to /Applications using ditto.
    /// Returns nil on success, or an error message on failure.
    func installToApplications() -> String? {
        let fm = FileManager.default
        let source = Bundle.main.bundlePath

        print("[GhostTools] Installing to \(kApplicationsPath)...")
        print("[GhostTools] Source: \(source)")

        // Verify source looks like a .app bundle
        guard source.hasSuffix(".app"),
              fm.fileExists(atPath: source + "/Contents/MacOS/GhostTools") else {
            let msg = "Source is not a valid .app bundle: \(source)"
            print("[GhostTools] Install failed: \(msg)")
            return msg
        }

        // Remove existing installation
        if fm.fileExists(atPath: kApplicationsPath) {
            print("[GhostTools] Removing existing \(kApplicationsPath)...")
            let rm = Process()
            rm.executableURL = URL(fileURLWithPath: "/bin/rm")
            rm.arguments = ["-rf", kApplicationsPath]
            let rmErr = Pipe()
            rm.standardError = rmErr
            try? rm.run()
            rm.waitUntilExit()
            if rm.terminationStatus != 0 {
                let errStr = String(data: rmErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let msg = "Could not remove existing /Applications/GhostTools.app: \(errStr)"
                print("[GhostTools] Install failed: \(msg)")
                return msg
            }
        }

        // Use ditto to copy (robust cross-filesystem, preserves code signing)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [source, kApplicationsPath]
        let errPipe = Pipe()
        ditto.standardError = errPipe

        do {
            try ditto.run()
        } catch {
            let msg = "Could not run ditto: \(error)"
            print("[GhostTools] Install failed: \(msg)")
            return msg
        }
        ditto.waitUntilExit()

        if ditto.terminationStatus != 0 {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let msg = "ditto failed (exit \(ditto.terminationStatus)): \(errStr)"
            print("[GhostTools] Install failed: \(msg)")
            return msg
        }

        // Verify
        guard fm.fileExists(atPath: kApplicationsPath + "/Contents/MacOS/GhostTools") else {
            let msg = "ditto succeeded but executable missing at destination"
            print("[GhostTools] Install failed: \(msg)")
            return msg
        }

        // Register with Launch Services
        let lsregister = Process()
        lsregister.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")
        lsregister.arguments = ["-f", kApplicationsPath]
        try? lsregister.run()
        lsregister.waitUntilExit()

        print("[GhostTools] Installed to /Applications successfully")
        return nil
    }

    // MARK: - Singleton Protection

    /// Terminate all other GhostTools instances so this one takes over.
    /// Always wins — the launch agent (KeepAlive) instance should be authoritative.
    private func terminateOtherInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        // Find all GhostTools instances by executable name
        let ghostToolsApps = NSWorkspace.shared.runningApplications.filter { app in
            if let execURL = app.executableURL {
                return execURL.lastPathComponent == "GhostTools"
            }
            return false
        }

        for instance in ghostToolsApps {
            if instance.processIdentifier != currentPID {
                print("[GhostTools] Terminating old instance (PID \(instance.processIdentifier), bundle: \(instance.bundleIdentifier ?? "unknown"))")
                instance.terminate()
            }
        }

        // Brief wait for graceful termination
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func acquireLockFile() -> Bool {
        let fm = FileManager.default

        // If lock exists, check if PID is still valid
        if fm.fileExists(atPath: lockFilePath) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: lockFilePath)),
               let pidString = String(data: data, encoding: .utf8),
               let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) {

                // Check if process is still running (kill with signal 0 = test only)
                if kill(pid, 0) == 0 {
                    // Process exists
                    return false
                } else {
                    // Stale lock file, remove it
                    print("[GhostTools] Removing stale lock file (PID \(pid) not running)")
                    try? fm.removeItem(atPath: lockFilePath)
                }
            }
        }

        // Create lock file with our PID
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let pidData = "\(currentPID)".data(using: .utf8)!

        do {
            try pidData.write(to: URL(fileURLWithPath: lockFilePath))
            print("[GhostTools] Lock file created: \(lockFilePath)")
            return true
        } catch {
            print("[GhostTools] Failed to create lock file: \(error)")
            return false
        }
    }

    private func releaseLockFile() {
        try? FileManager.default.removeItem(atPath: lockFilePath)
        print("[GhostTools] Lock file released")
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Default Browser Registration

    /// Check if GhostTools is the default handler for http URLs
    func isDefaultBrowser() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        guard let currentHandler = LSCopyDefaultHandlerForURLScheme("http" as CFString)?.takeRetainedValue() as String? else {
            return false
        }
        return currentHandler.caseInsensitiveCompare(bundleID) == .orderedSame
    }

    /// Register GhostTools as the default handler for http/https URLs
    /// This enables URL forwarding from guest to host
    func registerAsDefaultBrowser() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            print("[GhostTools] No bundle identifier, skipping default browser registration")
            return
        }

        let schemes = ["http", "https"]
        for scheme in schemes {
            let result = LSSetDefaultHandlerForURLScheme(scheme as CFString, bundleID as CFString)
            if result == noErr {
                print("[GhostTools] Registered as default handler for \(scheme)")
            } else {
                print("[GhostTools] Failed to register as default handler for \(scheme): \(result)")
            }
        }
    }

    // MARK: - Launch Agent

    /// Get the launch agent plist path
    private func launchAgentPlistPath() -> URL {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        return launchAgentsDir.appendingPathComponent("\(bundleId).plist")
    }

    /// Check if launch agent is installed with correct configuration
    func isLaunchAgentInstalled() -> Bool {
        let plistPath = launchAgentPlistPath()
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return false
        }

        // Verify plist has correct content
        guard let plist = NSDictionary(contentsOf: plistPath),
              let args = plist["ProgramArguments"] as? [String],
              args.first == kApplicationsPath + "/Contents/MacOS/GhostTools",
              let runAtLoad = plist["RunAtLoad"] as? Bool,
              runAtLoad == true else {
            return false
        }

        return true
    }

    /// Install and load the launch agent
    @discardableResult
    private func installLaunchAgent() -> Bool {
        print("[GhostTools] Checking launch agent installation...")
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("\(bundleId).plist")

        // MIGRATION: Remove old launch agents with old bundle IDs
        let oldPlistPaths = [
            launchAgentsDir.appendingPathComponent("com.ghostvm.ghosttools.plist"),
            // Add other old variants if they existed
        ]

        for oldPlistPath in oldPlistPaths {
            if FileManager.default.fileExists(atPath: oldPlistPath.path) {
                print("[GhostTools] === MIGRATION: Removing old launch agent ===")
                print("[GhostTools] Old plist: \(oldPlistPath.path)")

                // Unload from launchctl (ignore errors - may not be loaded)
                let unloadOld = Process()
                unloadOld.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unloadOld.arguments = ["unload", "-w", oldPlistPath.path]  // Add -w to write disabled state

                let errorPipe = Pipe()
                unloadOld.standardError = errorPipe

                try? unloadOld.run()
                unloadOld.waitUntilExit()

                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorStr = String(data: errorData, encoding: .utf8) ?? ""

                print("[GhostTools] launchctl unload exit status: \(unloadOld.terminationStatus)")
                if !errorStr.isEmpty {
                    print("[GhostTools] launchctl unload stderr: \(errorStr)")
                }

                // Force remove the file
                do {
                    try FileManager.default.removeItem(at: oldPlistPath)
                    print("[GhostTools] Removed old plist successfully")
                } catch {
                    print("[GhostTools] Failed to remove old plist: \(error)")
                }
            }
        }

        // Always use /Applications path for the launch agent
        let executablePath = kApplicationsPath + "/Contents/MacOS/GhostTools"

        // Check if already installed with correct path and settings
        if FileManager.default.fileExists(atPath: plistPath.path) {
            if let existingPlist = NSDictionary(contentsOf: plistPath),
               let args = existingPlist["ProgramArguments"] as? [String],
               args.first == executablePath,
               let keepAlive = existingPlist["KeepAlive"] as? Bool,
               keepAlive == true {
                print("[GhostTools] Launch agent plist found at \(plistPath.path)")

                // Verify it's loaded in launchd
                let launchctlList = Process()
                launchctlList.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                launchctlList.arguments = ["list", bundleId]

                let outputPipe = Pipe()
                launchctlList.standardOutput = outputPipe
                launchctlList.standardError = outputPipe

                try? launchctlList.run()
                launchctlList.waitUntilExit()

                if launchctlList.terminationStatus == 0 {
                    print("[GhostTools] Launch agent is loaded in launchctl")
                    return true
                } else {
                    print("[GhostTools] Launch agent plist exists but not loaded in launchctl, reloading...")
                    // Fall through to reload
                }
            } else {
                // Remove outdated launch agent (wrong path or missing KeepAlive)
                print("[GhostTools] Launch agent outdated (wrong path or KeepAlive), recreating...")
                // Unload first before removing
                let unload = Process()
                unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                unload.arguments = ["unload", plistPath.path]
                try? unload.run()
                unload.waitUntilExit()
                try? FileManager.default.removeItem(at: plistPath)
            }
        } else {
            print("[GhostTools] No launch agent plist found, creating...")
        }

        // Create LaunchAgents directory if needed
        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        } catch {
            print("[GhostTools] Failed to create LaunchAgents directory: \(error)")
            return false
        }

        // Create the plist content - always point to /Applications
        // KeepAlive: true ensures launchd restarts GhostTools if it exits for any reason
        // (crash, update cycle, etc.) - critical for reliable auto-start after make debug
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GhostTools")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let plistContent: [String: Any] = [
            "Label": bundleId,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("stderr.log").path,
            "ThrottleInterval": 5
        ]

        // Write the plist
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try data.write(to: plistPath)
            print("[GhostTools] Launch agent plist written to \(plistPath.path)")

            // Load the launch agent into launchd
            print("[GhostTools] Loading launch agent into launchd...")
            let launchctlLoad = Process()
            launchctlLoad.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            launchctlLoad.arguments = ["load", "-w", plistPath.path]

            let errorPipe = Pipe()
            launchctlLoad.standardError = errorPipe

            try launchctlLoad.run()
            launchctlLoad.waitUntilExit()

            if launchctlLoad.terminationStatus == 0 {
                print("[GhostTools] Launch agent loaded successfully")

                // Show success notification
                let content = UNMutableNotificationContent()
                content.title = "GhostTools Installed"
                content.body = "GhostTools will now start automatically at login."
                content.sound = .default
                let request = UNNotificationRequest(identifier: "launch-agent-installed", content: content, trigger: nil)
                UNUserNotificationCenter.current().add(request)
                return true
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorStr = String(data: errorData, encoding: .utf8) ?? "unknown error"
                print("[GhostTools] Warning: launchctl load returned status \(launchctlLoad.terminationStatus): \(errorStr)")
                // Note: Exit status 5 is "service already loaded" which is fine
                if launchctlLoad.terminationStatus == 5 {
                    print("[GhostTools] Service already loaded (this is OK)")
                    return true
                }
                return false
            }
        } catch {
            print("[GhostTools] Failed to install launch agent: \(error)")
            print("[GhostTools] Error details: \(error.localizedDescription)")
            return false
        }
    }

    /// Uninstall the launch agent by removing the plist file.
    /// Does NOT call launchctl unload — that would kill this process
    /// if we were launched by the agent (KeepAlive). Simply removing
    /// the plist prevents launchd from restarting us and removes the
    /// agent on next login.
    @discardableResult
    private func uninstallLaunchAgent() -> Bool {
        let plistPath = launchAgentPlistPath()
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return true // Already uninstalled
        }

        print("[GhostTools] Uninstalling launch agent...")

        do {
            try FileManager.default.removeItem(at: plistPath)
            print("[GhostTools] Launch agent plist removed")
            return true
        } catch {
            print("[GhostTools] Failed to remove launch agent plist: \(error)")
            return false
        }
    }

    /// Handle auto-start enable request from permissions window.
    /// Writes the plist without launchctl load (takes effect on next login).
    @objc private func handleAutoStartEnableRequest() {
        setAutoStartEnabled(true)
        UserDefaults.standard.synchronize()
        if writeLaunchAgentPlist() {
            updateMenu()
        } else {
            setAutoStartEnabled(false)
        }
    }

    /// Handle auto-start disable request from permissions window.
    /// Removes the plist without launchctl unload (takes effect on next login).
    @objc private func handleAutoStartDisableRequest() {
        setAutoStartEnabled(false)
        UserDefaults.standard.synchronize()
        removeLaunchAgentPlist()
        updateMenu()
    }

    /// Write the launch agent plist file (no launchctl load).
    private func writeLaunchAgentPlist() -> Bool {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("\(bundleId).plist")
        let executablePath = kApplicationsPath + "/Contents/MacOS/GhostTools"

        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        } catch {
            print("[GhostTools] Failed to create LaunchAgents directory: \(error)")
            return false
        }

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GhostTools")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let plistContent: [String: Any] = [
            "Label": bundleId,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logDir.appendingPathComponent("stdout.log").path,
            "StandardErrorPath": logDir.appendingPathComponent("stderr.log").path,
            "ThrottleInterval": 5
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try data.write(to: plistPath)
            print("[GhostTools] Launch agent plist written to \(plistPath.path)")
            return true
        } catch {
            print("[GhostTools] Failed to write launch agent plist: \(error)")
            return false
        }
    }

    /// Remove the launch agent plist file (no launchctl unload).
    private func removeLaunchAgentPlist() {
        let plistPath = launchAgentPlistPath()
        if FileManager.default.fileExists(atPath: plistPath.path) {
            try? FileManager.default.removeItem(at: plistPath)
            print("[GhostTools] Launch agent plist removed")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseLockFile()
        ForegroundAppService.shared.stop()
        PortScannerService.shared.stop()
        server?.stop()
        tunnelServer?.stop()
        healthServer?.stop()
        EventPushServer.shared.stop()
    }

    // MARK: - URL Handling

    /// Handle URLs opened via this app (when set as default browser)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }

        if scheme == "http" || scheme == "https" {
            print("[GhostTools] Received URL to forward: \(url.absoluteString)")

            URLService.shared.queueURL(url)

            // Show notification
            let content = UNMutableNotificationContent()
            content.title = "Opening on Host"
            content.body = url.host ?? url.absoluteString
            content.sound = nil  // Silent - don't be annoying
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if statusItem?.button != nil {
            updateStatusIcon(connected: false)
        }

        updateMenu()
    }

    private func updateStatusIcon(connected: Bool) {
        guard let button = statusItem?.button else { return }
        if let image = NSImage(systemSymbolName: "gearshape.2.fill", accessibilityDescription: "GhostTools") {
            let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.image = image.withSymbolConfiguration(sizeConfig)
        } else {
            button.title = "●"
        }
        button.alphaValue = connected ? 1.0 : 0.5
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Title with version (disabled)
        let titleItem = NSMenuItem(title: "GhostTools v\(kGhostToolsVersion)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Status item
        let statusText = isServerRunning ? "Status: Running" : "Status: Stopped"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())

        // Auto Start toggle
        let autoStartItem = NSMenuItem(
            title: "Auto Start",
            action: #selector(toggleAutoStart),
            keyEquivalent: ""
        )
        autoStartItem.target = self
        autoStartItem.state = isAutoStartEnabled ? .on : .off
        menu.addItem(autoStartItem)

        // Permissions window
        let permissionsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showPermissions),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(NSMenuItem.separator())

        // Send to Host menu item
        let sendToHostItem = NSMenuItem(
            title: "Send to Host...",
            action: #selector(sendToHost),
            keyEquivalent: ""
        )
        sendToHostItem.target = self
        menu.addItem(sendToHostItem)

        // Show queued files submenu if any
        if !filesToSend.isEmpty {
            let queuedItem = NSMenuItem(title: "Queued Files (\(filesToSend.count))", action: nil, keyEquivalent: "")
            let queuedMenu = NSMenu()

            for url in filesToSend {
                let fileItem = NSMenuItem(title: url.lastPathComponent, action: nil, keyEquivalent: "")
                fileItem.isEnabled = false
                queuedMenu.addItem(fileItem)
            }

            queuedMenu.addItem(NSMenuItem.separator())

            let clearItem = NSMenuItem(title: "Clear Queue", action: #selector(clearFileQueue), keyEquivalent: "")
            clearItem.target = self
            queuedMenu.addItem(clearItem)

            queuedItem.submenu = queuedMenu
            menu.addItem(queuedItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit GhostTools", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    @objc private func sendToHost() {
        guard !isFilePickerOpen else { return }
        isFilePickerOpen = true

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select files to send to host"
        panel.prompt = "Send"

        // Force the panel above all other windows (GhostTools is a menu bar
        // app with no key window, so the panel would otherwise appear behind
        // the frontmost app).
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)

        panel.begin { [weak self] response in
            self?.isFilePickerOpen = false
            guard response == .OK else { return }
            let urls = panel.urls
            guard !urls.isEmpty else { return }

            Task { @MainActor in
                self?.queueFilesForHost(urls)
            }
        }
    }

    private func queueFilesForHost(_ urls: [URL]) {
        // Add files to queue (they will be available via GET /api/v1/files)
        FileService.shared.queueOutgoingFiles(urls)
        updateMenu()

        // Show notification using UserNotifications
        let content = UNMutableNotificationContent()
        content.title = "Files Ready"
        content.body = "\(urls.count) file(s) queued for host. The host can now fetch them."
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    @objc private func clearFileQueue() {
        FileService.shared.clearOutgoingFiles()
        updateMenu()
    }

    @objc private func showPermissions() {
        PermissionsWindow.shared.show(from: self)
    }

    /// Called by PermissionsWindow to copy the app to /Applications.
    /// Returns nil on success, error string on failure.
    func performCopyToApplications() -> String? {
        return installToApplications()
    }

    @objc private func toggleAutoStart() {
        let newState = !isAutoStartEnabled
        setAutoStartEnabled(newState)
        UserDefaults.standard.synchronize()

        if newState {
            if !installLaunchAgent() {
                setAutoStartEnabled(false) // Revert on failure
            }
        } else {
            if !uninstallLaunchAgent() {
                setAutoStartEnabled(true) // Revert on failure
            }
        }

        updateMenu()
        NotificationCenter.default.post(name: .autoStartPreferenceChanged, object: nil)
    }

    private func startServer() {
        print("[GhostTools] startServer() called")
        Task {
            do {
                print("[GhostTools] Creating router...")
                let router = Router()
                print("[GhostTools] Creating VsockServer on port 5000...")
                server = VsockServer(port: 5000, router: router)

                server?.onStatusChange = { [weak self] running in
                    Task { @MainActor in
                        print("[GhostTools] Server status changed: \(running)")
                        self?.isServerRunning = running
                        self?.updateStatusIcon(connected: running)
                        self?.updateMenu()
                    }
                }

                print("[GhostTools] Starting vsock server...")
                try await server?.start()
                print("[GhostTools] Server started successfully")
            } catch {
                print("[GhostTools] Failed to start server: \(error)")
                print("[GhostTools] Error details: \(String(describing: error))")
                isServerRunning = false
                updateStatusIcon(connected: false)
                updateMenu()
            }
        }
    }

    private func startTunnelServer() {
        print("[GhostTools] startTunnelServer() called")
        Task {
            do {
                tunnelServer = TunnelServer()
                print("[GhostTools] Starting tunnel server on vsock port 5001...")
                try await tunnelServer?.start()
                print("[GhostTools] Tunnel server started successfully")
            } catch {
                print("[GhostTools] Failed to start tunnel server: \(error)")
            }
        }
    }

    private func startHealthServer() {
        print("[GhostTools] startHealthServer() called")
        Task {
            do {
                healthServer = HealthServer()
                print("[GhostTools] Starting health server on vsock port 5002...")
                try await healthServer?.start()
                print("[GhostTools] Health server started successfully")
            } catch {
                print("[GhostTools] Failed to start health server: \(error)")
            }
        }
    }

    private func startEventPushServer() {
        print("[GhostTools] startEventPushServer() called")
        Task {
            do {
                print("[GhostTools] Starting event push server on vsock port 5003...")
                try await EventPushServer.shared.start()
                print("[GhostTools] Event push server started successfully")
            } catch {
                print("[GhostTools] Failed to start event push server: \(error)")
            }
        }
    }

    private func startPortScanner() {
        print("[GhostTools] Starting port scanner service...")
        PortScannerService.shared.start()
    }

    private func startForegroundAppService() {
        print("[GhostTools] Starting foreground app service...")
        ForegroundAppService.shared.start()
    }
}

