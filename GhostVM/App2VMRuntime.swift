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

    /// Returns true if there are any active (running) sessions.
    var hasActiveSessions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.contains { session in
            switch session.state {
            case .running, .starting, .stopping, .suspending:
                return true
            default:
                return false
            }
        }
    }

    /// Suspends all running sessions. Calls completion when all are done.
    func suspendAllSessions(completion: @escaping () -> Void) {
        lock.lock()
        let runningSessions = sessions.values.filter { session in
            if case .running = session.state { return true }
            return false
        }
        lock.unlock()

        guard !runningSessions.isEmpty else {
            completion()
            return
        }

        let group = DispatchGroup()
        var observations: [AnyCancellable] = []

        for session in runningSessions {
            group.enter()
            var didLeave = false
            let observation = session.$state.sink { state in
                guard !didLeave else { return }
                switch state {
                case .stopped, .failed, .idle:
                    didLeave = true
                    group.leave()
                default:
                    break
                }
            }
            observations.append(observation)
            session.suspend()
        }

        group.notify(queue: .main) {
            // Cancel observations after completion
            observations.forEach { $0.cancel() }
            completion()
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

    // Clipboard sync
    @Published var clipboardSyncMode: ClipboardSyncMode = .disabled
    private var clipboardSyncService: ClipboardSyncService?
    private var ghostClient: GhostClient?

    let bundleURL: URL

    // Callbacks so the SwiftUI layer can reflect status into the list.
    var onStateChange: ((State) -> Void)?

    private var windowlessSession: WindowlessVMSession?
    private let controller = VMController()

    init(bundleURL: URL) {
        self.bundleURL = bundleURL.standardizedFileURL
        super.init()

        // Load persisted clipboard sync mode for this VM
        let key = "clipboardSyncMode_\(self.bundleURL.path.hashValue)"
        if let storedMode = UserDefaults.standard.string(forKey: key),
           let mode = ClipboardSyncMode(rawValue: storedMode) {
            self.clipboardSyncMode = mode
        }
    }

    /// Update clipboard sync mode and persist the setting
    func setClipboardSyncMode(_ mode: ClipboardSyncMode) {
        clipboardSyncMode = mode

        // Persist the setting per-VM
        let key = "clipboardSyncMode_\(bundleURL.path.hashValue)"
        UserDefaults.standard.set(mode.rawValue, forKey: key)

        // Update running service if active
        if let service = clipboardSyncService {
            Task { @MainActor in
                service.setSyncMode(mode)
            }
        }
    }

    /// Start clipboard sync service when VM is running
    private func startClipboardSync() {
        guard let vm = virtualMachine else { return }
        guard clipboardSyncMode != .disabled else { return }

        Task { @MainActor in
            let client = GhostClient(virtualMachine: vm)
            self.ghostClient = client

            let service = ClipboardSyncService(bundlePath: bundleURL.path)
            service.syncMode = clipboardSyncMode
            self.clipboardSyncService = service

            service.start(client: client)
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
        guard VZVirtualMachine.isSupported else {
            transition(to: .failed("Virtualization is not supported on this Mac."))
            return
        }

        transition(to: .starting, message: "Starting…")

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

    private var stopTimeoutWorkItem: DispatchWorkItem?

    func stop() {
        guard let session = windowlessSession else {
            transition(to: .stopped, message: "Stopped")
            return
        }

        transition(to: .stopping, message: "Stopping…")

        // Set up a 15-second timeout
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Only trigger timeout if still in stopping state
            if case .stopping = self.state {
                self.transition(to: .failed("Stop timed out. Use Terminate to force quit."))
            }
        }
        stopTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeoutWorkItem)

        session.requestStop(force: false) { [weak self] result in
            guard let self = self else { return }
            // Cancel the timeout since we got a response
            self.stopTimeoutWorkItem?.cancel()
            self.stopTimeoutWorkItem = nil

            self.windowlessSession = nil
            self.virtualMachine = nil
            switch result {
            case .success:
                self.transition(to: .stopped, message: "Stopped")
            case .failure(let error):
                self.transition(to: .failed(error.localizedDescription))
            }
        }
    }

    func terminate() {
        // Cancel any pending stop timeout
        stopTimeoutWorkItem?.cancel()
        stopTimeoutWorkItem = nil

        guard let session = windowlessSession else {
            transition(to: .stopped, message: "Stopped")
            return
        }

        transition(to: .stopping, message: "Terminating…")
        session.requestStop(force: true) { [weak self] result in
            guard let self = self else { return }
            self.windowlessSession = nil
            self.virtualMachine = nil
            switch result {
            case .success:
                self.transition(to: .stopped, message: "Terminated")
            case .failure(let error):
                self.transition(to: .failed(error.localizedDescription))
            }
        }
    }

    func suspend() {
        guard let session = windowlessSession else {
            return
        }
        guard case .running = state else {
            return
        }

        transition(to: .suspending, message: "Suspending…")
        session.suspend { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.windowlessSession = nil
                self.virtualMachine = nil
                self.transition(to: .stopped, message: "Suspended")
            case .failure(let error):
                self.transition(to: .running, message: "Running")
                print("[App2VMRunSession] suspend error: \(error)")
            }
        }
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

        // Start/stop clipboard sync based on VM state
        switch newState {
        case .running:
            startClipboardSync()
        case .stopped, .failed, .stopping, .suspending:
            stopClipboardSync()
        default:
            break
        }

        // Unregister from session registry when VM is no longer running
        switch newState {
        case .stopped, .failed:
            App2VMSessionRegistry.shared.unregister(self)
        default:
            break
        }

        onStateChange?(newState)
    }
}
