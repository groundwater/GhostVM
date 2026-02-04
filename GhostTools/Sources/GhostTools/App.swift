import AppKit
import SwiftUI
import UserNotifications

/// GhostTools version - update this when making changes to verify correct binary is running
let kGhostToolsVersion = "1.3.0-auto-install"

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
    private var isServerRunning = false

    /// Files queued for sending to host (accessor for FileService)
    private var filesToSend: [URL] {
        FileService.shared.listOutgoingFiles().compactMap { URL(fileURLWithPath: $0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[GhostTools] Application launched - version \(kGhostToolsVersion)")

        // Auto-install to /Applications if not already there
        if installToApplicationsIfNeeded() {
            // Will relaunch from /Applications, exit this instance
            return
        }

        setupMenuBar()
        print("[GhostTools] Menu bar setup complete")
        requestNotificationPermission()
        installLaunchAgentIfNeeded()
        startServer()
    }

    // MARK: - Auto-Install

    /// Copies app to /Applications if not already running from there, then relaunches
    /// - Returns: true if relaunching (caller should exit), false to continue
    private func installToApplicationsIfNeeded() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return false }

        // Already in /Applications?
        if bundlePath == kApplicationsPath {
            print("[GhostTools] Running from /Applications")
            return false
        }

        // Check if we're running from a DMG or other location
        print("[GhostTools] Running from: \(bundlePath)")
        print("[GhostTools] Installing to /Applications...")

        let fm = FileManager.default
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

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        server?.stop()
        tunnelServer?.stop()
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

            // Check for localhost URLs that need port forwarding
            if let host = url.host?.lowercased(),
               (host == "localhost" || host == "127.0.0.1"),
               let port = url.port,
               port > 0 && port <= UInt16.max {
                let portNum = UInt16(port)
                // Check if the port is actually listening before requesting forward
                if PortScanner.shared.isPortListening(portNum) {
                    print("[GhostTools] Requesting port forward for localhost:\(portNum)")
                    PortForwardRequestService.shared.requestForward(portNum)
                }
            }

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

        let color = connected ? NSColor.systemGreen : NSColor.systemGray

        if let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "GhostTools") {
            let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
            let sizeConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            let configuredImage = image.withSymbolConfiguration(colorConfig.applying(sizeConfig))
            button.image = configuredImage
        } else {
            button.title = "●"
            button.contentTintColor = color
        }
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Title (disabled)
        let titleItem = NSMenuItem(title: "GhostTools", action: nil, keyEquivalent: "")
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
        let sendToHostItem = NSMenuItem(title: "Send to Host...", action: #selector(sendToHost), keyEquivalent: "s")
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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select files to send to host"
        panel.prompt = "Send"

        panel.begin { [weak self] response in
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

        // Start tunnel server for port forwarding
        Task {
            do {
                print("[GhostTools] Creating TunnelServer on port 5001...")
                tunnelServer = TunnelServer()
                print("[GhostTools] Starting tunnel server...")
                try await tunnelServer?.start()
                print("[GhostTools] Tunnel server started successfully")
            } catch {
                print("[GhostTools] Failed to start tunnel server: \(error)")
            }
        }
    }
}

