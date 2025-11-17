import SwiftUI
import AppKit
import Virtualization
import Combine

// SwiftUI wrapper around VZVirtualMachineView so AppKit stays isolated here.
struct App2VMDisplayHost: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = virtualMachine
    }
}

// Invisible SwiftUI host that coordinates the NSWindow lifecycle so that
// closing the window triggers a graceful guest shutdown and the window
// stays open until the VM has actually stopped.
struct App2VMWindowCoordinatorHost: NSViewRepresentable {
    let session: App2VMRunSession

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var session: App2VMRunSession?
        weak var window: NSWindow?
        var cancellable: AnyCancellable?

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            window.delegate = self

            if cancellable == nil, let session = session {
                cancellable = session.$state
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] newState in
                        guard let self, let window = self.window else { return }
                        switch newState {
                        case .stopped, .failed:
                            if window.isVisible {
                                window.close()
                            }
                        default:
                            break
                        }
                    }
            }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard let session = session else {
                return true
            }
            switch session.state {
            case .stopped, .failed:
                return true
            default:
                session.stopIfNeeded()
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.session = session
        return coordinator
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView, let window = nsView.window else { return }
            context.coordinator.attach(to: window)
        }
    }
}

