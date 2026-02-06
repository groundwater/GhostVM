import AppKit

/// Delegate protocol for queued files panel actions
protocol QueuedFilesPanelDelegate: AnyObject {
    func queuedFilesPanelDidAllow(_ panel: QueuedFilesPanel)
    func queuedFilesPanelDidDeny(_ panel: QueuedFilesPanel)
}

/// NSPopover-based panel showing queued guest files with Allow/Deny actions
final class QueuedFilesPanel: NSObject {

    weak var delegate: QueuedFilesPanelDelegate?

    private var popover: NSPopover?
    private var fileNames: [String] = []
    private var contentViewController: QueuedFilesContentViewController?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)

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
        popover = nil
    }

    func setFileNames(_ names: [String]) {
        fileNames = names
        contentViewController?.setFileNames(names)
    }
}

extension QueuedFilesPanel: QueuedFilesContentViewControllerDelegate {
    func contentViewControllerDidAllow(_ vc: QueuedFilesContentViewController) {
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
    private var stackView: NSStackView!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
        container.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = NSTextField(labelWithString: "Files from Guest")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Scroll view with file name stack
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = stackView
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        // Pin stackView width to clipView
        stackView.widthAnchor.constraint(equalTo: clipView.widthAnchor).isActive = true

        container.addSubview(scrollView)

        // Button row
        let denyButton = NSButton(title: "Deny", target: self, action: #selector(denyClicked))
        denyButton.translatesAutoresizingMaskIntoConstraints = false
        denyButton.bezelStyle = .rounded
        container.addSubview(denyButton)

        let allowButton = NSButton(title: "Allow", target: self, action: #selector(allowClicked))
        allowButton.translatesAutoresizingMaskIntoConstraints = false
        allowButton.bezelStyle = .rounded
        allowButton.keyEquivalent = "\r"
        container.addSubview(allowButton)

        // Layout
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            allowButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            allowButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            allowButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            denyButton.centerYAnchor.constraint(equalTo: allowButton.centerYAnchor),
            denyButton.trailingAnchor.constraint(equalTo: allowButton.leadingAnchor, constant: -8),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])

        rebuildFileList()
        self.view = container
    }

    func setFileNames(_ names: [String]) {
        fileNames = names
        rebuildFileList()
    }

    private func rebuildFileList() {
        guard let stackView = stackView else { return }

        // Remove existing labels
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for name in fileNames {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            stackView.addArrangedSubview(label)
        }
    }

    @objc private func allowClicked() {
        delegate?.contentViewControllerDidAllow(self)
    }

    @objc private func denyClicked() {
        delegate?.contentViewControllerDidDeny(self)
    }
}
