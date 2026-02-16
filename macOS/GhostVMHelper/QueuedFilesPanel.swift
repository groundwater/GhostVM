import AppKit

/// Delegate protocol for queued files panel actions
protocol QueuedFilesPanelDelegate: AnyObject {
    func queuedFilesPanelDidAllow(_ panel: QueuedFilesPanel)
    func queuedFilesPanelDidDeny(_ panel: QueuedFilesPanel)
}

/// NSPopover-based panel showing queued guest files with Save/Decline actions
final class QueuedFilesPanel: NSObject, NSPopoverDelegate {

    weak var delegate: QueuedFilesPanelDelegate?
    var onClose: (() -> Void)?

    private var popover: NSPopover?
    private var fileNames: [String] = []
    private var contentViewController: QueuedFilesContentViewController?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self

        let vc = QueuedFilesContentViewController()
        vc.delegate = self
        vc.setFileNames(fileNames)
        contentViewController = vc

        popover.contentViewController = vc
        popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        self.popover = popover
    }

    func close() {
        popover?.close()
    }

    func setFileNames(_ names: [String]) {
        fileNames = names
        contentViewController?.setFileNames(names)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        contentViewController = nil
        onClose?()
    }
}

extension QueuedFilesPanel: QueuedFilesContentViewControllerDelegate {
    func contentViewControllerDidAllow(_ vc: QueuedFilesContentViewController) {
        NSLog("QueuedFilesPanel: Save clicked, delegate=%@", delegate != nil ? "present" : "NIL")
        delegate?.queuedFilesPanelDidAllow(self)
    }

    func contentViewControllerDidDeny(_ vc: QueuedFilesContentViewController) {
        delegate?.queuedFilesPanelDidDeny(self)
    }
}

// MARK: - Content View Controller

protocol QueuedFilesContentViewControllerDelegate: AnyObject {
    func contentViewControllerDidAllow(_ vc: QueuedFilesContentViewController)
    func contentViewControllerDidDeny(_ vc: QueuedFilesContentViewController)
}

final class QueuedFilesContentViewController: NSViewController {

    weak var delegate: QueuedFilesContentViewControllerDelegate?

    private var fileNames: [String] = []
    private var fileListStack: NSStackView!
    private var subtitleLabel: NSTextField!
    private var scrollView: NSScrollView!
    private var scrollHeightConstraint: NSLayoutConstraint?

    override func loadView() {
        let container = NSView()

        // Title
        let titleLabel = NSTextField(labelWithString: "Files from Guest")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Subtitle
        subtitleLabel = NSTextField(labelWithString: subtitleText())
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.setAccessibilityIdentifier("queuedFiles.subtitle")
        container.addSubview(subtitleLabel)

        // File list in scroll view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("queuedFiles.scrollView")

        fileListStack = NSStackView()
        fileListStack.orientation = .vertical
        fileListStack.alignment = .leading
        fileListStack.spacing = 4
        fileListStack.translatesAutoresizingMaskIntoConstraints = false

        // Wrap stack in a flipped view so the scroll view shows content from the top
        let flippedContainer = FlippedView()
        flippedContainer.translatesAutoresizingMaskIntoConstraints = false
        flippedContainer.addSubview(fileListStack)
        NSLayoutConstraint.activate([
            fileListStack.topAnchor.constraint(equalTo: flippedContainer.topAnchor),
            fileListStack.leadingAnchor.constraint(equalTo: flippedContainer.leadingAnchor),
            fileListStack.trailingAnchor.constraint(equalTo: flippedContainer.trailingAnchor),
            fileListStack.bottomAnchor.constraint(equalTo: flippedContainer.bottomAnchor),
        ])

        let clipView = NSClipView()
        clipView.documentView = flippedContainer
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        flippedContainer.widthAnchor.constraint(equalTo: clipView.widthAnchor).isActive = true

        container.addSubview(scrollView)

        // Info label
        let infoLabel = NSTextField(labelWithString: "Saved to ~/Downloads")
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(infoLabel)

        // Buttons
        let declineButton = NSButton(title: "Decline", target: self, action: #selector(denyClicked))
        declineButton.bezelStyle = .rounded
        declineButton.translatesAutoresizingMaskIntoConstraints = false
        declineButton.setAccessibilityIdentifier("queuedFiles.declineButton")
        container.addSubview(declineButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(allowClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.setAccessibilityIdentifier("queuedFiles.saveButton")
        container.addSubview(saveButton)

        // Layout
        let padding: CGFloat = 16

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 216),

            infoLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            infoLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            saveButton.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            declineButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            declineButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),

            container.widthAnchor.constraint(equalToConstant: 300),
        ])

        let initialHeight = scrollViewHeight(for: fileNames.count)
        let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: initialHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
        scrollHeightConstraint = heightConstraint

        rebuildFileList()
        self.view = container
    }

    func setFileNames(_ names: [String]) {
        fileNames = names
        subtitleLabel?.stringValue = subtitleText()
        rebuildFileList()
    }

    private func subtitleText() -> String {
        let count = fileNames.count
        if count == 1 { return "1 file ready to download" }
        return "\(count) files ready to download"
    }

    private let rowHeight: CGFloat = 18
    private let maxVisibleRows = 10

    private func scrollViewHeight(for fileCount: Int) -> CGFloat {
        let visibleRows = min(fileCount, maxVisibleRows)
        let contentHeight = CGFloat(visibleRows) * rowHeight + CGFloat(max(visibleRows - 1, 0)) * fileListStack.spacing
        return max(contentHeight, rowHeight)
    }

    private func rebuildFileList() {
        guard let fileListStack = fileListStack else { return }

        for view in fileListStack.arrangedSubviews {
            fileListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for (index, name) in fileNames.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            row.setAccessibilityIdentifier("queuedFiles.row.\(index)")

            if let docImage = NSImage(systemSymbolName: "doc", accessibilityDescription: "File") {
                let icon = NSImageView(image: docImage)
                icon.contentTintColor = .secondaryLabelColor
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
                row.addArrangedSubview(icon)
            }

            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.setAccessibilityIdentifier("queuedFiles.row.\(index)")
            row.addArrangedSubview(label)

            fileListStack.addArrangedSubview(row)
        }

        scrollHeightConstraint?.constant = scrollViewHeight(for: fileNames.count)
    }

    @objc private func allowClicked() {
        delegate?.contentViewControllerDidAllow(self)
    }

    @objc private func denyClicked() {
        delegate?.contentViewControllerDidDeny(self)
    }
}

/// NSView subclass that returns `true` for `isFlipped`, ensuring the scroll view
/// anchors content at the top rather than the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
