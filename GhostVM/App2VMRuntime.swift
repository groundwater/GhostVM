import Foundation
import AppKit
@preconcurrency import Virtualization
import GhostVMKit

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

    let bundleURL: URL

    // Callbacks so the SwiftUI layer can reflect status into the list.
    var onStateChange: ((State) -> Void)?

    private var windowlessSession: WindowlessVMSession?
    private let controller = VMController()

    init(bundleURL: URL) {
        self.bundleURL = bundleURL.standardizedFileURL
        super.init()
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

            session.start { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success:
                    self.transition(to: .running, message: "Running")
                case .failure(let error):
                    print("[App2VMRunSession] start callback error: \(error)")
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

    func stop() {
        guard let session = windowlessSession else {
            transition(to: .stopped, message: "Stopped")
            return
        }

        transition(to: .stopping, message: "Stopping…")
        session.requestStop(force: false) { [weak self] result in
            guard let self = self else { return }
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
        onStateChange?(newState)
    }
}
