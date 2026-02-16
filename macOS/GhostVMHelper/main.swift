import AppKit
import Combine
import Foundation
import Virtualization
import GhostVMKit

/// GhostVMHelper - Standalone app that hosts a single VM with its own Dock icon.
///
/// Launch arguments:
///   --vm-bundle <path>    Path to the .ghostvm bundle to run
///
/// Communication (via DistributedNotificationCenter):
///   - Listens for "com.ghostvm.helper.stop.<bundlePath>" to stop VM
///   - Listens for "com.ghostvm.helper.suspend.<bundlePath>" to suspend VM
///   - Posts "com.ghostvm.helper.state.<bundlePath>" when state changes
///

@MainActor
final class HelperAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate, NSMenuItemValidation, HelperToolbarDelegate, FileTransferDelegate {

    enum State: String {
        case starting
        case running
        case stopping
        case suspending
        case stopped
        case failed
    }

    private var vmBundleURL: URL!
    private var vmName: String = ""
    private var state: State = .stopped
    private var bootToRecovery: Bool = false

    private var window: NSWindow?
    private var vmView: FocusableVMView?
    private var virtualMachine: VZVirtualMachine?
    private var vmQueue: DispatchQueue?
    private var layout: VMFileLayout?

    private let controller = VMController()
    private let center = DistributedNotificationCenter.default()
    private let fileManager = FileManager.default

    private var ownsLock = false
    private var helperToolbar: HelperToolbar?
    private var statusOverlay: StatusOverlay?

    // Services
    private var ghostClient: GhostClient?
    private var clipboardSyncService: ClipboardSyncService?
    private var portForwardService: PortForwardService?
    private var folderShareService: FolderShareService?
    private var fileTransferService: FileTransferService?
    private var eventStreamService: EventStreamService?
    private var healthCheckService: HealthCheckService?
    private var autoPortMapService: AutoPortMapService?
    private var hostAPIService: HostAPIService?
    private var autoPortMapCancellable: AnyCancellable?
    private var fileTransferCancellable: AnyCancellable?
    private var fileCountCancellable: AnyCancellable?
    private var healthCheckCancellable: AnyCancellable?
    private var windowFocusObservers: [NSObjectProtocol] = []

    // Capture key state
    private var captureQuitEnabled = false
    private var captureHideEnabled = false
    private var quitMenuItem: NSMenuItem?
    private var hideMenuItem: NSMenuItem?

    // Clipboard permission state (in-memory, resets on restart)
    private var clipboardAlwaysAllowed = false
    private var clipboardAutoDismissMonitor: Any?
    private var lastPromptedClipboardChangeCount: Int? = nil

    // URL permission state
    private var urlAlwaysAllowed = false  // true when persisted setting OR "Always Allow" clicked
    private var pendingURLsToOpen: [String] = []
    private var urlPermissionCancellable: AnyCancellable?

    // Port forward notification state
    private var newlyForwardedCancellable: AnyCancellable?
    private var blockedPortsCancellable: AnyCancellable?

    // Dynamic icon state
    private var foregroundAppCancellable: AnyCancellable?
    private var iconStack: [(bundleId: String, icon: NSImage)] = []
    private let maxStackSize = 2
    private var activeIconMode: String?  // nil = static, "stack" = animated stack, "app" = single app icon
    private var iconAnimationTimer: Timer?
    private var iconAnimationStartTime: Date = .distantPast
    private let iconAnimationDuration: TimeInterval = 0.3
    private struct IconAnimFrame {
        let icon: NSImage
        let fromX: CGFloat; let fromY: CGFloat; let fromOpacity: CGFloat; let fromSize: CGFloat
        let toX: CGFloat; let toY: CGFloat; let toOpacity: CGFloat; let toSize: CGFloat
    }
    private var iconAnimationFrames: [IconAnimFrame] = []
    // Slot positions: index 0 = front (top-left), 1 = 2nd (bottom-right)
    private let iconSlots: [(x: CGFloat, y: CGFloat, opacity: CGFloat, size: CGFloat)] = [
        (-30,  30,  1.00, 1.0),  // Top-left (foreground) at 100% size
        ( 35, -35,  0.60, 0.9),  // Bottom-right (background) at 80% size
    ]
    private func centeredSlots(for count: Int) -> [(x: CGFloat, y: CGFloat, opacity: CGFloat, size: CGFloat)] {
        guard count > 0 else { return [] }
        let slots = Array(iconSlots.prefix(count))
        let centerX = (slots.map(\.x).min()! + slots.map(\.x).max()!) / 2
        let centerY = (slots.map(\.y).min()! + slots.map(\.y).max()!) / 2
        return slots.map { (x: $0.x - centerX, y: $0.y - centerY, opacity: $0.opacity, size: $0.size) }
    }

    // Placeholder icon for Finder-only mode
    private lazy var placeholderIcon: NSImage = {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()

        // Draw rounded rect (400x400) centered in canvas to match real app icons
        let iconSize: CGFloat = 400  // Match composite icon draw size
        let offset = (512 - iconSize) / 2
        let rect = NSRect(x: offset, y: offset, width: iconSize, height: iconSize)
        let cornerRadius: CGFloat = iconSize * 185.4 / 1024  // Match macOS icon rounding
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

        // Subtle gray fill with transparency
        NSColor(white: 0.95, alpha: 0.3).setFill()
        path.fill()

        image.unlockFocus()
        return image
    }()

    // MARK: - App Lifecycle

    private var isUITesting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("GhostVMHelper: BUILD 2025-02-09A — file transfer debug build")
        // Parse command line arguments
        let args = ProcessInfo.processInfo.arguments

        // UI testing mode: skip VM, show mock window
        if args.contains("--ui-testing") {
            isUITesting = true
            vmName = "macOS Sequoia"
            ProcessInfo.processInfo.processName = vmName
            NSApp.setActivationPolicy(.regular)
            setupMenuBar()
            setupUITestingWindow(args: args)
            return
        }

        if let bundleIndex = args.firstIndex(of: "--vm-bundle"), bundleIndex + 1 < args.count {
            vmBundleURL = URL(fileURLWithPath: args[bundleIndex + 1]).standardizedFileURL
        } else {
            // Infer from helper location: {VM}.ghostvm/Helper/{Name}.app
            vmBundleURL = Bundle.main.bundleURL
                .deletingLastPathComponent()  // Helper/
                .deletingLastPathComponent()  // {VM}.ghostvm
                .standardizedFileURL
        }
        vmName = vmBundleURL.deletingPathExtension().lastPathComponent
        ProcessInfo.processInfo.processName = vmName

        // Parse --recovery flag
        if args.contains("--recovery") {
            bootToRecovery = true
        }

        NSLog("GhostVMHelper: Starting VM '\(vmName)' from \(vmBundleURL.path)")

        // Set activation policy to show in Dock
        NSApp.setActivationPolicy(.regular)

        // Setup menu bar
        setupMenuBar()

        // Load and set custom icon
        loadCustomIcon()

        // Register for control notifications
        registerNotifications()

        // Start the VM
        startVM()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch state {
        case .running:
            suspendVM()
            return .terminateCancel
        case .suspending, .stopping, .starting:
            return .terminateCancel
        case .stopped, .failed:
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("GhostVMHelper: Terminating for VM '\(vmName)'")
        cleanup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Bring window to front when Dock icon is clicked
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        helperToolbar?.showQueuedFilesPopoverIfNeeded()
        return true
    }

    // MARK: - UI Testing Mode

    private func setupUITestingWindow(args: [String]) {
        // Create window — wide enough for toolbar items + popovers to not clip
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = vmName
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 512, height: 512)
        window.hasShadow = false  // Disable shadow so XCUITest captures are tight to window frame

        // Setup toolbar
        let toolbar = HelperToolbar()
        toolbar.delegate = self
        toolbar.attach(to: window)
        helperToolbar = toolbar

        // Create container for VM content
        let containerView = NSView()
        containerView.wantsLayer = true
        window.contentView = containerView

        // Helper to load a @2x image from bundle resources
        func loadBundleImage(_ name: String) -> NSImage? {
            let image = NSImage(named: name) ?? {
                guard let path = Bundle.main.path(forResource: name, ofType: "png") else { return nil }
                return NSImage(contentsOfFile: path)
            }()
            if let image = image, let rep = image.representations.first {
                image.size = NSSize(width: rep.pixelsWide / 2, height: rep.pixelsHigh / 2)
            }
            return image
        }

        // Guest desktop wallpaper — use --wallpaper flag or default to Desktop-Sequoia
        // Offset upward to hide the guest menu bar baked into the screenshot.
        let wallpaperName: String
        if let idx = args.firstIndex(of: "--wallpaper"), idx + 1 < args.count {
            wallpaperName = args[idx + 1]
        } else {
            wallpaperName = "Desktop-Sequoia"
        }
        let wallpaperView = NSImageView()
        wallpaperView.imageScaling = .scaleAxesIndependently
        wallpaperView.translatesAutoresizingMaskIntoConstraints = false
        wallpaperView.image = loadBundleImage(wallpaperName)
        containerView.addSubview(wallpaperView)
        let menuBarCrop: CGFloat = 38
        NSLayoutConstraint.activate([
            wallpaperView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: -menuBarCrop),
            wallpaperView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            wallpaperView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            wallpaperView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // If --content-image is specified, overlay the app window on the guest desktop
        if let idx = args.firstIndex(of: "--content-image"), idx + 1 < args.count {
            let contentName = args[idx + 1]
            if let appImage = loadBundleImage(contentName) {
                let appView = NSImageView()
                appView.translatesAutoresizingMaskIntoConstraints = false
                appView.image = appImage
                appView.wantsLayer = true
                appView.layer!.backgroundColor = NSColor.clear.cgColor
                appView.imageScaling = .scaleProportionallyUpOrDown
                appView.shadow = {
                    let s = NSShadow()
                    s.shadowBlurRadius = 12
                    s.shadowOffset = NSSize(width: 0, height: -4)
                    s.shadowColor = NSColor.black.withAlphaComponent(0.4)
                    return s
                }()
                containerView.addSubview(appView)
                // Inset the app window so guest desktop wallpaper is clearly visible behind it
                NSLayoutConstraint.activate([
                    appView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 60),
                    appView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 50),
                    appView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -50),
                    appView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -30),
                ])
            }
        }

        self.window = window

        // Pre-populate toolbar with mock data
        toolbar.setGuestToolsStatus(.connected)
        toolbar.setClipboardSyncMode("bidirectional")

        // Mock port forwards: node:8080, python3:3000
        toolbar.setPortForwardEntries([
            PortForwardEntry(hostPort: 8080, guestPort: 8080, enabled: true, isAutoMapped: true, processName: "node"),
            PortForwardEntry(hostPort: 3000, guestPort: 3000, enabled: true, isAutoMapped: true, processName: "python3"),
        ])
        toolbar.setAutoPortMapEnabled(true)

        // Mock shared folder
        toolbar.setSharedFolderEntries([
            SharedFolderEntry(id: UUID(), path: NSHomeDirectory() + "/Projects", readOnly: false),
        ])

        // Mock queued files
        let fileCount: Int
        if let idx = args.firstIndex(of: "--queued-file-count"), idx + 1 < args.count,
           let count = Int(args[idx + 1]) {
            fileCount = count
        } else {
            fileCount = 3
        }
        toolbar.setQueuedFileCount(fileCount)
        toolbar.setQueuedFileNames((1...fileCount).map { "file-\($0).txt" })

        toolbar.setVMRunning(true)

        // Show window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Show the requested panel after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            if args.contains("--show-clipboard-prompt") {
                self.helperToolbar?.showClipboardPermissionPopover()
            } else if args.contains("--show-port-forward") {
                self.helperToolbar?.showPortForwardNotificationPopover()
                let mappings: [(guestPort: UInt16, hostPort: UInt16, processName: String?)] = [
                    (guestPort: 8080, hostPort: 8080, processName: "node"),
                    (guestPort: 3000, hostPort: 3000, processName: "python3"),
                ]
                self.helperToolbar?.setPortForwardPermissionMappings(mappings)
            } else if args.contains("--show-file-transfer") {
                self.helperToolbar?.showQueuedFilesPopover()
            } else if args.contains("--show-shared-folders") {
                self.helperToolbar?.showSharedFolderEditor()
            }
        }
    }

    // MARK: - Custom Icon

    private func loadCustomIcon() {
        let iconURL = vmBundleURL.appendingPathComponent("icon.png")

        guard fileManager.fileExists(atPath: iconURL.path),
              let image = NSImage(contentsOf: iconURL) else {
            NSLog("GhostVMHelper: No custom icon found")
            return
        }

        // Set logical size to 256x256pt so macOS treats the 512px image as @2x
        image.size = NSSize(width: 256, height: 256)

        NSApp.applicationIconImage = image
        NSWorkspace.shared.setIcon(image, forFile: vmBundleURL.path, options: [])
        NSWorkspace.shared.setIcon(image, forFile: Bundle.main.bundlePath, options: [])
        NSLog("GhostVMHelper: Loaded custom icon from \(iconURL.path)")
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(title: "About GhostVM Helper", action: #selector(showAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)

        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(hideItem)
        self.hideMenuItem = hideItem

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        self.quitMenuItem = quitItem

        // VM menu
        let vmMenuItem = NSMenuItem()
        vmMenuItem.title = "VM"
        mainMenu.addItem(vmMenuItem)
        let vmMenu = NSMenu(title: "VM")
        vmMenuItem.submenu = vmMenu

        let startItem = NSMenuItem(title: "Start", action: #selector(startVMAction), keyEquivalent: "r")
        startItem.target = self
        vmMenu.addItem(startItem)

        vmMenu.addItem(NSMenuItem.separator())

        // Clipboard Sync toggle
        let clipboardItem = NSMenuItem(title: "Clipboard Sync", action: #selector(toggleClipboardSyncMenu), keyEquivalent: "")
        clipboardItem.target = self
        vmMenu.addItem(clipboardItem)

        vmMenu.addItem(NSMenuItem.separator())

        let suspendItem = NSMenuItem(title: "Suspend", action: #selector(suspendVMAction), keyEquivalent: "")
        suspendItem.target = self
        vmMenu.addItem(suspendItem)

        let shutdownItem = NSMenuItem(title: "Shut Down", action: #selector(shutdownVMAction), keyEquivalent: "")
        shutdownItem.target = self
        vmMenu.addItem(shutdownItem)

        let terminateItem = NSMenuItem(title: "Terminate", action: nil, keyEquivalent: "")
        terminateItem.action = #selector(terminateVMAction)
        terminateItem.target = self
        vmMenu.addItem(terminateItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        windowMenuItem.title = "Window"
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        let fullscreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        windowMenu.addItem(fullscreenItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu Actions

    @objc private func showAboutPanel() {
        let alert = NSAlert()
        alert.messageText = "GhostVM Helper"
        alert.informativeText = "Running VM: \(vmName)\n\nThis helper app hosts a single virtual machine with its own Dock icon."
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func startVMAction() {
        // Start is only valid if not already running
        guard state == .stopped || state == .failed else { return }
        startVM()
    }

    @objc private func suspendVMAction() {
        suspendVM()
    }

    @objc private func shutdownVMAction() {
        stopVM()
    }

    @objc private func terminateVMAction() {
        let alert = NSAlert()
        alert.messageText = "Terminate Virtual Machine?"
        alert.informativeText = "This will immediately force stop the VM. Any unsaved work in the guest will be lost.\n\nUse \"Shut Down\" for a graceful shutdown instead."
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")?
            .withSymbolConfiguration(.init(pointSize: 48, weight: .regular))
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            terminateVM()
        }
    }

    @objc private func toggleClipboardSyncMenu() {
        guard let service = clipboardSyncService else { return }
        let newMode: String = (service.syncMode == .disabled) ? "bidirectional" : "disabled"
        toolbar(helperToolbar!, didSelectClipboardSyncMode: newMode)
    }

    // Menu validation
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startVMAction):
            return state == .stopped || state == .failed
        case #selector(suspendVMAction):
            return state == .running
        case #selector(shutdownVMAction):
            return state == .running
        case #selector(terminateVMAction):
            return state == .running || state == .stopping || state == .suspending
        case #selector(toggleClipboardSyncMenu):
            if let currentMode = clipboardSyncService?.syncMode {
                menuItem.state = (currentMode != .disabled) ? .on : .off
            }
            return state == .running
        default:
            return true
        }
    }

    // MARK: - HelperToolbarDelegate

    func toolbar(_ toolbar: HelperToolbar, didToggleCaptureSystemKeys enabled: Bool) {
        vmView?.capturesSystemKeys = enabled

        // Persist per-VM
        let key = "captureSystemKeys_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(enabled, forKey: key)
        NSLog("GhostVMHelper: Capture inputs changed to \(enabled)")
    }

    func toolbar(_ toolbar: HelperToolbar, didToggleCaptureQuit enabled: Bool) {
        captureQuitEnabled = enabled
        (NSApp as? HelperApplication)?.captureQuitEnabled = enabled
        quitMenuItem?.keyEquivalent = enabled ? "" : "q"

        let key = "captureQuit_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(enabled, forKey: key)
        NSLog("GhostVMHelper: Capture quit changed to \(enabled)")
    }

    func toolbar(_ toolbar: HelperToolbar, didToggleCaptureHide enabled: Bool) {
        captureHideEnabled = enabled
        (NSApp as? HelperApplication)?.captureHideEnabled = enabled
        hideMenuItem?.keyEquivalent = enabled ? "" : "h"

        let key = "captureHide_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(enabled, forKey: key)
        NSLog("GhostVMHelper: Capture hide changed to \(enabled)")
    }

    func toolbar(_ toolbar: HelperToolbar, didToggleOpenURLsAutomatically enabled: Bool) {
        urlAlwaysAllowed = enabled

        let key = "openURLsAutomatically_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(enabled, forKey: key)
        NSLog("GhostVMHelper: Open URLs automatically changed to \(enabled)")
    }

    func toolbar(_ toolbar: HelperToolbar, didSelectClipboardSyncMode mode: String) {
        guard let syncMode = ClipboardSyncMode(rawValue: mode) else { return }
        clipboardSyncService?.setSyncMode(syncMode)
        helperToolbar?.setClipboardSyncMode(mode)

        // Reset permission when clipboard is disabled
        if syncMode == .disabled {
            clipboardAlwaysAllowed = false
        }

        // Persist per-VM
        let key = "clipboardSyncMode_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(mode, forKey: key)
        NSLog("GhostVMHelper: Clipboard sync mode changed to \(mode)")
    }

    @discardableResult
    func toolbar(_ toolbar: HelperToolbar, didAddPortForward hostPort: UInt16, guestPort: UInt16) -> String? {
        guard let service = portForwardService else {
            NSLog("GhostVMHelper: Port forwarding not available")
            return "Port forwarding not available"
        }
        let config = PortForwardConfig(hostPort: hostPort, guestPort: guestPort, enabled: true)
        do {
            try service.addForward(config)
            updateToolbarPortForwards()
            persistPortForwards()
            autoPortMapService?.updateManualPorts(manualPortSet())
            NSLog("GhostVMHelper: Added port forward \(hostPort) -> \(guestPort)")
            return nil
        } catch {
            NSLog("GhostVMHelper: Failed to add port forward: \(error)")
            return error.localizedDescription
        }
    }

    func toolbar(_ toolbar: HelperToolbar, didRemovePortForwardWithHostPort hostPort: UInt16) {
        portForwardService?.removeForward(hostPort: hostPort)
        updateToolbarPortForwards()
        persistPortForwards()
        autoPortMapService?.updateManualPorts(manualPortSet())
        NSLog("GhostVMHelper: Removed port forward with host port \(hostPort)")
    }

    func toolbar(_ toolbar: HelperToolbar, didToggleAutoPortMap enabled: Bool) {
        autoPortMapService?.setEnabled(enabled)
        let key = "autoPortMap_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(enabled, forKey: key)
        if !enabled {
            helperToolbar?.closePortForwardPermissionPopover()
            helperToolbar?.setBlockedPortDescriptions([])
            updateToolbarPortForwards()
        }
        NSLog("GhostVMHelper: Auto port map changed to \(enabled)")
    }

    func toolbar(_ toolbar: HelperToolbar, didAddSharedFolder path: String, readOnly: Bool) {
        let config = SharedFolderConfig(path: path, readOnly: readOnly)
        folderShareService?.addFolder(config)
        updateToolbarSharedFolders()
        persistSharedFolders()
        NSLog("GhostVMHelper: Added shared folder \(path)")
    }

    func toolbar(_ toolbar: HelperToolbar, didRemoveSharedFolderWithID id: UUID) {
        folderShareService?.removeFolder(id: id)
        updateToolbarSharedFolders()
        persistSharedFolders()
        NSLog("GhostVMHelper: Removed shared folder with id \(id)")
    }

    func toolbar(_ toolbar: HelperToolbar, didSetSharedFolderReadOnly readOnly: Bool, forID id: UUID) {
        folderShareService?.setReadOnly(id: id, readOnly: readOnly)
        updateToolbarSharedFolders()
        persistSharedFolders()
        NSLog("GhostVMHelper: Set shared folder \(id) readOnly=\(readOnly)")
    }

    func toolbarDidRequestPortForwardEditor(_ toolbar: HelperToolbar) {
        NSLog("GhostVMHelper: Port forward editor requested")
    }

    func toolbarDidRequestReceiveFiles(_ toolbar: HelperToolbar) {
        NSLog("GhostVMHelper: toolbarDidRequestReceiveFiles called, fileTransferService=%@", fileTransferService != nil ? "present" : "NIL")
        fileTransferService?.fetchAllGuestFiles()
        restoreVMViewFocus()
    }

    func toolbarDidRequestDenyFiles(_ toolbar: HelperToolbar) {
        fileTransferService?.clearGuestFileQueue()
        restoreVMViewFocus()
    }

    func toolbarQueuedFilesPanelDidClose(_ toolbar: HelperToolbar) {
        restoreVMViewFocus()
    }

    func toolbarClipboardPermissionDidDeny(_ toolbar: HelperToolbar) {
        lastPromptedClipboardChangeCount = NSPasteboard.general.changeCount
        removeClipboardAutoDismissMonitor()
        restoreVMViewFocus()
    }

    func toolbarClipboardPermissionDidAllowOnce(_ toolbar: HelperToolbar) {
        lastPromptedClipboardChangeCount = NSPasteboard.general.changeCount
        removeClipboardAutoDismissMonitor()
        clipboardSyncService?.windowDidBecomeKey()
        restoreVMViewFocus()
    }

    func toolbarClipboardPermissionDidAlwaysAllow(_ toolbar: HelperToolbar) {
        lastPromptedClipboardChangeCount = NSPasteboard.general.changeCount
        removeClipboardAutoDismissMonitor()
        clipboardAlwaysAllowed = true
        clipboardSyncService?.windowDidBecomeKey()
        restoreVMViewFocus()
    }

    func toolbarClipboardPermissionPanelDidClose(_ toolbar: HelperToolbar) {
        removeClipboardAutoDismissMonitor()
        restoreVMViewFocus()
    }

    func toolbarURLPermissionDidDeny(_ toolbar: HelperToolbar) {
        pendingURLsToOpen = []
        eventStreamService?.clearPendingURLs()
        restoreVMViewFocus()
    }

    func toolbarURLPermissionDidAllowOnce(_ toolbar: HelperToolbar) {
        openPendingURLs()
        restoreVMViewFocus()
    }

    func toolbarURLPermissionDidAlwaysAllow(_ toolbar: HelperToolbar) {
        urlAlwaysAllowed = true
        helperToolbar?.setOpenURLsAutomatically(true)
        let key = "openURLsAutomatically_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(true, forKey: key)
        openPendingURLs()
        restoreVMViewFocus()
    }

    func toolbarURLPermissionPanelDidClose(_ toolbar: HelperToolbar) {
        restoreVMViewFocus()
    }

    func toolbar(_ toolbar: HelperToolbar, didBlockAutoForwardedPort port: UInt16) {
        autoPortMapService?.blockPort(port)
        updateToolbarPortForwards()
    }

    func toolbarPortForwardPermissionPanelDidClose(_ toolbar: HelperToolbar) {
        autoPortMapService?.acknowledgeNewlyForwarded()
        restoreVMViewFocus()
    }

    func toolbar(_ toolbar: HelperToolbar, didUnblockPort port: UInt16) {
        autoPortMapService?.unblockPort(port)
    }

    func toolbarDidUnblockAllPorts(_ toolbar: HelperToolbar) {
        autoPortMapService?.unblockAll()
    }

    func toolbarDidDetectNewQueuedFiles(_ toolbar: HelperToolbar) {
        // In UI testing mode, skip the popover activation
        guard !isUITesting else { return }

        // Use the file paths we already have from the event stream
        // instead of making a redundant HTTP round-trip via listGuestFiles()
        let paths = fileTransferService?.queuedGuestFilePaths ?? []
        let names = paths.map { URL(fileURLWithPath: $0).lastPathComponent }
        NSLog("GhostVMHelper: toolbarDidDetectNewQueuedFiles — %d file(s) from event stream", names.count)
        helperToolbar?.setQueuedFileNames(names)

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            helperToolbar?.showQueuedFilesPopover()
        }
    }

    func toolbarDidRequestIconChooser(_ toolbar: HelperToolbar) {
        helperToolbar?.showIconChooserPopover(bundleURL: vmBundleURL)
    }

    func toolbar(_ toolbar: HelperToolbar, didSelectIconMode mode: String?, icon: NSImage?) {
        // Update live icon mode so handleForegroundAppChange reacts immediately
        activeIconMode = mode

        if mode == "stack" || mode == "app" || mode == "glass" {
            // Immediately apply the cached foreground app icon
            handleForegroundAppChange(eventStreamService?.foregroundApp)
        }

        DispatchQueue.global(qos: .userInitiated).async { [vmBundleURL = self.vmBundleURL!] in
            let layout = VMFileLayout(bundleURL: vmBundleURL)
            let store = VMConfigStore(layout: layout)
            do {
                var config = try store.load()
                config.iconMode = mode
                try store.save(config)

                if mode == "stack" || mode == "app" {
                    // Dynamic modes — don't touch icon.png, icon already applied above
                } else if let icon = icon,
                          let tiff = icon.tiffRepresentation,
                          let bitmap = NSBitmapImageRep(data: tiff),
                          let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try pngData.write(to: layout.customIconURL)
                    DispatchQueue.main.async {
                        icon.size = NSSize(width: 256, height: 256)
                        NSApp.applicationIconImage = icon
                        NSWorkspace.shared.setIcon(icon, forFile: vmBundleURL.path, options: [])
                        NSWorkspace.shared.setIcon(icon, forFile: Bundle.main.bundlePath, options: [])
                    }
                } else {
                    // Generic mode — remove custom icon
                    try? FileManager.default.removeItem(at: layout.customIconURL)
                    DispatchQueue.main.async {
                        NSApp.applicationIconImage = nil
                        NSWorkspace.shared.setIcon(nil, forFile: vmBundleURL.path, options: [])
                        NSWorkspace.shared.setIcon(nil, forFile: Bundle.main.bundlePath, options: [])
                    }
                }
            } catch {
                NSLog("GhostVMHelper: Failed to save icon: \(error)")
            }
        }
    }

    func toolbarDidRequestShutDown(_ toolbar: HelperToolbar) {
        stopVM()
    }

    func toolbarDidRequestTerminate(_ toolbar: HelperToolbar) {
        terminateVMAction()
    }

    // MARK: - FileTransferDelegate

    func fileTransfer(didReceiveFiles files: [FileWithRelativePath]) {
        NSLog("GhostVMHelper: Sending \(files.count) file(s) to guest")
        fileTransferService?.sendFiles(files)
    }

    func fileTransfer(didRequestShareFolders folders: [URL], readOnly: Bool, copyFiles files: [FileWithRelativePath]) {
        for folder in folders {
            let config = SharedFolderConfig(path: folder.path, readOnly: readOnly)
            folderShareService?.addFolder(config)
            NSLog("GhostVMHelper: Shared folder via drag: \(folder.path)")
        }
        updateToolbarSharedFolders()
        persistSharedFolders()

        // Open the shared folders directory in the guest
        Task {
            do {
                try await ghostClient?.openPath("/Volumes/My Shared Files")
                NSLog("GhostVMHelper: Opened /Volumes/My Shared Files in guest")
            } catch {
                NSLog("GhostVMHelper: Failed to open shared files in guest: \(error)")
            }
        }

        if !files.isEmpty {
            NSLog("GhostVMHelper: Sending \(files.count) loose file(s) to guest")
            fileTransferService?.sendFiles(files)
        }
    }

    private func restoreVMViewFocus() {
        if let vmView = vmView {
            window?.makeFirstResponder(vmView)
        }
    }

    // MARK: - Port Forward Notification Flow

    private func handleNewlyForwardedPorts(_ mapping: [UInt16: UInt16]) {
        if mapping.isEmpty {
            helperToolbar?.closePortForwardPermissionPopover()
            return
        }

        let sorted = mapping.sorted { $0.key < $1.key }
            .map { (guestPort: $0.key, hostPort: $0.value, processName: autoPortMapService?.processNames[$0.key]) }
        if helperToolbar?.isPortForwardPermissionPopoverShown == true {
            helperToolbar?.addPortForwardPermissionMappings(sorted)
        } else {
            helperToolbar?.showPortForwardNotificationPopover()
            helperToolbar?.setPortForwardPermissionMappings(sorted)
        }
    }

    private func updateBlockedPortsDisplay(_ blocked: Set<UInt16>) {
        let descriptions = blocked.sorted().map { "localhost:\($0)" }
        helperToolbar?.setBlockedPortDescriptions(descriptions)
    }

    // MARK: - Clipboard Permission Flow

    private func handleClipboardOnFocus() {
        guard let service = clipboardSyncService, service.syncMode != .disabled else { return }

        // Never prompt for empty clipboard
        guard let content = NSPasteboard.general.string(forType: .string), !content.isEmpty else { return }

        if clipboardAlwaysAllowed {
            service.windowDidBecomeKey()
            return
        }

        let currentChangeCount = NSPasteboard.general.changeCount

        // Skip if we already prompted for this clipboard content (user denied or did "once")
        if currentChangeCount == lastPromptedClipboardChangeCount { return }

        // Skip if the clipboard was updated by our own guest-to-host pull
        if currentChangeCount == service.lastHostChangeCount { return }

        helperToolbar?.showClipboardPermissionPopover()
        installClipboardAutoDismissMonitor()
    }

    private func installClipboardAutoDismissMonitor() {
        removeClipboardAutoDismissMonitor()

        clipboardAutoDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            guard self.helperToolbar?.isClipboardPermissionPopoverShown == true else {
                self.removeClipboardAutoDismissMonitor()
                return event
            }
            // Don't dismiss if the click/key is inside the popover's own window
            if let eventWindow = event.window, eventWindow != self.window {
                return event
            }
            // Auto-dismiss (implicit deny) when user interacts with the VM
            self.lastPromptedClipboardChangeCount = NSPasteboard.general.changeCount
            self.helperToolbar?.closeClipboardPermissionPopover()
            self.removeClipboardAutoDismissMonitor()
            return event
        }
    }

    private func removeClipboardAutoDismissMonitor() {
        if let monitor = clipboardAutoDismissMonitor {
            NSEvent.removeMonitor(monitor)
            clipboardAutoDismissMonitor = nil
        }
    }

    // MARK: - URL Permission Flow

    private func handlePendingURLs(_ urls: [String]) {
        guard !urls.isEmpty else { return }

        if urlAlwaysAllowed {
            for urlString in urls {
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
            eventStreamService?.clearPendingURLs()
            return
        }

        pendingURLsToOpen = urls

        Task {
            try? await Task.sleep(for: .milliseconds(200))
            helperToolbar?.showURLPermissionPopover()
            helperToolbar?.setURLPermissionURLs(urls)
        }
    }

    private func openPendingURLs() {
        for urlString in pendingURLsToOpen {
            if let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
            }
        }
        pendingURLsToOpen = []
        eventStreamService?.clearPendingURLs()
    }

    // MARK: - Dynamic Icon

    private func handleForegroundAppChange(_ app: GuestForegroundApp?) {
        guard let mode = activeIconMode else { return }

        guard let app = app else {
            cancelIconAnimation()
            loadCustomIcon()
            return
        }

        // If guest didn't provide icon, try to fetch from NSWorkspace (for common system apps)
        let icon: NSImage
        if let guestIcon = app.icon {
            icon = guestIcon
        } else {
            // Try to get icon from NSWorkspace for known system apps
            if app.bundleId == "com.apple.finder" {
                icon = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
            } else {
                // For other apps without icons, fall back to generic app icon
                icon = NSWorkspace.shared.icon(forFileType: "app")
            }
        }

        // "app" mode: just set the icon directly, no stack
        if mode == "app" {
            let sized = NSImage(size: NSSize(width: 256, height: 256))
            sized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256),
                      from: .zero, operation: .sourceOver, fraction: 1.0)
            sized.unlockFocus()
            NSApp.applicationIconImage = sized
            return
        }

        // "glass" mode: app icon behind glass overlay
        if mode == "glass" {
            let canvasSize = NSSize(width: 512, height: 512)
            let composited = NSImage(size: canvasSize)
            composited.lockFocus()

            // Draw app icon as base, clipped to macOS icon shape
            let iconRect = NSRect(x: 56, y: 56, width: 400, height: 400)
            let cornerRadius = iconRect.width * 185.4 / 1024
            let path = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()

            // Draw glass overlay on top
            if let glassURL = Bundle.main.url(forResource: "GlassOverlay", withExtension: "png"),
               let glass = NSImage(contentsOf: glassURL) {
                glass.draw(in: NSRect(origin: .zero, size: canvasSize),
                           from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            composited.unlockFocus()
            composited.size = NSSize(width: 256, height: 256)
            NSApp.applicationIconImage = composited
            return
        }

        // "stack" mode: animated icon stack
        // Cancel any in-progress animation
        cancelIconAnimation()

        // Capture old stack for animation origin
        let oldStack = iconStack

        // Update stack: move-to-front deduplication
        iconStack.removeAll { $0.bundleId == app.bundleId }
        iconStack.insert((bundleId: app.bundleId, icon: icon), at: 0)

        // Remove placeholder if a real second app exists
        if iconStack.count > 1 {
            iconStack.removeAll { $0.bundleId == "com.ghostvm.placeholder" }
        }

        // Trim to maxStackSize (now 2)
        if iconStack.count > maxStackSize {
            iconStack = Array(iconStack.prefix(maxStackSize))
        }

        // Insert placeholder if only one real app in stack
        if iconStack.count < maxStackSize {
            iconStack.append((bundleId: "com.ghostvm.placeholder", icon: placeholderIcon))
        }

        // Build animation frames using centered slot positions
        var frames: [IconAnimFrame] = []
        let oldCentered = centeredSlots(for: max(2, oldStack.count))
        let newCentered = centeredSlots(for: max(2, iconStack.count))

        // Entrance/exit offsets relative to centered positions
        let entrance = (x: newCentered[0].x - 60, y: newCentered[0].y + 30, opacity: CGFloat(0.0))
        let exit: (x: CGFloat, y: CGFloat, opacity: CGFloat) = oldCentered.isEmpty
            ? (x: 75, y: -75, opacity: 0.0)
            : (x: oldCentered.last!.x + 20, y: oldCentered.last!.y - 20, opacity: 0.0)

        // Icons in new stack: animate from old slot (or entrance) to new slot
        for (newIdx, item) in iconStack.enumerated() {
            let to = newCentered[newIdx]
            if let oldIdx = oldStack.firstIndex(where: { $0.bundleId == item.bundleId }) {
                let from = oldIdx < oldCentered.count ? oldCentered[oldIdx] : oldCentered.last!
                frames.append(IconAnimFrame(
                    icon: item.icon,
                    fromX: from.x, fromY: from.y, fromOpacity: from.opacity, fromSize: from.size,
                    toX: to.x, toY: to.y, toOpacity: to.opacity, toSize: to.size
                ))
            } else {
                // New icon slides in from the left
                frames.append(IconAnimFrame(
                    icon: item.icon,
                    fromX: entrance.x, fromY: entrance.y, fromOpacity: entrance.opacity, fromSize: to.size,
                    toX: to.x, toY: to.y, toOpacity: to.opacity, toSize: to.size
                ))
            }
        }

        // Icons that fell off: animate from old slot to exit
        for (oldIdx, item) in oldStack.enumerated() {
            if !iconStack.contains(where: { $0.bundleId == item.bundleId }) {
                let from = oldIdx < oldCentered.count ? oldCentered[oldIdx] : oldCentered.last!
                frames.append(IconAnimFrame(
                    icon: item.icon,
                    fromX: from.x, fromY: from.y, fromOpacity: from.opacity, fromSize: from.size,
                    toX: exit.x, toY: exit.y, toOpacity: exit.opacity, toSize: from.size
                ))
            }
        }

        iconAnimationFrames = frames
        iconAnimationStartTime = Date()
        iconAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tickIconAnimation()
        }
    }

    private func tickIconAnimation() {
        let elapsed = Date().timeIntervalSince(iconAnimationStartTime)
        let rawProgress = min(elapsed / iconAnimationDuration, 1.0)
        // Ease-out: decelerate toward end
        let t = CGFloat(rawProgress * (2.0 - rawProgress))

        let image = drawCompositeIcon(progress: t)
        NSApp.applicationIconImage = image

        if rawProgress >= 1.0 {
            cancelIconAnimation()
        }
    }

    private func cancelIconAnimation() {
        iconAnimationTimer?.invalidate()
        iconAnimationTimer = nil
        iconAnimationFrames = []
    }

    private func drawCompositeIcon(progress t: CGFloat) -> NSImage {
        let canvasSize = NSSize(width: 512, height: 512)
        let image = NSImage(size: canvasSize)
        image.lockFocus()

        let baseIconSize: CGFloat = 400  // Renamed from iconSize

        // Draw from back to front: frames[0] is front, so reverse to draw back first
        for frame in iconAnimationFrames.reversed() {
            let offsetX = frame.fromX + (frame.toX - frame.fromX) * t
            let offsetY = frame.fromY + (frame.toY - frame.fromY) * t
            let opacity = frame.fromOpacity + (frame.toOpacity - frame.fromOpacity) * t
            let sizeMultiplier = frame.fromSize + (frame.toSize - frame.fromSize) * t  // NEW
            if opacity <= 0 { continue }

            let iconSize = baseIconSize * sizeMultiplier  // NEW: dynamic size
            let baseX = (canvasSize.width - iconSize) / 2   // MOVED: per-icon centering
            let baseY = (canvasSize.height - iconSize) / 2  // MOVED: per-icon centering

            let rect = NSRect(x: baseX + offsetX, y: baseY + offsetY, width: iconSize, height: iconSize)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 185.4 / 1024, yRadius: rect.height * 185.4 / 1024)

            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            frame.icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            NSGraphicsContext.restoreGraphicsState()
        }

        image.unlockFocus()
        image.size = NSSize(width: 256, height: 256)
        return image
    }

    // MARK: - Notifications

    private func registerNotifications() {
        let bundlePathHash = vmBundleURL.path.stableHash

        // Listen for stop command
        center.addObserver(
            forName: NSNotification.Name("com.ghostvm.helper.stop.\(bundlePathHash)"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopVM()
        }

        // Listen for suspend command
        center.addObserver(
            forName: NSNotification.Name("com.ghostvm.helper.suspend.\(bundlePathHash)"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.suspendVM()
        }

        // Listen for terminate command
        center.addObserver(
            forName: NSNotification.Name("com.ghostvm.helper.terminate.\(bundlePathHash)"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.terminateVM()
        }
    }

    private func postStateChange() {
        guard let vmBundleURL = vmBundleURL else { return }
        let bundlePathHash = vmBundleURL.path.stableHash
        NSLog("GhostVMHelper: Posting state '\(state.rawValue)' for hash \(bundlePathHash)")
        NSLog("GhostVMHelper: Bundle path: \(vmBundleURL.path)")
        center.postNotificationName(
            NSNotification.Name("com.ghostvm.helper.state.\(bundlePathHash)"),
            object: nil,
            userInfo: [
                "state": state.rawValue,
                "bundlePath": vmBundleURL.path,
                "pid": ProcessInfo.processInfo.processIdentifier
            ],
            deliverImmediately: true
        )
    }

    // MARK: - VM Lifecycle

    private func startVM() {
        guard VZVirtualMachine.isSupported else {
            showErrorAndQuit("Virtualization is not supported on this Mac.")
            return
        }

        state = .starting
        postStateChange()
        // Overlay will be shown after window is created

        do {
            // Load VM configuration
            layout = VMFileLayout(bundleURL: vmBundleURL)
            let store = VMConfigStore(layout: layout!)
            var config = try store.load()

            // Check if already running
            if let owner = readVMLockOwner(from: layout!.pidFileURL) {
                if kill(owner.pid, 0) == 0 {
                    throw VMError.message("VM '\(vmName)' is already running (PID \(owner.pid)).")
                } else {
                    removeVMLock(at: layout!.pidFileURL)
                }
            }

            // Check icon mode
            activeIconMode = config.iconMode

            // Generate MAC address if needed
            if config.macAddress == nil {
                config.macAddress = VZMACAddress.randomLocallyAdministered().string
                config.modifiedAt = Date()
                try store.save(config)
            }

            // Build VM configuration
            let builder = VMConfigurationBuilder(layout: layout!, storedConfig: config)
            let vmConfiguration = try builder.makeConfiguration(headless: false, connectSerialToStandardIO: false, runtimeSharedFolder: nil)

            // Create VM
            vmQueue = DispatchQueue(label: "ghostvm.helper.\(vmName)")
            virtualMachine = VZVirtualMachine(configuration: vmConfiguration, queue: vmQueue!)
            virtualMachine!.delegate = self

            // Create window and view
            createWindow()

            // Show starting overlay (distinguish between resuming and cold start)
            let wasSuspended = config.isSuspended && fileManager.fileExists(atPath: layout!.suspendStateURL.path)
            if wasSuspended {
                statusOverlay?.setState(.info(message: "Resuming..."))
            } else {
                statusOverlay?.setState(.starting)
            }

            // Write lock file
            try writeVMLockOwner(.embedded(ProcessInfo.processInfo.processIdentifier), to: layout!.pidFileURL)
            ownsLock = true

            // Start or resume VM
            if wasSuspended {
                resumeVM()
            } else if bootToRecovery {
                vmQueue!.async {
                    let options = VZMacOSVirtualMachineStartOptions()
                    options.startUpFromMacOSRecovery = true
                    self.virtualMachine!.start(options: options) { error in
                        DispatchQueue.main.async {
                            if let error = error {
                                self.handleStartResult(.failure(error))
                            } else {
                                self.handleStartResult(.success(()))
                            }
                        }
                    }
                }
            } else {
                vmQueue!.async {
                    self.virtualMachine!.start { result in
                        DispatchQueue.main.async {
                            self.handleStartResult(result)
                        }
                    }
                }
            }

        } catch {
            NSLog("GhostVMHelper: Failed to start VM: \(error)")
            showErrorAndQuit(error.localizedDescription)
        }
    }

    private func resumeVM() {
        guard let vm = virtualMachine, let queue = vmQueue, let layout = layout else { return }

        queue.async {
            vm.restoreMachineStateFrom(url: layout.suspendStateURL) { restoreError in
                if let error = restoreError {
                    DispatchQueue.main.async {
                        self.handleStartFailure(error)
                    }
                    return
                }

                vm.resume { resumeResult in
                    DispatchQueue.main.async {
                        switch resumeResult {
                        case .success:
                            // Clear suspend state
                            try? self.fileManager.removeItem(at: layout.suspendStateURL)
                            let store = VMConfigStore(layout: layout)
                            if var config = try? store.load() {
                                config.isSuspended = false
                                config.modifiedAt = Date()
                                try? store.save(config)
                            }
                            self.handleStartResult(.success(()))
                        case .failure(let error):
                            self.handleStartFailure(error)
                        }
                    }
                }
            }
        }
    }

    private func handleStartResult(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            state = .running
            postStateChange()
            updateWindowTitle()
            helperToolbar?.setVMRunning(true)

            // Hide starting overlay
            statusOverlay?.setState(.hidden)

            // Start services
            startServices()

            // Show window
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            NSLog("GhostVMHelper: VM '\(vmName)' is now running")

        case .failure(let error):
            handleStartFailure(error)
        }
    }

    private func updateWindowTitle() {
        let stateLabel: String
        switch state {
        case .starting:
            stateLabel = "Starting..."
        case .running:
            stateLabel = ""
        case .stopping:
            stateLabel = "Shutting Down..."
        case .suspending:
            stateLabel = "Suspending..."
        case .stopped:
            stateLabel = "Stopped"
        case .failed:
            stateLabel = "Error"
        }

        if stateLabel.isEmpty {
            window?.title = vmName
        } else {
            window?.title = "\(vmName) - \(stateLabel)"
        }
    }

    private func handleStartFailure(_ error: Error) {
        NSLog("GhostVMHelper: Failed to start VM: \(error)")
        cleanup()
        showErrorAndQuit(error.localizedDescription)
    }

    private func stopVM() {
        guard state == .running else { return }

        // Fire-and-forget: just send the power button event.
        // Don't change state or stop services — the guest may show a
        // confirmation dialog and the user might cancel.  If the guest
        // actually shuts down, guestDidStop() will call handleTermination().
        vmQueue?.async {
            do {
                try self.virtualMachine?.requestStop()
            } catch {
                DispatchQueue.main.async {
                    self.terminateVM()
                }
            }
        }

        // Brief cooldown to prevent accidental double-taps
        helperToolbar?.setShutDownEnabled(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.state == .running else { return }
            self.helperToolbar?.setShutDownEnabled(true)
        }
    }

    private func suspendVM() {
        guard state == .running, let vm = virtualMachine, let queue = vmQueue, let layout = layout else { return }

        state = .suspending
        postStateChange()
        updateWindowTitle()
        helperToolbar?.setVMRunning(false)
        stopServices()

        // Show suspending overlay
        statusOverlay?.setState(.suspending)

        // Remove existing suspend file
        try? fileManager.removeItem(at: layout.suspendStateURL)

        queue.async {
            vm.pause { pauseResult in
                switch pauseResult {
                case .success:
                    vm.saveMachineStateTo(url: layout.suspendStateURL) { saveError in
                        DispatchQueue.main.async {
                            if let error = saveError {
                                NSLog("GhostVMHelper: Failed to save state: \(error)")
                                // Resume since save failed
                                queue.async {
                                    vm.resume { _ in
                                        DispatchQueue.main.async {
                                            self.state = .running
                                            self.postStateChange()
                                        }
                                    }
                                }
                                return
                            }

                            // Mark as suspended in config
                            let store = VMConfigStore(layout: layout)
                            if var config = try? store.load() {
                                config.isSuspended = true
                                config.modifiedAt = Date()
                                try? store.save(config)
                            }

                            NSLog("GhostVMHelper: VM '\(self.vmName)' suspended")
                            self.handleTermination()
                        }
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        NSLog("GhostVMHelper: Failed to pause VM: \(error)")
                        self.state = .running
                        self.postStateChange()
                    }
                }
            }
        }
    }

    private func terminateVM() {
        guard let vm = virtualMachine, let queue = vmQueue else {
            NSApp.terminate(nil)
            return
        }

        state = .stopping
        postStateChange()

        queue.async {
            vm.stop { _ in
                DispatchQueue.main.async {
                    self.handleTermination()
                }
            }
        }
    }

    private func handleTermination() {
        // Snapshot current Dock icon as Finder icon for the VM bundle
        if let icon = NSApp.applicationIconImage {
            NSWorkspace.shared.setIcon(icon, forFile: vmBundleURL.path, options: [])

            // For dynamic icon modes, persist the current dock icon as icon.png
            // so the main app and Finder show the last active icon
            if activeIconMode == "stack" || activeIconMode == "app" || activeIconMode == "glass",
               let layout = self.layout,
               let tiff = icon.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: layout.customIconURL)
            }
        }
        cleanup()
        state = .stopped
        postStateChange()
        NSApp.terminate(nil)
    }

    private func cleanup() {
        stopServices()
        if ownsLock, let layout = layout {
            removeVMLock(at: layout.pidFileURL)
            ownsLock = false
        }
        vmView?.virtualMachine = nil
    }

    // MARK: - Services

    private func startServices() {
        guard let vm = virtualMachine, let queue = vmQueue else { return }

        // 1. Create GhostClient
        let client = GhostClient(virtualMachine: vm, vmQueue: queue)
        self.ghostClient = client

        // 1b. Host API service (Unix domain socket for vmctl)
        let apiService = HostAPIService(vmName: vmName)
        apiService.start(client: client, vmWindow: self.window)
        self.hostAPIService = apiService

        // 2. Persistent health check (vsock port 5002)
        let hcService = HealthCheckService()
        hcService.start(client: client)
        self.healthCheckService = hcService
        // Bind status to toolbar
        healthCheckCancellable = hcService.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.helperToolbar?.setGuestToolsStatus(status)
            }

        // 3. Port forwarding
        let pfService = PortForwardService(vm: vm, queue: queue)
        self.portForwardService = pfService
        let forwards = loadPortForwards()
        if !forwards.isEmpty {
            pfService.start(forwards: forwards)
        }
        updateToolbarPortForwards()

        // 3b. Shared folder management
        let fsService = FolderShareService(vm: vm, queue: queue)
        self.folderShareService = fsService
        let folders = loadSharedFolders()
        fsService.start(folders: folders)
        updateToolbarSharedFolders()

        // 4. Clipboard sync (event-driven via window focus/blur)
        let cbService = ClipboardSyncService(bundlePath: vmBundleURL.path)
        cbService.configure(client: client)
        self.clipboardSyncService = cbService

        // Load persisted mode (normalize legacy directional modes to bidirectional)
        let key = "clipboardSyncMode_\(vmBundleURL.path.stableHash)"
        if let storedMode = UserDefaults.standard.string(forKey: key) {
            let effectiveMode: ClipboardSyncMode = (storedMode == "disabled") ? .disabled : .bidirectional
            cbService.setSyncMode(effectiveMode)
            helperToolbar?.setClipboardSyncMode(effectiveMode.rawValue)
        }

        // Observe window focus/blur to trigger clipboard sync
        if let win = self.window {
            let becomeKeyObs = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                self?.handleClipboardOnFocus()
            }
            let resignKeyObs = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                self?.clipboardSyncService?.windowDidResignKey()
            }
            windowFocusObservers = [becomeKeyObs, resignKeyObs]
        }

        // 5. File transfer (no polling — driven by EventStreamService)
        let ftService = FileTransferService()
        ftService.configure(client: client)
        self.fileTransferService = ftService

        // 6. Event stream (replaces log polling + file queue polling + URL polling)
        let esService = EventStreamService()
        esService.start(client: client)
        self.eventStreamService = esService
        // Bind queued file count to toolbar (from event stream)
        fileTransferCancellable = esService.$queuedGuestFiles
            .receive(on: RunLoop.main)
            .sink { [weak self] files in
                self?.fileTransferService?.updateQueuedFiles(files)
                self?.helperToolbar?.setQueuedFileCount(files.count)
            }
        // Also track when fetchAllGuestFiles resets the count (host-side clear)
        fileCountCancellable = ftService.$queuedGuestFileCount
            .receive(on: RunLoop.main)
            .sink { [weak self] count in
                self?.helperToolbar?.setQueuedFileCount(count)
            }

        // 6b. URL permission — subscribe to pending URLs
        urlPermissionCancellable = esService.$pendingURLs
            .receive(on: RunLoop.main)
            .sink { [weak self] urls in
                self?.handlePendingURLs(urls)
            }

        // 6c. Dynamic icon — subscribe to foreground app changes
        foregroundAppCancellable = esService.$foregroundApp
            .receive(on: RunLoop.main)
            .sink { [weak self] app in
                self?.handleForegroundAppChange(app)
            }

        // 7. Auto port mapping
        let apmService = AutoPortMapService()
        apmService.start(
            portForwardService: pfService,
            eventStreamService: esService,
            manualForwards: forwards
        )
        self.autoPortMapService = apmService

        // Load persisted toggle
        let autoPortMapKey = "autoPortMap_\(vmBundleURL.path.stableHash)"
        let autoPortMapEnabled = UserDefaults.standard.object(forKey: autoPortMapKey) as? Bool ?? true
        apmService.setEnabled(autoPortMapEnabled)
        helperToolbar?.setAutoPortMapEnabled(autoPortMapEnabled)

        // Bind auto-mapped ports to toolbar updates
        autoPortMapCancellable = apmService.$autoMappedPorts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateToolbarPortForwards()
            }

        // Bind newly forwarded ports to notification popover
        newlyForwardedCancellable = apmService.$newlyForwardedPorts
            .receive(on: RunLoop.main)
            .sink { [weak self] ports in
                self?.handleNewlyForwardedPorts(ports)
            }

        // Bind blocked ports to toolbar display
        blockedPortsCancellable = apmService.$blockedPorts
            .receive(on: RunLoop.main)
            .sink { [weak self] blocked in
                self?.updateBlockedPortsDisplay(blocked)
            }

        NSLog("GhostVMHelper: Services started for '\(vmName)'")
    }

    private func stopServices() {
        newlyForwardedCancellable?.cancel()
        newlyForwardedCancellable = nil
        blockedPortsCancellable?.cancel()
        blockedPortsCancellable = nil
        autoPortMapCancellable?.cancel()
        autoPortMapCancellable = nil
        autoPortMapService?.stop()
        autoPortMapService = nil

        healthCheckCancellable?.cancel()
        healthCheckCancellable = nil
        healthCheckService?.stop()
        healthCheckService = nil
        helperToolbar?.setGuestToolsStatus(.connecting)

        portForwardService?.stop()
        portForwardService = nil

        folderShareService?.stop()
        folderShareService = nil

        for obs in windowFocusObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowFocusObservers = []

        clipboardSyncService?.stop()
        clipboardSyncService = nil

        fileTransferCancellable?.cancel()
        fileTransferCancellable = nil
        fileCountCancellable?.cancel()
        fileCountCancellable = nil
        fileTransferService = nil

        urlPermissionCancellable?.cancel()
        urlPermissionCancellable = nil

        foregroundAppCancellable?.cancel()
        foregroundAppCancellable = nil
        cancelIconAnimation()
        iconStack = []
        if activeIconMode != nil {
            loadCustomIcon()
        }

        eventStreamService?.stop()
        eventStreamService = nil

        hostAPIService?.stop()
        hostAPIService = nil

        ghostClient = nil
    }

    // MARK: - Port Forward Persistence

    private func loadPortForwards() -> [PortForwardConfig] {
        guard let layout = layout else { return [] }
        do {
            let store = VMConfigStore(layout: layout)
            let config = try store.load()
            return config.portForwards
        } catch {
            NSLog("GhostVMHelper: Failed to load port forwards: \(error)")
            return []
        }
    }

    private func updateToolbarPortForwards() {
        guard let service = portForwardService else {
            helperToolbar?.setPortForwardEntries([])
            return
        }
        let autoHostPorts = autoPortMapService?.autoMappedHostPorts ?? []
        let entries = service.activeForwards.map { fwd in
            let isAuto = autoHostPorts.contains(fwd.hostPort)
            let procName = isAuto ? autoPortMapService?.processNames[fwd.guestPort] : nil
            return PortForwardEntry(
                hostPort: fwd.hostPort,
                guestPort: fwd.guestPort,
                enabled: fwd.enabled,
                isAutoMapped: isAuto,
                processName: procName
            )
        }
        let summary = entries.map { "\($0.processName ?? "nil"):\($0.guestPort)→\($0.hostPort)" }
        NSLog("GhostVMHelper: updateToolbarPortForwards: %@", summary.joined(separator: ", "))
        helperToolbar?.setPortForwardEntries(entries)
    }

    /// Returns the set of host ports from manually-configured port forwards
    /// (i.e. active forwards minus auto-mapped ones).
    private func manualPortSet() -> Set<UInt16> {
        let allPorts = Set(portForwardService?.activeForwards.map { $0.hostPort } ?? [])
        let autoHostPorts = autoPortMapService?.autoMappedHostPorts ?? []
        return allPorts.subtracting(autoHostPorts)
    }

    private func persistPortForwards() {
        guard let service = portForwardService else { return }
        let autoHostPorts = autoPortMapService?.autoMappedHostPorts ?? []
        let activeForwards = service.activeForwards.filter { !autoHostPorts.contains($0.hostPort) }
        let bundleURL = self.vmBundleURL!

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let layout = VMFileLayout(bundleURL: bundleURL)
                let store = VMConfigStore(layout: layout)
                var config = try store.load()
                config.portForwards = activeForwards
                try store.save(config)
                NSLog("GhostVMHelper: Persisted \(activeForwards.count) port forward(s)")
            } catch {
                NSLog("GhostVMHelper: Failed to persist port forwards: \(error)")
            }
        }
    }

    // MARK: - Shared Folder Persistence

    private func loadSharedFolders() -> [SharedFolderConfig] {
        guard let layout = layout else { return [] }
        do {
            let store = VMConfigStore(layout: layout)
            let config = try store.load()
            // Prefer sharedFolders array; fall back to legacy sharedFolderPath
            if !config.sharedFolders.isEmpty {
                return config.sharedFolders
            }
            if let legacyPath = config.sharedFolderPath, !legacyPath.isEmpty {
                return [SharedFolderConfig(path: legacyPath, readOnly: config.sharedFolderReadOnly)]
            }
            return []
        } catch {
            NSLog("GhostVMHelper: Failed to load shared folders: \(error)")
            return []
        }
    }

    private func updateToolbarSharedFolders() {
        guard let service = folderShareService else {
            helperToolbar?.setSharedFolderEntries([])
            return
        }
        let entries = service.activeFolders.map { folder in
            SharedFolderEntry(id: folder.id, path: folder.path, readOnly: folder.readOnly)
        }
        helperToolbar?.setSharedFolderEntries(entries)
    }

    private func persistSharedFolders() {
        guard let service = folderShareService else { return }
        let activeFolders = service.activeFolders
        let bundleURL = self.vmBundleURL!

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let layout = VMFileLayout(bundleURL: bundleURL)
                let store = VMConfigStore(layout: layout)
                var config = try store.load()
                config.sharedFolders = activeFolders
                // Clear legacy fields when using the new array
                config.sharedFolderPath = nil
                config.sharedFolderReadOnly = false
                try store.save(config)
                NSLog("GhostVMHelper: Persisted \(activeFolders.count) shared folder(s)")
            } catch {
                NSLog("GhostVMHelper: Failed to persist shared folders: \(error)")
            }
        }
    }

    // MARK: - Window

    private func createWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = vmName
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 512, height: 512)
        window.collectionBehavior = [.fullScreenPrimary]

        // Setup toolbar
        let toolbar = HelperToolbar()
        toolbar.delegate = self
        toolbar.attach(to: window)
        helperToolbar = toolbar

        // Create container view for VM and overlay
        let containerView = NSView()
        containerView.wantsLayer = true
        window.contentView = containerView

        // Create VM view
        let vmView = FocusableVMView()
        vmView.fileTransferDelegate = self
        if #available(macOS 14.0, *) {
            vmView.automaticallyReconfiguresDisplay = true
        }
        vmView.translatesAutoresizingMaskIntoConstraints = false
        vmView.virtualMachine = virtualMachine

        // Set initial capture system keys preference (default: true)
        let captureKeysKey = "captureSystemKeys_\(vmBundleURL.path.stableHash)"
        let captureKeys = UserDefaults.standard.object(forKey: captureKeysKey) as? Bool ?? true
        vmView.capturesSystemKeys = captureKeys
        toolbar.setCaptureSystemKeys(captureKeys)

        // Load persisted capture quit/hide preferences (independent of capture inputs)
        let captureQuitKey = "captureQuit_\(vmBundleURL.path.stableHash)"
        let captureQuit = UserDefaults.standard.bool(forKey: captureQuitKey)
        let captureHideKey = "captureHide_\(vmBundleURL.path.stableHash)"
        let captureHide = UserDefaults.standard.bool(forKey: captureHideKey)

        captureQuitEnabled = captureQuit
        toolbar.setCaptureQuit(captureQuit)
        if captureQuit {
            (NSApp as? HelperApplication)?.captureQuitEnabled = true
            quitMenuItem?.keyEquivalent = ""
        }

        captureHideEnabled = captureHide
        toolbar.setCaptureHide(captureHide)
        if captureHide {
            (NSApp as? HelperApplication)?.captureHideEnabled = true
            hideMenuItem?.keyEquivalent = ""
        }

        // Load persisted open-URLs-automatically preference
        let openURLsKey = "openURLsAutomatically_\(vmBundleURL.path.stableHash)"
        let openURLsAuto = UserDefaults.standard.bool(forKey: openURLsKey)
        urlAlwaysAllowed = openURLsAuto
        toolbar.setOpenURLsAutomatically(openURLsAuto)

        containerView.addSubview(vmView)

        // Create status overlay (on top of VM view)
        let overlay = StatusOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(overlay)

        // Layout constraints
        NSLayoutConstraint.activate([
            vmView.topAnchor.constraint(equalTo: containerView.topAnchor),
            vmView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            vmView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            vmView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            overlay.topAnchor.constraint(equalTo: containerView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        self.window = window
        self.vmView = vmView
        self.statusOverlay = overlay
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isUITesting { return true }
        switch state {
        case .stopped, .failed:
            return true
        case .running:
            // Suspend on window close
            suspendVM()
            return false
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        vmView?.virtualMachine = nil
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.toolbar?.isVisible = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        DispatchQueue.main.async {
            self.window?.toolbar?.isVisible = true
        }
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async {
            NSLog("GhostVMHelper: Guest did stop")
            self.handleTermination()
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async {
            NSLog("GhostVMHelper: VM stopped with error: \(error)")
            self.state = .failed
            self.postStateChange()
            self.cleanup()
            self.showErrorAndQuit(error.localizedDescription)
        }
    }

    // MARK: - Error Handling

    private func showErrorAndQuit(_ message: String) {
        state = .failed
        postStateChange()

        let alert = NSAlert()
        alert.messageText = "VM Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()

        NSApp.terminate(nil)
    }
}

// MARK: - Custom NSApplication

/// Overrides sendEvent to intercept CMD+Q and CMD+H before the event
/// reaches VZVirtualMachineView, which consumes all key events via
/// performKeyEquivalent — preventing the normal menu-based hide/quit
/// from ever firing.
@objc(HelperApplication)
final class HelperApplication: NSApplication {
    var captureQuitEnabled = false
    var captureHideEnabled = false

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let chars = event.charactersIgnoringModifiers {
                if chars == "q" {
                    if captureQuitEnabled {
                        terminate(nil)
                        return
                    }
                    // else: let event flow to VM guest
                }
                if chars == "h" {
                    if captureHideEnabled {
                        // Explicitly hide — VZVirtualMachineView would eat
                        // the event before the menu system can trigger hide
                        hide(nil)
                        return
                    }
                    // else: let event flow to VM guest
                }
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Main Entry Point

// IMPORTANT: Ignore SIGPIPE signal
//
// GhostVMHelper runs as a separate process, so it does NOT inherit
// the parent app's signal disposition. When writing to a socket/pipe
// after the remote end has closed (e.g., browser reload, guest
// disconnect), the OS sends SIGPIPE which terminates the process.
// By ignoring SIGPIPE, write() returns -1 with errno=EPIPE instead,
// which PortForwardListener handles gracefully.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = HelperApplication.shared
    let delegate = HelperAppDelegate()
    app.delegate = delegate
    app.run()
}
