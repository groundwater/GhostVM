import Foundation
import AppKit
import Virtualization

/// Session for running a VM inside the app (in-process).
public final class EmbeddedVMSession: NSObject, NSWindowDelegate, VZVirtualMachineDelegate {
    public enum State {
        case initialized
        case starting
        case running
        case stopping
        case stopped
        case suspending
    }

    public enum SpecialKey {
        case escape
        case `return`
        case tab
        case space
    }

    public let name: String
    public let bundlePath: String
    public let window: NSWindow
    public var stateDidChange: ((State) -> Void)?
    public var statusChanged: ((String) -> Void)?
    public var terminationHandler: ((Result<Void, Error>) -> Void)?

    public var isRunning: Bool { state == .running }
    public var isStopping: Bool { state == .stopping }

    private let layout: VMFileLayout
    private let virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue
    private let vmView: VZVirtualMachineView
    private var state: State = .initialized {
        didSet {
            if state != oldValue {
                stateDidChange?(state)
            }
        }
    }
    private var ownsLock = false
    private var didTerminate = false
    private var stopContinuations: [(Result<Void, Error>) -> Void] = []

    public init(name: String, bundleURL: URL, layout: VMFileLayout, storedConfig: VMStoredConfig, runtimeSharedFolder: RuntimeSharedFolderOverride?) throws {
        self.name = name
        self.bundlePath = bundleURL.path
        self.layout = layout
        let builder = VMConfigurationBuilder(layout: layout, storedConfig: storedConfig)
        let configuration = try builder.makeConfiguration(headless: false, connectSerialToStandardIO: false, runtimeSharedFolder: runtimeSharedFolder)
        self.vmQueue = DispatchQueue(label: "vmctl.embedded.\(name)")
        self.virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
        let ui = EmbeddedVMSession.makeWindowAndView(name: name)
        self.window = ui.window
        self.vmView = ui.view
        super.init()

        self.virtualMachine.delegate = self
        configureUIBindings()
    }

    public func start(completion: @escaping (Result<Void, Error>) -> Void) {
        guard state == .initialized || state == .stopped else {
            completion(.failure(VMError.message("VM '\(name)' is already starting or running.")))
            return
        }

        state = .starting
        do {
            try writeVMLockOwner(.embedded(ProcessInfo.processInfo.processIdentifier), to: layout.pidFileURL)
            ownsLock = true
        } catch {
            state = .stopped
            completion(.failure(error))
            return
        }

        vmQueue.async {
            self.virtualMachine.start { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.state = .running
                        self.window.center()
                        self.window.makeKeyAndOrderFront(nil)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        self.statusChanged?("VM \(self.name) started.")
                        completion(.success(()))
                    case .failure(let error):
                        self.state = .stopped
                        if self.ownsLock {
                            removeVMLock(at: self.layout.pidFileURL)
                            self.ownsLock = false
                        }
                        self.statusChanged?("Failed to start \(self.name): \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    public func requestStop(force: Bool = false, completion: ((Result<Void, Error>) -> Void)? = nil) {
        if state == .stopped {
            completion?(.success(()))
            return
        }

        if let completion = completion {
            stopContinuations.append(completion)
        }

        let alreadyStopping = state == .stopping
        if !alreadyStopping {
            state = .stopping
            statusChanged?("Stopping \(name)…")
        }

        if force {
            issueForceStop()
        } else if !alreadyStopping {
            issueGracefulStop()
        }
    }

    /// Suspends the VM by pausing execution and saving state to disk.
    public func suspend(completion: @escaping (Result<Void, Error>) -> Void) {
        guard state == .running else {
            completion(.failure(VMError.message("VM '\(name)' is not running.")))
            return
        }

        state = .suspending
        statusChanged?("Suspending \(name)…")

        vmQueue.async {
            self.virtualMachine.pause { pauseResult in
                switch pauseResult {
                case .success:
                    self.virtualMachine.saveMachineStateTo(url: self.layout.suspendStateURL) { saveError in
                        DispatchQueue.main.async {
                            if let error = saveError {
                                self.statusChanged?("Failed to save VM state: \(error.localizedDescription)")
                                // Resume the VM since we failed to save
                                self.vmQueue.async {
                                    self.virtualMachine.resume { _ in
                                        DispatchQueue.main.async {
                                            self.state = .running
                                            completion(.failure(error))
                                        }
                                    }
                                }
                                return
                            }
                            // Update config to mark as suspended
                            let store = VMConfigStore(layout: self.layout)
                            if var config = try? store.load() {
                                config.isSuspended = true
                                config.modifiedAt = Date()
                                try? store.save(config)
                            }
                            self.statusChanged?("VM '\(self.name)' suspended.")
                            self.handleSuspendCompletion()
                            completion(.success(()))
                        }
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.state = .running
                        self.statusChanged?("Failed to pause VM: \(error.localizedDescription)")
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    private func handleSuspendCompletion() {
        if ownsLock {
            removeVMLock(at: layout.pidFileURL)
            ownsLock = false
        }

        state = .stopped
        vmView.virtualMachine = nil
        if window.isVisible {
            window.orderOut(nil)
        }

        terminationHandler?(.success(()))
    }

    public func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func flashDisplay() {
        DispatchQueue.main.async {
            guard let contentView = self.window.contentView else { return }
            let overlay = NSView(frame: contentView.bounds)
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.white.cgColor
            overlay.alphaValue = 0
            overlay.autoresizingMask = [.width, .height]
            contentView.addSubview(overlay)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                overlay.animator().alphaValue = 1
            } completionHandler: {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    overlay.animator().alphaValue = 0
                } completionHandler: {
                    overlay.removeFromSuperview()
                }
            }
        }
    }

    @available(macOS 13.0, *)
    public func captureScreenshot(completion: @escaping (Result<CGImage, Error>) -> Void) {
        DispatchQueue.main.async {
            guard let contentView = self.window.contentView else {
                completion(.failure(VMError.message("No content view available for screenshot.")))
                return
            }
            let bounds = contentView.bounds
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                completion(.failure(VMError.message("Unable to prepare bitmap for screenshot.")))
                return
            }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            if let cgImage = bitmap.cgImage {
                completion(.success(cgImage))
            } else {
                completion(.failure(VMError.message("Failed to capture screenshot image.")))
            }
        }
    }

    public func sendSpecialKey(_ key: SpecialKey) {
        DispatchQueue.main.async {
            guard let window = self.window as NSWindow? else { return }
            window.makeFirstResponder(self.vmView)

            self.sendSimpleKey(key, in: window)
        }
    }

    private func sendSimpleKey(_ key: SpecialKey, in window: NSWindow) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let modifierFlags: NSEvent.ModifierFlags = []
        let characters: String
        let charactersIgnoringModifiers: String
        let keyCode: UInt16

        switch key {
        case .escape:
            characters = String(UnicodeScalar(0x1b)!)
            charactersIgnoringModifiers = characters
            keyCode = 53
        case .return:
            characters = "\r"
            charactersIgnoringModifiers = characters
            keyCode = 36
        case .tab:
            characters = "\t"
            charactersIgnoringModifiers = characters
            keyCode = 48
        case .space:
            characters = " "
            charactersIgnoringModifiers = characters
            keyCode = 49
        }

        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ), let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            return
        }

        vmView.keyDown(with: keyDown)
        vmView.keyUp(with: keyUp)
    }

    // MARK: - NSWindowDelegate

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch state {
        case .stopped:
            return true
        default:
            requestStop()
            return false
        }
    }

    public func windowWillClose(_ notification: Notification) {
        vmView.virtualMachine = nil
    }

    // MARK: - VZVirtualMachineDelegate

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async {
            self.handleTermination(result: .success(()))
        }
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.handleTermination(result: .failure(error))
        }
    }

    // MARK: - Helpers

    private static func makeWindowAndView(name: String) -> (window: NSWindow, view: VZVirtualMachineView) {
        let builder = { () -> (NSWindow, VZVirtualMachineView) in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1024, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Virtual Machine – \(name)"

            let vmView = VZVirtualMachineView()
            if #available(macOS 14.0, *) {
                vmView.automaticallyReconfiguresDisplay = true
            }
            vmView.autoresizingMask = [.width, .height]
            window.contentView = vmView
            return (window, vmView)
        }

        if Thread.isMainThread {
            return builder()
        }

        var result: (NSWindow, VZVirtualMachineView)!
        DispatchQueue.main.sync {
            result = builder()
        }
        return result
    }

    private func configureUIBindings() {
        let work = {
            self.window.delegate = self
            self.window.isReleasedWhenClosed = false
            self.vmView.virtualMachine = self.virtualMachine
        }

        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    private func issueGracefulStop() {
        vmQueue.async {
            do {
                try self.virtualMachine.requestStop()
            } catch {
                DispatchQueue.main.async {
                    self.statusChanged?("Failed to request stop: \(error.localizedDescription)")
                    self.issueForceStop()
                }
            }
        }
    }

    private func issueForceStop() {
        vmQueue.async {
            self.virtualMachine.stop { error in
                DispatchQueue.main.async {
                    if let error = error {
                        self.handleTermination(result: .failure(error))
                    } else {
                        self.handleTermination(result: .success(()))
                    }
                }
            }
        }
    }

    private func handleTermination(result: Result<Void, Error>) {
        guard !didTerminate else { return }
        didTerminate = true

        if ownsLock {
            removeVMLock(at: layout.pidFileURL)
            ownsLock = false
        }

        state = .stopped
        vmView.virtualMachine = nil
        if window.isVisible {
            window.orderOut(nil)
        }

        terminationHandler?(result)
        if !stopContinuations.isEmpty {
            stopContinuations.forEach { $0(result) }
            stopContinuations.removeAll()
        }
    }

    deinit {
        if ownsLock {
            removeVMLock(at: layout.pidFileURL)
        }
    }
}
