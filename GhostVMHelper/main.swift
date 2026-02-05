import AppKit
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

final class HelperAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {

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
    private var vmView: VZVirtualMachineView?
    private var virtualMachine: VZVirtualMachine?
    private var vmQueue: DispatchQueue?
    private var layout: VMFileLayout?

    private let controller = VMController()
    private let center = DistributedNotificationCenter.default()
    private let fileManager = FileManager.default

    private var ownsLock = false

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

        NSLog("GhostVMHelper: Starting VM '\(vmName)' from \(vmBundleURL.path)")

        // Set activation policy to show in Dock
        NSApp.setActivationPolicy(.regular)

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

    // MARK: - Notifications

    private func registerNotifications() {
        let bundlePathHash = vmBundleURL.path.hashValue

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
        let bundlePathHash = vmBundleURL.path.hashValue
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
            let vmConfig = try builder.makeConfiguration(headless: false, connectSerialToStandardIO: false, runtimeSharedFolder: nil)

            // Create VM
            vmQueue = DispatchQueue(label: "ghostvm.helper.\(vmName)")
            virtualMachine = VZVirtualMachine(configuration: vmConfig, queue: vmQueue!)
            virtualMachine!.delegate = self

            // Create window and view
            createWindow()

            // Write lock file
            try writeVMLockOwner(.embedded(ProcessInfo.processInfo.processIdentifier), to: layout!.pidFileURL)
            ownsLock = true

            // Start or resume VM
            let wasSuspended = config.isSuspended && fileManager.fileExists(atPath: layout!.suspendStateURL.path)

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

            // Show window
            window?.center()
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            NSLog("GhostVMHelper: VM '\(vmName)' is now running")

        case .failure(let error):
            handleStartFailure(error)
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
        if ownsLock, let layout = layout {
            removeVMLock(at: layout.pidFileURL)
            ownsLock = false
        }
        vmView?.virtualMachine = nil
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

        let vmView = VZVirtualMachineView()
        if #available(macOS 14.0, *) {
            vmView.automaticallyReconfiguresDisplay = true
        }
        vmView.autoresizingMask = [.width, .height]
        vmView.virtualMachine = virtualMachine
        window.contentView = vmView

        self.window = window
        self.vmView = vmView
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

let delegate = HelperAppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
