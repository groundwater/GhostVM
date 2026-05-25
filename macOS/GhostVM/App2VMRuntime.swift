import Foundation
import AppKit
import Combine
@preconcurrency import Virtualization
import GhostVMKit

// Registry for active VM sessions, keyed by bundle path.
// This allows the VM list to send terminate commands to running VMs.
final class App2VMSessionRegistry {
    static let shared = App2VMSessionRegistry()
    private var sessions: [String: App2VMRunSession] = [:]
    private let lock = NSLock()

    private init() {}

    func register(_ session: App2VMRunSession) {
        lock.lock()
        defer { lock.unlock() }
        sessions[session.bundleURL.path] = session
    }

    func unregister(_ session: App2VMRunSession) {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeValue(forKey: session.bundleURL.path)
    }

    func session(for bundlePath: String) -> App2VMRunSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[bundlePath]
    }

    func terminateSession(for bundlePath: String) {
        lock.lock()
        let session = sessions[bundlePath]
        lock.unlock()
        session?.terminate()
    }

    // MARK: - ASIF Migration

    /// Retained reference to the migration prompt panel so it isn't
    /// deallocated while visible (avoids CoreAnimation use-after-free).
    fileprivate static var migrationPanel: NSPanel?

    private static func promptMigration(bundleURL: URL, store: App2VMStore, vmID: App2VM.ID, recovery: Bool) {
        DispatchQueue.main.async {
            let vmName = bundleURL.deletingPathExtension().lastPathComponent

            // Build a lightweight NSPanel instead of NSAlert.
            // NSAlert's internal _NSWindowTransformAnimation is deallocated
            // by SwiftUI's window management, causing a use-after-free crash
            // ~30s after dismissal on macOS 26. A plain NSPanel we retain
            // ourselves has no such animation object.
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            panel.title = "Upgrade Disk Format"
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.level = .modalPanel
            panel.isReleasedWhenClosed = false
            Self.migrationPanel = panel

            // --- Layout ---
            let contentView = NSView(frame: panel.contentView!.bounds)
            contentView.autoresizingMask = [.width, .height]

            let icon = NSImageView(frame: NSRect(x: 20, y: 130, width: 48, height: 48))
            icon.image = NSImage(named: NSImage.cautionName)
            contentView.addSubview(icon)

            let titleLabel = NSTextField(labelWithString: "Upgrade \"\(vmName)\" Disk Format?")
            titleLabel.font = .boldSystemFont(ofSize: 13)
            titleLabel.frame = NSRect(x: 78, y: 158, width: 320, height: 20)
            contentView.addSubview(titleLabel)

            let infoLabel = NSTextField(wrappingLabelWithString:
                "This VM uses an older disk format. Migrating to ASIF gives near-native SSD performance.\n\nThe original VM will not be modified.\n\n⚠ Snapshots and suspend state are not migrated.")
            infoLabel.frame = NSRect(x: 78, y: 48, width: 320, height: 108)
            infoLabel.font = .systemFont(ofSize: 11)
            contentView.addSubview(infoLabel)

            let migrateButton = NSButton(title: "Migrate\u{2026}", target: nil, action: nil)
            migrateButton.bezelStyle = .rounded
            migrateButton.keyEquivalent = "\r"
            migrateButton.frame = NSRect(x: 310, y: 12, width: 95, height: 30)
            contentView.addSubview(migrateButton)

            let notNowButton = NSButton(title: "Not Now", target: nil, action: nil)
            notNowButton.bezelStyle = .rounded
            notNowButton.keyEquivalent = "\u{1b}" // Escape
            notNowButton.frame = NSRect(x: 215, y: 12, width: 90, height: 30)
            contentView.addSubview(notNowButton)

            panel.contentView = contentView

            // --- Actions ---
            let handler = MigrationPromptHandler(
                panel: panel,
                bundleURL: bundleURL,
                store: store,
                vmID: vmID,
                recovery: recovery
            )
            // Keep handler alive as long as the panel is visible
            objc_setAssociatedObject(panel, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

            migrateButton.target = handler
            migrateButton.action = #selector(MigrationPromptHandler.migrate)

            notNowButton.target = handler
            notNowButton.action = #selector(MigrationPromptHandler.notNow)

            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    fileprivate static func runMigration(
        source: URL,
        destination: URL,
        store: App2VMStore,
        vmID: App2VM.ID,
        recovery: Bool
    ) {
        let migrationService = VMMigrationService()

        // Create progress window with terminal output
        let progressWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        progressWindow.title = "Migrating VM…"
        progressWindow.center()

        let statusLabel = NSTextField(labelWithString: "Starting migration…")
        statusLabel.frame = NSRect(x: 20, y: 288, width: 480, height: 20)
        statusLabel.font = .systemFont(ofSize: 12)

        let progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 265, width: 480, height: 20))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = false

        // Terminal-style output view
        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 50, width: 480, height: 210))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textColor = NSColor.labelColor
        textView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.frame = NSRect(x: 420, y: 12, width: 80, height: 30)

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        contentView.addSubview(statusLabel)
        contentView.addSubview(progressBar)
        contentView.addSubview(scrollView)
        contentView.addSubview(cancelButton)
        progressWindow.contentView = contentView
        progressWindow.makeKeyAndOrderFront(nil)

        cancelButton.target = migrationService
        cancelButton.action = #selector(VMMigrationService.cancel)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try migrationService.migrate(
                    source: source,
                    destination: destination,
                    progressHandler: { fraction, message in
                        DispatchQueue.main.async {
                            progressBar.doubleValue = fraction
                            statusLabel.stringValue = message
                        }
                    },
                    outputHandler: { line in
                        DispatchQueue.main.async {
                            textView.textStorage?.append(NSAttributedString(
                                string: line,
                                attributes: [
                                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                                    .foregroundColor: NSColor.labelColor,
                                ]
                            ))
                            textView.scrollToEndOfDocument(nil)
                        }
                    }
                )

                DispatchQueue.main.async {
                    // Swap VM in list
                    store.replaceBundleURL(vmID: vmID, newBundleURL: destination)

                    // Show success state with Boot button
                    progressBar.doubleValue = 1.0
                    statusLabel.stringValue = "Migration complete"
                    progressWindow.title = "Migration Complete"
                    cancelButton.isHidden = true

                    let bootButton = NSButton(title: "Boot Now", target: nil, action: nil)
                    bootButton.bezelStyle = .rounded
                    bootButton.keyEquivalent = "\r"
                    bootButton.frame = NSRect(x: 400, y: 12, width: 100, height: 30)
                    contentView.addSubview(bootButton)

                    // Boot action: hide window immediately, boot after animations settle
                    let bootAction = MigrationBootAction(window: progressWindow) {
                        App2VMSessionRegistry.shared.startVMSession(
                            bundleURL: destination, store: store, vmID: vmID, recovery: recovery
                        )
                    }
                    objc_setAssociatedObject(bootButton, "bootAction", bootAction, .OBJC_ASSOCIATION_RETAIN)
                    bootButton.target = bootAction
                    bootButton.action = #selector(MigrationBootAction.boot)
                }
            } catch {
                DispatchQueue.main.async {
                    statusLabel.stringValue = "Migration failed: \(error.localizedDescription)"
                    progressWindow.title = "Migration Failed"
                    let closeAction = MigrationBootAction(window: progressWindow) {}
                    objc_setAssociatedObject(cancelButton, "closeAction", closeAction, .OBJC_ASSOCIATION_RETAIN)
                    cancelButton.title = "Close"
                    cancelButton.target = closeAction
                    cancelButton.action = #selector(MigrationBootAction.boot)
                }
            }
        }
    }

}

/// Handles Migrate / Not Now buttons in the migration prompt panel.
/// Stored as an associated object on the panel so it stays alive while visible.
private final class MigrationPromptHandler: NSObject {
    private let panel: NSPanel
    private let bundleURL: URL
    private let store: App2VMStore
    private let vmID: App2VM.ID
    private let recovery: Bool

    init(panel: NSPanel, bundleURL: URL, store: App2VMStore, vmID: App2VM.ID, recovery: Bool) {
        self.panel = panel
        self.bundleURL = bundleURL
        self.store = store
        self.vmID = vmID
        self.recovery = recovery
    }

    private func dismissPanel() {
        panel.orderOut(nil)
        // Release the strong reference so the panel can be deallocated
        App2VMSessionRegistry.migrationPanel = nil
    }

    @objc func migrate() {
        dismissPanel()

        let savePanel = NSSavePanel()
        savePanel.title = "Save Migrated VM"
        savePanel.nameFieldStringValue = bundleURL.lastPathComponent
        savePanel.canCreateDirectories = true

        savePanel.begin { [bundleURL, store, vmID, recovery] response in
            if response == .OK, let destURL = savePanel.url {
                App2VMSessionRegistry.runMigration(
                    source: bundleURL,
                    destination: destURL,
                    store: store,
                    vmID: vmID,
                    recovery: recovery
                )
            }
        }
    }

    @objc func notNow() {
        dismissPanel()

        App2VMSessionRegistry.shared.startVMSession(
            bundleURL: bundleURL, store: store, vmID: vmID, recovery: recovery,
            skipHelperCopy: true
        )
    }
}

/// Handles Boot Now button: hides window, waits for animations to flush, then boots.
private final class MigrationBootAction: NSObject {
    private weak var window: NSWindow?
    private var onBoot: (() -> Void)?
    init(window: NSWindow, onBoot: @escaping () -> Void) {
        self.window = window
        self.onBoot = onBoot
    }
    @objc func boot() {
        window?.orderOut(nil)
        let callback = onBoot
        onBoot = nil // release captured references
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.window?.close()
            callback?()
        }
    }
}

extension App2VMSessionRegistry {
    /// Starts a VM by launching its helper app, or reconnects to an existing helper.
    /// Creates a session if needed.
    /// - Parameters:
    ///   - bundleURL: The VM bundle URL
    ///   - store: The VM store to update status in
    ///   - vmID: The VM's ID in the store for status updates
    ///   - runningPID: If non-nil, reconnect to an already-running helper instead of launching a new one
    func startVM(bundleURL: URL, store: App2VMStore, vmID: App2VM.ID, runningPID: pid_t? = nil, recovery: Bool = false) {
        // Check if disk needs ASIF migration (only for fresh launches, not reconnects)
        if runningPID == nil {
            let layout = VMFileLayout(bundleURL: bundleURL)
            let format = DiskFormat.detect(at: layout.diskURL)
            if !format.isASIF {
                Self.promptMigration(bundleURL: bundleURL, store: store, vmID: vmID, recovery: recovery)
                return
            }
        }

        startVMSession(bundleURL: bundleURL, store: store, vmID: vmID, runningPID: runningPID, recovery: recovery)
    }

    fileprivate func startVMSession(bundleURL: URL, store: App2VMStore, vmID: App2VM.ID, runningPID: pid_t? = nil, recovery: Bool = false, skipHelperCopy: Bool = false) {
        let path = bundleURL.standardizedFileURL.path
        lock.lock()
        var session = sessions[path]
        lock.unlock()

        if session == nil {
            session = App2VMRunSession(bundleURL: bundleURL)
            lock.lock()
            sessions[path] = session
            lock.unlock()
        }

        // Wire up status updates to the store
        session?.onStateChange = { [weak store, vmID, bundleURL] state in
            guard let store = store else { return }
            DispatchQueue.main.async {
                switch state {
                case .running:
                    store.updateStatus(for: vmID, status: "Running")
                case .starting:
                    store.updateStatus(for: vmID, status: "Starting…")
                case .suspending:
                    store.updateStatus(for: vmID, status: "Suspending…")
                case .stopping:
                    store.updateStatus(for: vmID, status: "Stopping…")
                case .stopped, .idle:
                    store.reloadVM(at: bundleURL)
                case .failed(let message):
                    store.updateStatus(for: vmID, status: "Error")
                    store.lastStartError = message
                }
            }
        }

        if let pid = runningPID {
            session?.reconnectToRunningHelper(pid: pid)
        } else {
            session?.recoveryBoot = recovery
            session?.skipHelperCopy = skipHelperCopy
            session?.startIfNeeded()
        }
    }

}

// Minimal runtime controller for a single VM bundle.
// Uses WindowlessVMSession so SwiftUI can manage the window.
final class App2VMRunSession: NSObject, ObservableObject, @unchecked Sendable {
    enum State {
        case idle
        case starting
        case running
        case suspending
        case stopping
        case stopped
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusText: String = ""
    @Published private(set) var virtualMachine: VZVirtualMachine?

    /// When true, the helper app will boot into macOS Recovery mode.
    var recoveryBoot: Bool = false

    /// When true, skip copying the helper app/GhostTools into the VM bundle.
    /// Used when launching a legacy VM that declined ASIF migration.
    var skipHelperCopy: Bool = false

    /// The VM's dispatch queue, needed for vsock operations
    var vmQueue: DispatchQueue? { windowlessSession?.vmQueue }

    // Clipboard sync
    @Published var clipboardSyncMode: ClipboardSyncMode = .disabled
    private var clipboardSyncService: ClipboardSyncService?
    private var ghostClient: GhostClient?

    // Port forwarding
    @Published private(set) var portForwardService: PortForwardService?
    private var portForwardingStarted = false


    // Helper app that runs the VM
    private var helperBundleManager = VMHelperBundleManager()
    private var helperProcess: NSRunningApplication?

    /// Activate the helper process (bring its window to front).
    func activateHelper() {
        helperProcess?.activate()
    }

    let bundleURL: URL

    /// VM name derived from bundle filename
    private var vmName: String {
        let candidate = bundleURL.deletingPathExtension().lastPathComponent
        return candidate.isEmpty ? bundleURL.lastPathComponent : candidate
    }

    // Callbacks so the SwiftUI layer can reflect status into the list.
    var onStateChange: ((State) -> Void)?

    private var windowlessSession: WindowlessVMSession?
    private let controller = VMController()

    init(bundleURL: URL) {
        self.bundleURL = bundleURL.standardizedFileURL
        super.init()

        // Load persisted clipboard sync mode for this VM
        let key = "clipboardSyncMode_\(self.bundleURL.path.stableHash)"
        if let storedMode = UserDefaults.standard.string(forKey: key),
           let mode = ClipboardSyncMode(rawValue: storedMode) {
            self.clipboardSyncMode = mode
        }

    }

    /// Update clipboard sync mode and persist the setting
    func setClipboardSyncMode(_ mode: ClipboardSyncMode) {
        clipboardSyncMode = mode

        // Persist the setting per-VM
        let key = "clipboardSyncMode_\(bundleURL.path.stableHash)"
        UserDefaults.standard.set(mode.rawValue, forKey: key)

        // Update running service if active, or start it if enabling
        if let service = clipboardSyncService {
            Task { @MainActor in
                service.setSyncMode(mode)
            }
        } else if mode != .disabled {
            // Service doesn't exist yet but we're enabling - start it
            startClipboardSync()
        }
    }

    /// Start clipboard sync service when VM is running
    private func startClipboardSync() {
        guard clipboardSyncService == nil else { return }  // Already started
        guard let vm = virtualMachine else { return }
        guard let session = windowlessSession else { return }
        guard clipboardSyncMode != .disabled else { return }

        Task { @MainActor in
            let client = GhostClient(virtualMachine: vm, vmQueue: session.vmQueue)
            self.ghostClient = client

            let service = ClipboardSyncService(bundlePath: bundleURL.path)
            service.setSyncMode(clipboardSyncMode)
            service.configure(client: client)
            self.clipboardSyncService = service
        }
    }

    /// Stop clipboard sync service
    private func stopClipboardSync() {
        Task { @MainActor in
            clipboardSyncService?.stop()
            clipboardSyncService = nil
            ghostClient = nil
        }
    }

    /// Start port forwarding service when VM is running
    private func startPortForwarding() {
        guard !portForwardingStarted else { return }  // Already started or starting
        guard let vm = virtualMachine else { return }
        guard let session = windowlessSession else { return }

        portForwardingStarted = true  // Set flag synchronously before async Task

        Task { @MainActor in
            let service = PortForwardService(vm: vm, queue: session.vmQueue)
            self.portForwardService = service

            // Load port forwards from VM config
            let forwards = loadPortForwards()
            if !forwards.isEmpty {
                service.start(forwards: forwards)
            }
        }
    }

    /// Stop port forwarding service
    private func stopPortForwarding() {
        portForwardingStarted = false  // Reset flag synchronously
        Task { @MainActor in
            portForwardService?.stop()
            portForwardService = nil
        }
    }

    /// Load port forward configuration from VM bundle
    private func loadPortForwards() -> [PortForwardConfig] {
        do {
            let layout = VMFileLayout(bundleURL: bundleURL)
            let store = VMConfigStore(layout: layout)
            let config = try store.load()
            return config.portForwards
        } catch {
            print("[App2VMRunSession] Failed to load port forwards: \(error)")
            return []
        }
    }

    /// Add a port forward at runtime and persist to config
    @MainActor
    func addPortForward(hostPort: UInt16, guestPort: UInt16) throws {
        guard let service = portForwardService else {
            throw PortForwardError.serviceNotRunning
        }

        let config = PortForwardConfig(hostPort: hostPort, guestPort: guestPort, enabled: true)
        try service.addForward(config)

        // Persist to config.json
        persistPortForwards()
    }

    /// Remove a port forward at runtime and persist to config
    @MainActor
    func removePortForward(hostPort: UInt16) {
        guard let service = portForwardService else { return }
        service.removeForward(hostPort: hostPort)

        // Persist to config.json
        persistPortForwards()
    }

    /// Save current port forwards to config.json
    @MainActor
    private func persistPortForwards() {
        guard let service = portForwardService else { return }
        let activeForwards = service.activeForwards

        DispatchQueue.global(qos: .userInitiated).async { [bundleURL] in
            do {
                let layout = VMFileLayout(bundleURL: bundleURL)
                let store = VMConfigStore(layout: layout)
                var config = try store.load()
                config.portForwards = activeForwards
                try store.save(config)
                print("[App2VMRunSession] Persisted \(activeForwards.count) port forward(s)")
            } catch {
                print("[App2VMRunSession] Failed to persist port forwards: \(error)")
            }
        }
    }

    enum PortForwardError: LocalizedError {
        case serviceNotRunning

        var errorDescription: String? {
            switch self {
            case .serviceNotRunning:
                return "Port forwarding service is not running"
            }
        }
    }

    // MARK: - Helper App (VM Host with Separate Dock Icon)

    private var helperStateObserver: NSObjectProtocol?

    /// Launch the helper app that hosts and runs this VM
    private func launchHelperApp() {
        guard helperProcess == nil else { return }

        let helperAppURL: URL
        if skipHelperCopy {
            // Legacy VM — use existing helper in the VM bundle
            guard let existingURL = helperBundleManager.helperAppURL(vmBundleURL: bundleURL) else {
                print("[App2VMRunSession] No existing helper found in VM bundle")
                transition(to: .failed("Helper app not found in VM bundle"))
                return
            }
            helperAppURL = existingURL
        } else {
            // Normal path — copy latest helper into VM bundle
            guard let sourceHelperURL = VMHelperBundleManager.findHelperInMainBundle() else {
                print("[App2VMRunSession] GhostVMHelper.app not found in main bundle")
                transition(to: .failed("Helper app not found"))
                return
            }
            do {
                helperAppURL = try helperBundleManager.copyHelperApp(
                    vmBundleURL: bundleURL,
                    sourceHelperAppURL: sourceHelperURL
                )
            } catch {
                print("[App2VMRunSession] Failed to copy helper: \(error)")
                transition(to: .failed("Failed to copy helper: \(error.localizedDescription)"))
                return
            }
        }

        // Register for state change notifications from helper
        // IMPORTANT: Use standardized path to match helper's path normalization
        let standardizedPath = bundleURL.standardizedFileURL.path
        let bundlePathHash = standardizedPath.stableHash
        print("[App2VMRunSession] Registering for helper notifications: com.ghostvm.helper.state.\(bundlePathHash)")
        print("[App2VMRunSession] Bundle path (standardized): \(standardizedPath)")
        helperStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.ghostvm.helper.state.\(bundlePathHash)"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleHelperStateChange(notification)
        }

        // Launch the helper app with VM bundle path (use standardized path)
        let configuration = NSWorkspace.OpenConfiguration()
        var args = ["--vm-bundle", standardizedPath]
        if recoveryBoot {
            args.append("--recovery")
        }
        configuration.arguments = args
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: helperAppURL,
            configuration: configuration
        ) { [weak self] app, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("[App2VMRunSession] Failed to launch helper: \(error)")
                    self?.transition(to: .failed(error.localizedDescription))
                } else if let app = app {
                    self?.helperProcess = app
                    print("[App2VMRunSession] Helper launched for '\(self?.vmName ?? "unknown")' (PID \(app.processIdentifier))")
                }
            }
        }
    }

    /// Handle state change notification from helper
    private func handleHelperStateChange(_ notification: Notification) {
        guard let stateString = notification.userInfo?["state"] as? String else {
            print("[App2VMRunSession] Received notification but no state in userInfo")
            return
        }

        print("[App2VMRunSession] Helper state changed to: \(stateString) for '\(vmName)'")

        switch stateString {
        case "starting":
            transition(to: .starting, message: "Starting…")
        case "running":
            App2VMSessionRegistry.shared.register(self)
            transition(to: .running, message: "Running")
        case "suspending":
            transition(to: .suspending, message: "Suspending…")
        case "stopped":
            cleanupHelper()
            transition(to: .stopped, message: "Stopped")
        case "failed":
            let errorMessage = notification.userInfo?["error"] as? String ?? "VM error"
            cleanupHelper()
            transition(to: .failed(errorMessage))
        default:
            break
        }
    }

    /// Send stop command to helper
    private func sendStopToHelper() {
        let bundlePathHash = bundleURL.standardizedFileURL.path.stableHash
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.ghostvm.helper.stop.\(bundlePathHash)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Send suspend command to helper
    private func sendSuspendToHelper() {
        let bundlePathHash = bundleURL.standardizedFileURL.path.stableHash
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.ghostvm.helper.suspend.\(bundlePathHash)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Send terminate (force stop) command to helper
    private func sendTerminateToHelper() {
        let bundlePathHash = bundleURL.standardizedFileURL.path.stableHash
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.ghostvm.helper.terminate.\(bundlePathHash)"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Clean up helper tracking state
    private func cleanupHelper() {
        if let observer = helperStateObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            helperStateObserver = nil
        }
        helperProcess = nil
        App2VMSessionRegistry.shared.unregister(self)
    }

    /// Reconnect to an already-running helper process (e.g. after main app relaunch).
    /// Registers for state notifications and finds the running process by PID.
    func reconnectToRunningHelper(pid: pid_t) {
        guard case .idle = state else { return }  // Only reconnect from idle state

        // Find the running application by PID
        let runningApp = NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier == pid
        }
        guard let app = runningApp, !app.isTerminated else {
            print("[App2VMRunSession] Helper process \(pid) not found or already terminated for '\(vmName)'")
            return
        }

        // Register for state change notifications from helper
        let standardizedPath = bundleURL.standardizedFileURL.path
        let bundlePathHash = standardizedPath.stableHash
        print("[App2VMRunSession] Reconnecting to helper (PID \(pid)) for '\(vmName)'")
        helperStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.ghostvm.helper.state.\(bundlePathHash)"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleHelperStateChange(notification)
        }

        helperProcess = app
        App2VMSessionRegistry.shared.register(self)
        transition(to: .running, message: "Running")
    }

    func startIfNeeded() {
        switch state {
        case .running, .starting:
            return
        default:
            break
        }
        start()
    }

    func start() {
        if let forcedError = Self.uiTestingForcedStartErrorMessage() {
            transition(to: .failed(forcedError))
            return
        }

        guard VZVirtualMachine.isSupported else {
            transition(to: .failed("Virtualization is not supported on this Mac."))
            return
        }

        transition(to: .starting, message: "Starting…")

        // Launch the helper app which hosts and runs the VM
        launchHelperApp()
    }

    private static func uiTestingForcedStartErrorMessage() -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing") else { return nil }
        guard let index = args.firstIndex(of: "--ui-testing-force-start-error"),
              args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    // Legacy in-process start method (kept for reference, not used)
    private func startInProcess() {
        do {
            let session = try controller.makeWindowlessSession(bundleURL: bundleURL, runtimeSharedFolder: nil)
            self.windowlessSession = session
            self.virtualMachine = session.virtualMachine

            session.stateDidChange = { [weak self] sessionState in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    switch sessionState {
                    case .initialized:
                        break
                    case .starting:
                        self.transition(to: .starting, message: "Starting…")
                    case .running:
                        self.transition(to: .running, message: "Running")
                    case .stopping:
                        self.transition(to: .stopping, message: "Stopping…")
                    case .suspending:
                        self.transition(to: .suspending, message: "Suspending…")
                    case .stopped:
                        self.windowlessSession = nil
                        self.virtualMachine = nil
                        self.transition(to: .stopped, message: "Stopped")
                    }
                }
            }

            session.terminationHandler = { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.windowlessSession = nil
                    self.virtualMachine = nil
                    switch result {
                    case .success:
                        self.transition(to: .stopped, message: "Stopped")
                    case .failure(let error):
                        print("[App2VMRunSession] termination error: \(error)")
                        self.transition(to: .failed(error.localizedDescription))
                    }
                }
            }

            // Use resume if VM was suspended, otherwise start fresh
            let startOrResume: (@escaping (Result<Void, Error>) -> Void) -> Void = session.wasSuspended
                ? session.resume
                : session.start

            startOrResume { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    App2VMSessionRegistry.shared.register(self)
                    self.transition(to: .running, message: "Running")
                case .failure(let error):
                    print("[App2VMRunSession] start/resume callback error: \(error)")
                    self.windowlessSession = nil
                    self.virtualMachine = nil
                    self.transition(to: .failed(error.localizedDescription))
                }
            }
        } catch {
            print("[App2VMRunSession] makeWindowlessSession/start error: \(error)")
            self.windowlessSession = nil
            self.virtualMachine = nil
            transition(to: .failed(error.localizedDescription))
        }
    }

    func stopIfNeeded() {
        switch state {
        case .running, .starting:
            stop()
        default:
            break
        }
    }

    func suspendIfNeeded() {
        switch state {
        case .running:
            suspend()
        default:
            break
        }
    }

    func stop() {
        guard helperProcess != nil else {
            transition(to: .stopped, message: "Stopped")
            return
        }

        // Fire-and-forget: just send the power button event to the helper.
        // Don't change local state — the guest may show a confirmation
        // dialog and the user might cancel.  The helper will notify us
        // via DistributedNotificationCenter when the VM actually stops.
        sendStopToHelper()
    }

    func terminate() {
        guard helperProcess != nil else {
            transition(to: .stopped, message: "Stopped")
            return
        }

        transition(to: .stopping, message: "Terminating…")

        // Send terminate (force stop) command to helper
        sendTerminateToHelper()

        // Force kill after timeout if helper doesn't respond
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if let process = self?.helperProcess, !process.isTerminated {
                process.terminate()
            }
        }
    }

    func suspend() {
        guard helperProcess != nil else { return }
        guard case .running = state else { return }

        transition(to: .suspending, message: "Suspending…")

        // Send suspend command to helper
        sendSuspendToHelper()
    }

    private func transition(to newState: State, message: String? = nil) {
        state = newState
        if let message = message {
            statusText = message
        } else {
            switch newState {
            case .idle:
                statusText = ""
            case .starting:
                statusText = "Starting…"
            case .running:
                statusText = "Running"
            case .suspending:
                statusText = "Suspending…"
            case .stopping:
                statusText = "Stopping…"
            case .stopped:
                statusText = "Stopped"
            case .failed(let text):
                statusText = "Error: \(text)"
            }
        }

        // Note: Services (clipboard, port forwarding, log polling) now run in the helper app

        onStateChange?(newState)
    }
}
