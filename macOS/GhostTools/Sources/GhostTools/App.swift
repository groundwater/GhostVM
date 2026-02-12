import AppKit
import SwiftUI
import UserNotifications
import CoreServices

/// GhostTools version - reads from Info.plist; falls back to "dev" when running bare binary
let kGhostToolsVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

/// Target install location
let kApplicationsPath = "/Applications/GhostTools.app"

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

    /// Files queued for sending to host (accessor for FileService)
    private var filesToSend: [URL] {
        FileService.shared.listOutgoingFiles().compactMap { URL(fileURLWithPath: $0) }
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

        print("[GhostTools] Application launched - version \(kGhostToolsVersion)")

        // Auto-install to /Applications if not already there
        if installToApplicationsIfNeeded() {
            // Will relaunch from /Applications, exit this instance
            return
        }

        // Check for updates from mounted volumes on launch
        if checkForUpdateFromVolumes() {
            // Will relaunch with new version, exit this instance
            return
        }

        setupMenuBar()
        print("[GhostTools] Menu bar setup complete")
        requestNotificationPermission()
        PermissionsWindow.shared.showIfNeeded()
        installLaunchAgentIfNeeded()
        registerAsDefaultBrowser()

        // Refresh menu when outgoing files change (e.g. host clears queue via DELETE)
        NotificationCenter.default.addObserver(forName: .outgoingFilesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateMenu()
        }

        startServer()
        startTunnelServer()
        startHealthServer()
        startEventPushServer()
        startPortScanner()
        startForegroundAppService()
        startUpdateChecker()
    }

    // MARK: - Auto-Update from Volumes

    /// Check mounted volumes for a newer GhostTools and update if found
    /// - Returns: true if updating (caller should exit), false to continue
    private func checkForUpdateFromVolumes() -> Bool {
        let fm = FileManager.default

        // Check if /Volumes/GhostTools exists (our DMG is mounted)
        let volumePath = "/Volumes/GhostTools"
        let appPath = "\(volumePath)/GhostTools.app"
        let sourceExecPath = "\(appPath)/Contents/MacOS/GhostTools"

        guard fm.fileExists(atPath: sourceExecPath) else {
            return false
        }

        print("[GhostTools] Found mounted GhostTools volume")

        let installedExecPath = "\(kApplicationsPath)/Contents/MacOS/GhostTools"

        // If not installed yet, install from volume
        guard fm.fileExists(atPath: installedExecPath) else {
            print("[GhostTools] Not installed, installing from volume...")
            return performUpdate(from: appPath)
        }

        // Compare file sizes as a quick check for differences
        guard let sourceAttrs = try? fm.attributesOfItem(atPath: sourceExecPath),
              let installedAttrs = try? fm.attributesOfItem(atPath: installedExecPath),
              let sourceSize = sourceAttrs[.size] as? Int,
              let installedSize = installedAttrs[.size] as? Int else {
            return false
        }

        // Update if sizes differ (different binary)
        if sourceSize != installedSize {
            print("[GhostTools] Size differs (installed: \(installedSize), available: \(sourceSize)), updating...")
            return performUpdate(from: appPath)
        }

        // Also check modification date
        if let sourceDate = sourceAttrs[.modificationDate] as? Date,
           let installedDate = installedAttrs[.modificationDate] as? Date,
           sourceDate > installedDate {
            print("[GhostTools] Newer version available, updating...")
            return performUpdate(from: appPath)
        }

        return false
    }

    /// Perform the update from the source app path
    private func performUpdate(from sourcePath: String) -> Bool {
        let fm = FileManager.default
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = URL(fileURLWithPath: kApplicationsPath)

        print("[GhostTools] Updating from \(sourcePath)...")

        do {
            // Remove existing installation
            if fm.fileExists(atPath: kApplicationsPath) {
                try fm.removeItem(at: destURL)
            }

            // Copy new version
            try fm.copyItem(at: sourceURL, to: destURL)
            print("[GhostTools] Update complete")

            // Relaunch
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", kApplicationsPath]
            try task.run()

            print("[GhostTools] Relaunching...")

            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return true

        } catch {
            print("[GhostTools] Update failed: \(error)")
            return false
        }
    }

    /// Periodically check for updates from mounted volumes
    private func startUpdateChecker() {
        // Check every 10 seconds for mounted DMGs with updates
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            if self?.checkForUpdateFromVolumes() == true {
                // Will terminate and relaunch
            }
        }
    }

    // MARK: - Auto-Install

    /// Copies app to /Applications if not already running from there, or if this version is newer
    /// - Returns: true if relaunching (caller should exit), false to continue
    private func installToApplicationsIfNeeded() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return false }

        // Already in /Applications?
        if bundlePath == kApplicationsPath {
            print("[GhostTools] Running from /Applications")
            return false
        }

        // Check if we're running from a DMG/Volumes with a newer version
        let fm = FileManager.default
        if fm.fileExists(atPath: kApplicationsPath) {
            // Check installed version
            let installedPlistPath = kApplicationsPath + "/Contents/Info.plist"
            if let installedPlist = NSDictionary(contentsOfFile: installedPlistPath),
               let installedVersion = installedPlist["CFBundleShortVersionString"] as? String {
                print("[GhostTools] Installed version: \(installedVersion), this version: \(kGhostToolsVersion)")
                if installedVersion == kGhostToolsVersion {
                    print("[GhostTools] Same version already installed, launching from /Applications")
                    // Launch the installed version instead
                    launchInstalledAndExit()
                    return true
                }
                print("[GhostTools] Updating to version \(kGhostToolsVersion)...")
            }
        }

        // Check if we're running from a DMG or other location
        print("[GhostTools] Running from: \(bundlePath)")
        print("[GhostTools] Installing to /Applications...")

        let sourceURL = URL(fileURLWithPath: bundlePath)
        let destURL = URL(fileURLWithPath: kApplicationsPath)

        do {
            // Remove existing installation if present
            if fm.fileExists(atPath: kApplicationsPath) {
                print("[GhostTools] Removing existing installation...")
                try fm.removeItem(at: destURL)
            }

            // Copy to /Applications
            try fm.copyItem(at: sourceURL, to: destURL)
            print("[GhostTools] Installed to \(kApplicationsPath)")

            // Register with Launch Services
            let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: lsregister)
            process.arguments = ["-f", kApplicationsPath]
            try process.run()
            process.waitUntilExit()
            print("[GhostTools] Registered with Launch Services")

            // Set as default browser for URL forwarding
            registerAsDefaultBrowser()

            // Relaunch from /Applications
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", kApplicationsPath]
            try task.run()

            print("[GhostTools] Relaunching from /Applications...")

            // Quit this instance
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
            return true

        } catch {
            print("[GhostTools] Failed to install: \(error)")
            // Continue running from current location
            return false
        }
    }

    /// Launch the installed version from /Applications and exit this instance
    private func launchInstalledAndExit() {
        do {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", kApplicationsPath]
            try task.run()
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        } catch {
            print("[GhostTools] Failed to launch installed version: \(error)")
        }
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

    private func installLaunchAgentIfNeeded() {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentsDir.appendingPathComponent("com.ghostvm.ghosttools.plist")

        // Always use /Applications path for the launch agent
        let executablePath = kApplicationsPath + "/Contents/MacOS/GhostTools"

        // Check if already installed with correct path
        if FileManager.default.fileExists(atPath: plistPath.path) {
            // Verify it points to /Applications
            if let existingPlist = NSDictionary(contentsOf: plistPath),
               let args = existingPlist["ProgramArguments"] as? [String],
               args.first == executablePath {
                print("[GhostTools] Launch agent already installed")
                return
            }
            // Remove outdated launch agent
            try? FileManager.default.removeItem(at: plistPath)
            print("[GhostTools] Updating launch agent to point to /Applications")
        }

        // Create LaunchAgents directory if needed
        do {
            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        } catch {
            print("[GhostTools] Failed to create LaunchAgents directory: \(error)")
            return
        }

        // Create the plist content - always point to /Applications
        let plistContent: [String: Any] = [
            "Label": "com.ghostvm.ghosttools",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        // Write the plist
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try data.write(to: plistPath)
            print("[GhostTools] Launch agent installed at \(plistPath.path)")

            // Show notification
            let content = UNMutableNotificationContent()
            content.title = "GhostTools Installed"
            content.body = "GhostTools will now start automatically at login."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "launch-agent-installed", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } catch {
            print("[GhostTools] Failed to write launch agent plist: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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

