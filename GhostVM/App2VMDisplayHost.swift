import SwiftUI
import AppKit
import Virtualization
import Combine
import UniformTypeIdentifiers

// SwiftUI wrapper around VZVirtualMachineView so AppKit stays isolated here.
struct App2VMDisplayHost: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine?
    let isLinux: Bool
    let captureSystemKeys: Bool
    let fileTransferService: FileTransferService?

    init(virtualMachine: VZVirtualMachine?, isLinux: Bool = false, captureSystemKeys: Bool = true, fileTransferService: FileTransferService? = nil) {
        self.virtualMachine = virtualMachine
        self.isLinux = isLinux
        self.captureSystemKeys = captureSystemKeys
        self.fileTransferService = fileTransferService
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fileTransferService: fileTransferService)
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
        view.coordinator = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: FocusableVMView, context: Context) {
        nsView.virtualMachine = virtualMachine
        nsView.coordinator = context.coordinator
        context.coordinator.fileTransferService = fileTransferService
        // Make the view first responder when VM is attached
        if virtualMachine != nil {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    class Coordinator: NSObject {
        weak var view: FocusableVMView?
        var fileTransferService: FileTransferService?

        init(fileTransferService: FileTransferService?) {
            self.fileTransferService = fileTransferService
        }
    }
}

// Custom VZVirtualMachineView subclass that properly handles first responder status
// to ensure keyboard and mouse events are received, and supports file drag-and-drop.
// Note: VZVirtualMachineView already conforms to NSDraggingDestination via NSView.
class FocusableVMView: VZVirtualMachineView {
    override var acceptsFirstResponder: Bool { true }

    /// Coordinator for handling file drops
    weak var coordinator: App2VMDisplayHost.Coordinator?

    /// Drop zone overlay view
    private lazy var dropZoneOverlay: DropZoneOverlayView = {
        let overlay = DropZoneOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        return overlay
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupDropZone()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupDropZone()
    }

    private func setupDropZone() {
        // Register for file drops
        registerForDraggedTypes([.fileURL])

        // Add drop zone overlay
        addSubview(dropZoneOverlay)
        NSLayoutConstraint.activate([
            dropZoneOverlay.topAnchor.constraint(equalTo: topAnchor),
            dropZoneOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropZoneOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropZoneOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

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

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else {
            return []
        }

        // Show drop zone overlay
        dropZoneOverlay.isHidden = false
        dropZoneOverlay.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            dropZoneOverlay.animator().alphaValue = 1
        }

        // Update service state
        Task { @MainActor in
            coordinator?.fileTransferService?.isDropTargetActive = true
        }

        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else {
            return []
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropZone()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return hasFileURLs(in: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropZone()

        guard let urls = extractFileURLs(from: sender), !urls.isEmpty else {
            return false
        }

        // Send files to guest
        Task { @MainActor in
            coordinator?.fileTransferService?.sendFiles(urls)
        }

        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideDropZone()
    }

    // MARK: - Private Helpers

    private func hasFileURLs(in draggingInfo: NSDraggingInfo) -> Bool {
        let pasteboard = draggingInfo.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func extractFileURLs(from draggingInfo: NSDraggingInfo) -> [URL]? {
        let pasteboard = draggingInfo.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return nil
        }
        // Filter to only include files (not directories)
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    private func hideDropZone() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            dropZoneOverlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.dropZoneOverlay.isHidden = true
        }

        Task { @MainActor in
            coordinator?.fileTransferService?.isDropTargetActive = false
        }
    }
}

// MARK: - Drop Zone Overlay View

/// Visual overlay shown when dragging files over the VM window
class DropZoneOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Semi-transparent overlay
        NSColor.black.withAlphaComponent(0.5).setFill()
        dirtyRect.fill()

        // Draw dashed border
        let borderRect = bounds.insetBy(dx: 20, dy: 20)
        let path = NSBezierPath(roundedRect: borderRect, xRadius: 16, yRadius: 16)
        path.lineWidth = 3

        let dashPattern: [CGFloat] = [8, 4]
        path.setLineDash(dashPattern, count: 2, phase: 0)

        NSColor.white.withAlphaComponent(0.8).setStroke()
        path.stroke()

        // Draw icon and text
        let centerX = bounds.midX
        let centerY = bounds.midY

        // Draw SF Symbol
        if let image = NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: "Drop files") {
            let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .medium)
            let configuredImage = image.withSymbolConfiguration(config)

            let imageSize = NSSize(width: 64, height: 64)
            let imageRect = NSRect(
                x: centerX - imageSize.width / 2,
                y: centerY + 10,
                width: imageSize.width,
                height: imageSize.height
            )

            configuredImage?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 0.9)
        }

        // Draw text
        let text = "Drop files to send to VM"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: centerX - textSize.width / 2,
            y: centerY - 30,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
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
                // Closing window triggers suspend (preserves VM state)
                session.suspendIfNeeded()
                return false
            }
        }

        func windowWillEnterFullScreen(_ notification: Notification) {
            guard let window = window else { return }
            // Hide toolbar in fullscreen for immersive VM experience
            window.toolbar?.isVisible = false
        }

        func windowWillExitFullScreen(_ notification: Notification) {
            guard let window = window else { return }
            window.toolbar?.isVisible = true
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
