import AppKit
import SwiftUI
import UserNotifications

/// GhostTools - Menu bar daemon for guest VM integration
/// Provides HTTP/1.1 server over vsock for host-guest communication
@main
struct GhostToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app with no main window
        Settings {
            PreferencesView()
        }
    }
}

/// App delegate handles menu bar setup and server lifecycle
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var server: VsockServer?
    private var isServerRunning = false
    /// Files queued for sending to host
    private var filesToSend: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        requestNotificationPermission()
        startServer()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
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

        let symbolName = connected ? "circle.fill" : "circle"
        let color = connected ? NSColor.systemGreen : NSColor.systemGray

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "GhostTools Status") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let configuredImage = image.withSymbolConfiguration(config)
            button.image = configuredImage
            button.contentTintColor = color
        } else {
            button.title = connected ? "G+" : "G"
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

        // Clipboard sync submenu
        let clipboardItem = NSMenuItem(title: "Clipboard Sync", action: nil, keyEquivalent: "")
        let clipboardMenu = NSMenu()

        let modes = ["Bidirectional", "Host -> Guest", "Guest -> Host", "Disabled"]
        for mode in modes {
            let item = NSMenuItem(title: mode, action: #selector(clipboardModeSelected(_:)), keyEquivalent: "")
            item.target = self
            if mode == ClipboardService.shared.syncMode.displayName {
                item.state = .on
            }
            clipboardMenu.addItem(item)
        }
        clipboardItem.submenu = clipboardMenu
        menu.addItem(clipboardItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

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
        // Add files to queue (they will be available via GET /api/v1/files/{path})
        for url in urls {
            if !filesToSend.contains(url) {
                filesToSend.append(url)
            }
        }
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
        filesToSend.removeAll()
        updateMenu()
    }

    @objc private func clipboardModeSelected(_ sender: NSMenuItem) {
        guard let mode = ClipboardSyncMode.from(displayName: sender.title) else { return }
        ClipboardService.shared.syncMode = mode
        updateMenu()
    }

    @objc private func showPreferences() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startServer() {
        Task {
            do {
                let router = Router()
                server = VsockServer(port: 80, router: router)

                server?.onStatusChange = { [weak self] running in
                    Task { @MainActor in
                        self?.isServerRunning = running
                        self?.updateStatusIcon(connected: running)
                        self?.updateMenu()
                    }
                }

                print("GhostTools starting vsock server on port 80...")
                try await server?.start()
            } catch {
                print("Failed to start server: \(error)")
                isServerRunning = false
                updateStatusIcon(connected: false)
                updateMenu()
            }
        }
    }
}

/// Preferences view for settings window
struct PreferencesView: View {
    @State private var syncMode: ClipboardSyncMode = ClipboardService.shared.syncMode

    var body: some View {
        Form {
            Section("Clipboard") {
                Picker("Sync Mode", selection: $syncMode) {
                    ForEach(ClipboardSyncMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: syncMode) { _, newValue in
                    ClipboardService.shared.syncMode = newValue
                }
            }

            Section("Server") {
                LabeledContent("Port") {
                    Text("80 (vsock)")
                }
                LabeledContent("Token Path") {
                    Text("/Volumes/GhostVM/.ghost-token")
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 200)
    }
}
