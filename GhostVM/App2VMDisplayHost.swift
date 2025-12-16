import SwiftUI
import AppKit
import Virtualization
import Combine

// SwiftUI wrapper around VZVirtualMachineView so AppKit stays isolated here.
struct App2VMDisplayHost: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?
    let isLinux: Bool
    let captureSystemKeys: Bool

    init(virtualMachine: VZVirtualMachine?, isLinux: Bool = false, captureSystemKeys: Bool = true) {
        self.virtualMachine = virtualMachine
        self.isLinux = isLinux
        self.captureSystemKeys = captureSystemKeys
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FocusableVMView {
        let view = FocusableVMView()
        view.capturesSystemKeys = captureSystemKeys
        if #available(macOS 14.0, *) {
            // Only enable automatic display reconfiguration for macOS guests.
            // Linux guests with VirtIO graphics use a fixed scanout resolution
            // and don't handle dynamic resolution changes well.
            view.automaticallyReconfiguresDisplay = !isLinux
        }
        view.autoresizingMask = [.width, .height]
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: FocusableVMView, context: Context) {
        nsView.virtualMachine = virtualMachine
        // Make the view first responder when VM is attached
        if virtualMachine != nil {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    class Coordinator: NSObject {
        weak var view: FocusableVMView?
    }
}

// Custom VZVirtualMachineView subclass that properly handles first responder status
// to ensure keyboard and mouse events are received.
class FocusableVMView: VZVirtualMachineView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        // Ensure we become first responder on click
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Become first responder when added to window
        if let window = window {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                window.makeFirstResponder(self)
            }
            // Also observe when window becomes key
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidBecomeKey),
                name: NSWindow.didBecomeKeyNotification,
                object: window
            )
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        // When window becomes key, make sure we're first responder
        window?.makeFirstResponder(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
                        case .running:
                            // Activate the window and bring it to front when VM starts running
                            NSApp.activate(ignoringOtherApps: true)
                            window.makeKeyAndOrderFront(nil)
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
