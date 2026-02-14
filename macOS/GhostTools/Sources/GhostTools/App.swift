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
private let kAutoStartEnabledKey = "com.ghostvm.ghosttools.autoStartEnabled"

/// Notification names
extension Notification.Name {
    static let autoStartPreferenceChanged = Notification.Name("autoStartPreferenceChanged")
    static let autoStartEnableRequested = Notification.Name("autoStartEnableRequested")
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
    private var updateTimer: Timer?
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

        // STEP 1: Check for updates FIRST (before anything else)
        if checkForUpdatesAndRelaunch() {
            // Update in progress, will relaunch - this instance exits
            return
        }

        // STEP 2: Ensure we're in /Applications
        if !isRunningFromApplications() {
            print("[GhostTools] ERROR: Not in /Applications and installation failed")
            print("[GhostTools] Bundle path: \(Bundle.main.bundlePath)")
            print("[GhostTools] Expected path: \(kApplicationsPath)")

            // Show error notification to user
            let content = UNMutableNotificationContent()
            content.title = "GhostTools Installation Failed"
            content.body = "Failed to install to /Applications. Please manually copy GhostTools.app to /Applications and launch it from there."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "install-failed", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)

            // Wait a bit for notification to be delivered
            Thread.sleep(forTimeInterval: 2.0)
            exit(1)
        }

        // STEP 3: Install LaunchAgent (only if explicitly enabled)
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
        PermissionsWindow.shared.showIfNeeded()
        registerAsDefaultBrowser()

        // Refresh menu when outgoing files change (e.g. host clears queue via DELETE)
        NotificationCenter.default.addObserver(forName: .outgoingFilesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateMenu()
        }

        // Handle auto-start enable request from permissions window
        NotificationCenter.default.addObserver(forName: .autoStartEnableRequested, object: nil, queue: .main) { [weak self] _ in
            self?.handleAutoStartEnableRequest()
        }

        startServer()
        startTunnelServer()
        startHealthServer()
        startEventPushServer()
        startPortScanner()
        startForegroundAppService()

        // STEP 5: Start update checker (checks every 10s for new DMG)
        startUpdateChecker()
    }

    // MARK: - Unified Update Check and Relaunch

    /// Check for updates from all sources and relaunch if found
    /// Sources checked in order:
    /// 1. /Volumes/GhostTools/GhostTools.app (mounted DMG)
    /// 2. /Volumes/*/GhostTools.app (shared folders for debug)
    /// Returns: true if updating (caller should exit), false to continue
    private func checkForUpdatesAndRelaunch() -> Bool {
        let installedPath = kApplicationsPath

        // Get current installed version and build
        guard let installed = getInstalledVersion() else {
            // Not installed yet, check if we should install
            return installFromFirstAvailableSource()
        }

        print("[GhostTools] Installed: v\(installed.version) build \(installed.build)")
        print("[GhostTools] Current: v\(kGhostToolsVersion) build \(kGhostToolsBuild)")

        // Check update sources in order
        let updateSources = findUpdateSources()

        for source in updateSources {
            guard let sourceInfo = getVersionFromBundle(source) else { continue }

            // Compare versions and builds
            if shouldUpdate(from: installed.version, to: sourceInfo.version,
                           installedBuild: installed.build, sourceBuild: sourceInfo.build) {
                print("[GhostTools] Update found at \(source) (v\(sourceInfo.version) build \(sourceInfo.build))")
                return performUpdate(from: source, newVersion: sourceInfo.version)
            }
        }

        // If we're not running from /Applications, launch the installed version and exit
        let currentBundle = Bundle.main.bundlePath
        if currentBundle != installedPath {
            print("[GhostTools] Running from \(currentBundle), launching installed version")
            launchInstalledAndTerminate()
            return true
        }

        return false
    }

    /// Check if running from /Applications
    private func isRunningFromApplications() -> Bool {
        return Bundle.main.bundlePath == kApplicationsPath
    }

    /// Find all potential update sources
    private func findUpdateSources() -> [String] {
        var sources: [String] = []
        let fm = FileManager.default

        // Source 1: Mounted DMG
        let dmgPath = "/Volumes/GhostTools/GhostTools.app"
        if fm.fileExists(atPath: dmgPath) {
            sources.append(dmgPath)
        }

        // Source 2: Shared folders (for debug updates without restart)
        if let volumesContents = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumesContents {
                let sharedGhostTools = "/Volumes/\(volume)/GhostTools.app"
                if volume != "GhostTools" && fm.fileExists(atPath: sharedGhostTools) {
                    sources.append(sharedGhostTools)
                }
            }
        }

        return sources
    }

    /// Get installed version and build from /Applications
    private func getInstalledVersion() -> (version: String, build: String)? {
        let installedPlistPath = kApplicationsPath + "/Contents/Info.plist"
        guard let installedPlist = NSDictionary(contentsOfFile: installedPlistPath),
              let version = installedPlist["CFBundleShortVersionString"] as? String,
              let build = installedPlist["CFBundleVersion"] as? String else {
            return nil
        }
        return (version, build)
    }

    /// Get version and build from any bundle path
    private func getVersionFromBundle(_ bundlePath: String) -> (version: String, build: String)? {
        let plistPath = bundlePath + "/Contents/Info.plist"
        guard let plist = NSDictionary(contentsOfFile: plistPath) else {
            print("[GhostTools] Failed to read plist at \(plistPath)")
            return nil
        }

        guard let version = plist["CFBundleShortVersionString"] as? String else {
            print("[GhostTools] No CFBundleShortVersionString in plist at \(plistPath)")
            return nil
        }

        guard let build = plist["CFBundleVersion"] as? String else {
            print("[GhostTools] No CFBundleVersion in plist at \(plistPath)")
            return nil
        }

        print("[GhostTools] Read version info from \(bundlePath): v\(version) build \(build)")
        return (version, build)
    }

    /// Compare versions and builds to determine if update is needed
    /// Primary strategy: Compare CFBundleVersion (build timestamps)
    /// Fallback strategy: Compare CFBundleShortVersionString (semantic versions)
    private func shouldUpdate(from installedVersion: String, to sourceVersion: String,
                             installedBuild: String, sourceBuild: String) -> Bool {
        // Parse build strings as integers (Unix timestamps)
        if let installedBuildNum = Int(installedBuild),
           let sourceBuildNum = Int(sourceBuild) {
            // Both have numeric build timestamps - prefer timestamp comparison
            if sourceBuildNum > installedBuildNum {
                return true
            }
            // If builds are identical, check semantic version as tiebreaker
            if sourceBuildNum == installedBuildNum {
                return sourceVersion.compare(installedVersion, options: .numeric) == .orderedDescending
            }
            return false
        }

        // Fallback: if build numbers aren't timestamps, use semantic version comparison
        return sourceVersion.compare(installedVersion, options: .numeric) == .orderedDescending
    }

    /// Install from the first available source (DMG or shared folder)
    private func installFromFirstAvailableSource() -> Bool {
        let sources = findUpdateSources()

        for source in sources {
            if let sourceInfo = getVersionFromBundle(source) {
                print("[GhostTools] Not installed, installing from \(source)...")
                return performUpdate(from: source, newVersion: sourceInfo.version)
            }
        }

        print("[GhostTools] No installation source found")
        return false
    }

    /// Perform the update from the source app path
    private func performUpdate(from sourcePath: String, newVersion: String) -> Bool {
        // Cancel timer first to prevent multiple updates
        updateTimer?.invalidate()
        updateTimer = nil

        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = URL(fileURLWithPath: kApplicationsPath)

        print("[GhostTools] Updating from \(sourcePath) (version \(newVersion))...")

        do {
            // Remove existing installation
            if fm.fileExists(atPath: kApplicationsPath) {
                print("[GhostTools] Removing existing installation...")
                try fm.removeItem(at: destURL)
            }

            // Copy new version
            print("[GhostTools] Copying \(sourcePath) to \(kApplicationsPath)...")
            try fm.copyItem(at: sourceURL, to: destURL)
            print("[GhostTools] Copy complete")

            // Verify the copy
            guard fm.fileExists(atPath: kApplicationsPath) else {
                print("[GhostTools] ERROR: Copy succeeded but destination doesn't exist!")
                return false
            }
            print("[GhostTools] Installation verified")

            // Register with Launch Services
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
            let lsProcess = Process()
            lsProcess.executableURL = URL(fileURLWithPath: lsregister)
            lsProcess.arguments = ["-f", kApplicationsPath]
            try lsProcess.run()
            lsProcess.waitUntilExit()
            print("[GhostTools] Registered with Launch Services")

            // Terminate other instances
            terminateOtherInstances()

            // Launch the newly installed version directly, then exit
            let installedExecutable = kApplicationsPath + "/Contents/MacOS/GhostTools"
            print("[GhostTools] Launching \(installedExecutable) (new version)...")
            let launchProcess = Process()
            launchProcess.executableURL = URL(fileURLWithPath: installedExecutable)
            try launchProcess.run()
            print("[GhostTools] Launched new version (PID \(launchProcess.processIdentifier)), exiting...")
            exit(0)

        } catch {
            print("[GhostTools] Update failed: \(error)")
            print("[GhostTools] Error details: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("[GhostTools] Error domain: \(nsError.domain), code: \(nsError.code)")
                print("[GhostTools] Error userInfo: \(nsError.userInfo)")
            }
            return false
        }
    }

    /// Launch the /Applications copy and exit this instance
    private func launchInstalledAndTerminate() {
        terminateOtherInstances()

        let installedExecutable = kApplicationsPath + "/Contents/MacOS/GhostTools"
        print("[GhostTools] Launching \(installedExecutable)...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: installedExecutable)
        do {
            try process.run()
            print("[GhostTools] Launched installed version (PID \(process.processIdentifier)), exiting DMG instance...")
        } catch {
            print("[GhostTools] ERROR: Failed to launch installed version: \(error)")
        }
        exit(0)
    }

    /// Periodically check for updates from mounted volumes
    private func startUpdateChecker() {
        // Check every 10 seconds for mounted DMGs with updates
        updateTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            if self?.checkForUpdatesAndRelaunch() == true {
                // Update in progress - terminate() will handle exit
            }
        }
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

    /// Register GhostTools as the default handler for http/https URLs
    /// This enables URL forwarding from guest to host
    private func registerAsDefaultBrowser() {
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

    /// Uninstall and unload the launch agent
    @discardableResult
    private func uninstallLaunchAgent() -> Bool {
        let plistPath = launchAgentPlistPath()
        guard FileManager.default.fileExists(atPath: plistPath.path) else {
            return true // Already uninstalled
        }

        print("[GhostTools] Uninstalling launch agent...")

        // Unload from launchctl with -w flag to write disabled state
        // This prevents KeepAlive from auto-reloading
        let unload = Process()
        unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unload.arguments = ["unload", "-w", plistPath.path]

        let errorPipe = Pipe()
        unload.standardError = errorPipe

        try? unload.run()
        unload.waitUntilExit()

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let errorStr = String(data: errorData, encoding: .utf8) ?? ""

        print("[GhostTools] launchctl unload exit status: \(unload.terminationStatus)")
        if !errorStr.isEmpty && unload.terminationStatus != 0 {
            print("[GhostTools] launchctl unload stderr: \(errorStr)")
        }

        // Delete the plist file
        do {
            try FileManager.default.removeItem(at: plistPath)
            print("[GhostTools] Launch agent plist removed")
            return true
        } catch {
            print("[GhostTools] Failed to remove launch agent plist: \(error)")
            return false
        }
    }

    /// Handle auto-start enable request from permissions window
    @objc private func handleAutoStartEnableRequest() {
        setAutoStartEnabled(true)
        UserDefaults.standard.synchronize()
        if installLaunchAgent() {
            updateMenu()
            NotificationCenter.default.post(name: .autoStartPreferenceChanged, object: nil)
        } else {
            setAutoStartEnabled(false) // Revert on failure
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

