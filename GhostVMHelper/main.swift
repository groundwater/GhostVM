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
    private var fileTransferService: FileTransferService?
    private var eventStreamService: EventStreamService?
    private var healthCheckService: HealthCheckService?
    private var fileTransferCancellable: AnyCancellable?
    private var healthCheckCancellable: AnyCancellable?
    private var windowFocusObservers: [NSObjectProtocol] = []

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Parse command line arguments
        let args = ProcessInfo.processInfo.arguments
        guard let bundleIndex = args.firstIndex(of: "--vm-bundle"), bundleIndex + 1 < args.count else {
            NSLog("GhostVMHelper: Missing --vm-bundle argument")
            showErrorAndQuit("Missing --vm-bundle argument")
            return
        }

        let bundlePath = args[bundleIndex + 1]
        vmBundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        vmName = vmBundleURL.deletingPathExtension().lastPathComponent
        ProcessInfo.processInfo.processName = vmName

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

    // MARK: - Custom Icon

    private func loadCustomIcon() {
        let iconURL = vmBundleURL.appendingPathComponent("icon.png")

        if fileManager.fileExists(atPath: iconURL.path),
           let image = NSImage(contentsOf: iconURL) {
            // Set custom Dock icon
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            NSApp.dockTile.contentView = imageView
            NSApp.dockTile.display()
            NSLog("GhostVMHelper: Loaded custom icon from \(iconURL.path)")
        } else {
            NSLog("GhostVMHelper: No custom icon found at \(iconURL.path)")
        }
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

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

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

        // Clipboard Sync submenu
        let clipboardItem = NSMenuItem(title: "Clipboard Sync", action: nil, keyEquivalent: "")
        let clipboardSubmenu = NSMenu(title: "Clipboard Sync")
        clipboardItem.submenu = clipboardSubmenu
        vmMenu.addItem(clipboardItem)

        let syncModes = [
            ("Bidirectional", "bidirectional"),
            ("Host → Guest", "hostToGuest"),
            ("Guest → Host", "guestToHost"),
            ("Disabled", "disabled")
        ]
        for (title, mode) in syncModes {
            let item = NSMenuItem(title: title, action: #selector(setClipboardSyncMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            clipboardSubmenu.addItem(item)
        }

        vmMenu.addItem(NSMenuItem.separator())

        let suspendItem = NSMenuItem(title: "Suspend", action: #selector(suspendVMAction), keyEquivalent: "s")
        suspendItem.keyEquivalentModifierMask = [.command, .option]
        suspendItem.target = self
        vmMenu.addItem(suspendItem)

        let shutdownItem = NSMenuItem(title: "Shut Down", action: #selector(shutdownVMAction), keyEquivalent: "q")
        shutdownItem.keyEquivalentModifierMask = [.command, .option]
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

        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        let fullscreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreenItem.keyEquivalentModifierMask = [.command, .control]
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
        terminateVM()
    }

    @objc private func setClipboardSyncMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        toolbar(helperToolbar!, didSelectClipboardSyncMode: mode)
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
        case #selector(setClipboardSyncMode(_:)):
            if let modeString = menuItem.representedObject as? String,
               let currentMode = clipboardSyncService?.syncMode {
                menuItem.state = (modeString == currentMode.rawValue) ? .on : .off
            }
            return state == .running
        default:
            return true
        }
    }

    // MARK: - HelperToolbarDelegate

    func toolbar(_ toolbar: HelperToolbar, didSelectClipboardSyncMode mode: String) {
        guard let syncMode = ClipboardSyncMode(rawValue: mode) else { return }
        clipboardSyncService?.setSyncMode(syncMode)
        helperToolbar?.setClipboardSyncMode(mode)

        // Persist per-VM
        let key = "clipboardSyncMode_\(vmBundleURL.path.stableHash)"
        UserDefaults.standard.set(mode, forKey: key)
        NSLog("GhostVMHelper: Clipboard sync mode changed to \(mode)")
    }

    func toolbar(_ toolbar: HelperToolbar, didAddPortForward hostPort: UInt16, guestPort: UInt16) {
        let config = PortForwardConfig(hostPort: hostPort, guestPort: guestPort, enabled: true)
        do {
            try portForwardService?.addForward(config)
            updateToolbarPortForwards()
            persistPortForwards()
            NSLog("GhostVMHelper: Added port forward \(hostPort) -> \(guestPort)")
        } catch {
            NSLog("GhostVMHelper: Failed to add port forward: \(error)")
        }
    }

    func toolbar(_ toolbar: HelperToolbar, didRemovePortForwardWithHostPort hostPort: UInt16) {
        portForwardService?.removeForward(hostPort: hostPort)
        updateToolbarPortForwards()
        persistPortForwards()
        NSLog("GhostVMHelper: Removed port forward with host port \(hostPort)")
    }

    func toolbarDidRequestPortForwardEditor(_ toolbar: HelperToolbar) {
        NSLog("GhostVMHelper: Port forward editor requested")
    }

    func toolbarDidRequestReceiveFiles(_ toolbar: HelperToolbar) {
        window?.level = .normal
        fileTransferService?.fetchAllGuestFiles()
        restoreVMViewFocus()
    }

    func toolbarDidRequestDenyFiles(_ toolbar: HelperToolbar) {
        window?.level = .normal
        fileTransferService?.clearGuestFileQueue()
        restoreVMViewFocus()
    }

    func toolbarQueuedFilesPanelDidClose(_ toolbar: HelperToolbar) {
        window?.level = .normal
        restoreVMViewFocus()
    }

    func toolbarDidDetectNewQueuedFiles(_ toolbar: HelperToolbar) {
        Task {
            let files = (try? await fileTransferService?.listGuestFiles()) ?? []
            let names = files.map { URL(fileURLWithPath: $0).lastPathComponent }
            helperToolbar?.setQueuedFileNames(names)

            // Float the window above ALL other apps — this is the only
            // reliable way to appear in front on macOS 14+.
            window?.level = .floating
            window?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.requestUserAttention(.criticalRequest)

            try? await Task.sleep(for: .milliseconds(200))

            helperToolbar?.showQueuedFilesPopover()
        }
    }

    func toolbarDidRequestShutDown(_ toolbar: HelperToolbar) {
        stopVM()
    }

    func toolbarDidRequestTerminate(_ toolbar: HelperToolbar) {
        terminateVM()
    }

    // MARK: - FileTransferDelegate

    func fileTransfer(didReceiveFiles files: [FileWithRelativePath]) {
        NSLog("GhostVMHelper: Sending \(files.count) file(s) to guest")
        fileTransferService?.sendFiles(files)
    }

    private func restoreVMViewFocus() {
        if let vmView = vmView {
            window?.makeFirstResponder(vmView)
        }
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

        state = .stopping
        postStateChange()
        updateWindowTitle()
        helperToolbar?.setVMRunning(false)
        stopServices()

        vmQueue?.async {
            do {
                try self.virtualMachine?.requestStop()
            } catch {
                DispatchQueue.main.async {
                    self.terminateVM()
                }
            }
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

        // 2. Persistent health check (vsock port 5002)
        let hcService = HealthCheckService()
        hcService.start(client: client)
        self.healthCheckService = hcService
        // Bind isConnected to toolbar
        healthCheckCancellable = hcService.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.helperToolbar?.setGuestToolsConnected(connected)
            }

        // 3. Port forwarding
        let pfService = PortForwardService(vm: vm, queue: queue)
        self.portForwardService = pfService
        let forwards = loadPortForwards()
        if !forwards.isEmpty {
            pfService.start(forwards: forwards)
        }
        updateToolbarPortForwards()

        // 4. Clipboard sync (event-driven via window focus/blur)
        let cbService = ClipboardSyncService(bundlePath: vmBundleURL.path)
        cbService.configure(client: client)
        self.clipboardSyncService = cbService

        // Load persisted mode
        let key = "clipboardSyncMode_\(vmBundleURL.path.stableHash)"
        if let storedMode = UserDefaults.standard.string(forKey: key),
           let mode = ClipboardSyncMode(rawValue: storedMode) {
            cbService.setSyncMode(mode)
            helperToolbar?.setClipboardSyncMode(storedMode)
        }

        // Observe window focus/blur to trigger clipboard sync
        if let win = self.window {
            let becomeKeyObs = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                self?.clipboardSyncService?.windowDidBecomeKey()
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
        // Bind queued file count to toolbar
        fileTransferCancellable = esService.$queuedGuestFiles
            .receive(on: RunLoop.main)
            .sink { [weak self] files in
                self?.fileTransferService?.updateQueuedFiles(files)
                self?.helperToolbar?.setQueuedFileCount(files.count)
            }

        NSLog("GhostVMHelper: Services started for '\(vmName)'")
    }

    private func stopServices() {
        healthCheckCancellable?.cancel()
        healthCheckCancellable = nil
        healthCheckService?.stop()
        healthCheckService = nil
        helperToolbar?.setGuestToolsConnected(false)

        portForwardService?.stop()
        portForwardService = nil

        for obs in windowFocusObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowFocusObservers = []

        clipboardSyncService?.stop()
        clipboardSyncService = nil

        fileTransferCancellable?.cancel()
        fileTransferCancellable = nil
        fileTransferService = nil

        eventStreamService?.stop()
        eventStreamService = nil

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
        let entries = service.activeForwards.map { fwd in
            PortForwardEntry(hostPort: fwd.hostPort, guestPort: fwd.guestPort, enabled: fwd.enabled)
        }
        helperToolbar?.setPortForwardEntries(entries)
    }

    private func persistPortForwards() {
        guard let service = portForwardService else { return }
        let activeForwards = service.activeForwards
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
        window.minSize = NSSize(width: 1024, height: 640)
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
    let delegate = HelperAppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
