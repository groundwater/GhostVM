import AppKit
import Virtualization

/// Represents a file with its relative path for transfer
public struct FileWithRelativePath {
    public let url: URL
    public let relativePath: String
}

/// Delegate protocol for file transfer events
protocol FileTransferDelegate: AnyObject {
    func fileTransfer(didReceiveFiles files: [FileWithRelativePath])
}

/// Custom VZVirtualMachineView subclass that supports file drag-and-drop
final class FocusableVMView: VZVirtualMachineView {
    override var acceptsFirstResponder: Bool { true }

    /// Delegate for handling file drops
    weak var fileTransferDelegate: FileTransferDelegate?

    /// Drop zone overlay view
    private lazy var dropZoneOverlay: DropZoneOverlayView = {
        let overlay = DropZoneOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        return overlay
    }()

    private var isDragging = false

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
        window?.makeFirstResponder(self)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFileURLs(in: sender) else { return [] }
        isDragging = true
        showDropZone()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isDragging && dropZoneOverlay.isHidden {
            showDropZone()
        }
        guard hasFileURLs(in: sender) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragging = false
        hideDropZone()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return hasFileURLs(in: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragging = false
        hideDropZone()

        guard let files = extractFilesWithPaths(from: sender), !files.isEmpty else {
            return false
        }

        NSLog("GhostVMHelper: Dropping \(files.count) file(s)")
        fileTransferDelegate?.fileTransfer(didReceiveFiles: files)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        isDragging = false
        hideDropZone()
    }

    private func showDropZone() {
        dropZoneOverlay.isHidden = false
        dropZoneOverlay.alphaValue = 1
    }

    private func hideDropZone() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            dropZoneOverlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.dropZoneOverlay.isHidden = true
        }
    }

    // MARK: - Private Helpers

    private func hasFileURLs(in draggingInfo: NSDraggingInfo) -> Bool {
        let pasteboard = draggingInfo.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func extractFilesWithPaths(from draggingInfo: NSDraggingInfo) -> [FileWithRelativePath]? {
        let pasteboard = draggingInfo.draggingPasteboard
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return nil
        }

        var result: [FileWithRelativePath] = []
        let fm = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                // For directories, preserve the folder name as the base of relative paths
                let baseFolderName = url.lastPathComponent
                let baseURL = url

                // Enumerate all files in directory recursively
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator {
                        var isFile: ObjCBool = false
                        if fm.fileExists(atPath: fileURL.path, isDirectory: &isFile) && !isFile.boolValue {
                            // Compute relative path: folder/subfolder/file.txt
                            let relativePath = baseFolderName + "/" + fileURL.path.dropFirst(baseURL.path.count + 1)
                            result.append(FileWithRelativePath(url: fileURL, relativePath: String(relativePath)))
                        }
                    }
                }
            } else {
                // Single file - relative path is just the filename
                result.append(FileWithRelativePath(url: url, relativePath: url.lastPathComponent))
            }
        }

        return result.isEmpty ? nil : result
    }
}

// MARK: - Drop Zone Overlay

/// Visual overlay shown when dragging files over the VM window
final class DropZoneOverlayView: NSView {
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

// MARK: - File Transfer Progress View

/// Progress bar view shown during file transfers
final class FileTransferProgressView: NSView {
    private let progressBar: NSProgressIndicator
    private let statusLabel: NSTextField
    private let cancelButton: NSButton

    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        progressBar = NSProgressIndicator()
        statusLabel = NSTextField(labelWithString: "")
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        progressBar = NSProgressIndicator()
        statusLabel = NSTextField(labelWithString: "")
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.cornerRadius = 8

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTransfer)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(progressBar)
        addSubview(statusLabel)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            progressBar.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            progressBar.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 4),

            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func setProgress(_ progress: Double, status: String) {
        progressBar.doubleValue = progress
        statusLabel.stringValue = status
    }

    func setIndeterminate(_ indeterminate: Bool) {
        progressBar.isIndeterminate = indeterminate
        if indeterminate {
            progressBar.startAnimation(nil)
        } else {
            progressBar.stopAnimation(nil)
        }
    }

    @objc private func cancelTransfer() {
        onCancel?()
    }
}
