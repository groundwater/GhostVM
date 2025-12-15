import Foundation
import AppKit
@preconcurrency import Virtualization
import GhostVMKit

// Minimal runtime controller for a single VM bundle.
// This wraps the framework's EmbeddedVMSession for SwiftUI integration.
final class App2VMRunSession: NSObject, ObservableObject, @unchecked Sendable {
    enum State {
        case idle
        case starting
        case running
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

    private var embeddedSession: EmbeddedVMSession?
    private let controller = VMController()

    init(bundleURL: URL) {
        self.bundleURL = bundleURL.standardizedFileURL
        super.init()
    }

    var window: NSWindow? {
        return embeddedSession?.window
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
            let session = try controller.makeEmbeddedSession(bundleURL: bundleURL, runtimeSharedFolder: nil)
            self.embeddedSession = session

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
                    case .stopped:
                        self.embeddedSession = nil
                        self.transition(to: .stopped, message: "Stopped")
                    }
                }
            }

            session.terminationHandler = { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    self.embeddedSession = nil
                    switch result {
                    case .success:
                        self.transition(to: .stopped, message: "Stopped")
                    case .failure(let error):
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
                    self.embeddedSession = nil
                    self.transition(to: .failed(error.localizedDescription))
                }
            }
        } catch {
            self.embeddedSession = nil
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
        guard let session = embeddedSession else {
            transition(to: .stopped, message: "Stopped")
            return
        }

        transition(to: .stopping, message: "Stopping…")
        session.requestStop(force: false) { [weak self] result in
            guard let self = self else { return }
            self.embeddedSession = nil
            switch result {
            case .success:
                self.transition(to: .stopped, message: "Stopped")
            case .failure(let error):
                self.transition(to: .failed(error.localizedDescription))
            }
        }
    }

    func bringToFront() {
        embeddedSession?.bringToFront()
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
