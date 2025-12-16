import Foundation
import AppKit
import Virtualization

/// A VM session that doesn't create its own window.
/// Use this when the host app (e.g., SwiftUI) manages the window.
public final class WindowlessVMSession: NSObject, VZVirtualMachineDelegate {
    public enum State {
        case initialized
        case starting
        case running
        case stopping
        case stopped
        case suspending
    }

    public let name: String
    public let bundlePath: String
    public var stateDidChange: ((State) -> Void)?
    public var terminationHandler: ((Result<Void, Error>) -> Void)?

    /// The VZVirtualMachine instance. Assign this to a VZVirtualMachineView.
    public var virtualMachine: VZVirtualMachine { _virtualMachine }

    public var isRunning: Bool { state == .running }
    public var isStopping: Bool { state == .stopping }

    private let layout: VMFileLayout
    private let _virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue
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
        self.vmQueue = DispatchQueue(label: "vmctl.windowless.\(name)")
        self._virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)
        super.init()

        self._virtualMachine.delegate = self
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
            self._virtualMachine.start { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self.state = .running
                        completion(.success(()))
                    case .failure(let error):
                        self.state = .stopped
                        if self.ownsLock {
                            removeVMLock(at: self.layout.pidFileURL)
                            self.ownsLock = false
                        }
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

        vmQueue.async {
            self._virtualMachine.pause { pauseResult in
                switch pauseResult {
                case .success:
                    self._virtualMachine.saveMachineStateTo(url: self.layout.suspendStateURL) { saveError in
                        DispatchQueue.main.async {
                            if let error = saveError {
                                // Resume the VM since we failed to save
                                self.vmQueue.async {
                                    self._virtualMachine.resume { _ in
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
                            self.handleSuspendCompletion()
                            completion(.success(()))
                        }
                    }
                case .failure(let error):
                    DispatchQueue.main.async {
                        self.state = .running
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
        terminationHandler?(.success(()))
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

    // MARK: - Private Helpers

    private func issueGracefulStop() {
        vmQueue.async {
            do {
                try self._virtualMachine.requestStop()
            } catch {
                DispatchQueue.main.async {
                    self.issueForceStop()
                }
            }
        }
    }

    private func issueForceStop() {
        vmQueue.async {
            self._virtualMachine.stop { error in
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
