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
        container.addSubview(subtitleLabel)

        // File list in scroll view
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        fileListStack = NSStackView()
        fileListStack.orientation = .vertical
        fileListStack.alignment = .leading
        fileListStack.spacing = 4
        fileListStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = fileListStack
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        fileListStack.widthAnchor.constraint(equalTo: clipView.widthAnchor).isActive = true

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
        container.addSubview(declineButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(allowClicked))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
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
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
            scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 110),

            infoLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 10),
            infoLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            saveButton.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            declineButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            declineButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),

            container.widthAnchor.constraint(equalToConstant: 300),
        ])

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

    private func rebuildFileList() {
        guard let fileListStack = fileListStack else { return }

        for view in fileListStack.arrangedSubviews {
            fileListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for name in fileNames {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY

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
            row.addArrangedSubview(label)

            fileListStack.addArrangedSubview(row)
        }
    }

    @objc private func allowClicked() {
        delegate?.contentViewControllerDidAllow(self)
    }

    @objc private func denyClicked() {
        delegate?.contentViewControllerDidDeny(self)
    }
}
