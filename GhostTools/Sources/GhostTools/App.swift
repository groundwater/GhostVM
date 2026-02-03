import AppKit
import SwiftUI

/// GhostTools - Menu bar daemon for guest VM integration
/// Provides HTTP/2 server over vsock for host-guest communication
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
    private var server: GhostServer?
    private var isConnected = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        startServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Server cleanup happens automatically when app terminates
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Use ghost SF Symbol or fallback to text
            if let image = NSImage(systemSymbolName: "theatermask.and.paintbrush", accessibilityDescription: "GhostTools") {
                button.image = image
            } else {
                button.title = "G"
            }
        }

        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Status item
        let statusText = isConnected ? "Status: Connected" : "Status: Disconnected"
        let statusItem = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)

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
                server = try await GhostServer()
                isConnected = true
                updateMenu()
                try await server?.run()
            } catch {
                print("Failed to start server: \(error)")
                isConnected = false
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
