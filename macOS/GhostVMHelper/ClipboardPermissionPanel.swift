import AppKit

/// Delegate protocol for clipboard permission panel actions
protocol ClipboardPermissionPanelDelegate: AnyObject {
    func clipboardPermissionPanelDidDeny(_ panel: ClipboardPermissionPanel)
    func clipboardPermissionPanelDidAllowOnce(_ panel: ClipboardPermissionPanel)
    func clipboardPermissionPanelDidAlwaysAllow(_ panel: ClipboardPermissionPanel)
}

/// NSPopover-based panel prompting the user to allow clipboard sync
final class ClipboardPermissionPanel: NSObject, NSPopoverDelegate {

    weak var delegate: ClipboardPermissionPanelDelegate?
    var onClose: (() -> Void)?

    private var popover: NSPopover?
    private var contentViewController: ClipboardPermissionContentViewController?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self

        let vc = ClipboardPermissionContentViewController()
        vc.delegate = self
        contentViewController = vc

        popover.contentViewController = vc
        popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        self.popover = popover
    }

    func close() {
        popover?.close()
    }

    var isShown: Bool {
        popover?.isShown ?? false
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        contentViewController = nil
        onClose?()
    }
}

extension ClipboardPermissionPanel: ClipboardPermissionContentViewControllerDelegate {
    func contentViewControllerDidDeny(_ vc: ClipboardPermissionContentViewController) {
        delegate?.clipboardPermissionPanelDidDeny(self)
    }

    func contentViewControllerDidAllowOnce(_ vc: ClipboardPermissionContentViewController) {
        delegate?.clipboardPermissionPanelDidAllowOnce(self)
    }

    func contentViewControllerDidAlwaysAllow(_ vc: ClipboardPermissionContentViewController) {
        delegate?.clipboardPermissionPanelDidAlwaysAllow(self)
    }
}

// MARK: - Content View Controller

protocol ClipboardPermissionContentViewControllerDelegate: AnyObject {
    func contentViewControllerDidDeny(_ vc: ClipboardPermissionContentViewController)
    func contentViewControllerDidAllowOnce(_ vc: ClipboardPermissionContentViewController)
    func contentViewControllerDidAlwaysAllow(_ vc: ClipboardPermissionContentViewController)
}

final class ClipboardPermissionContentViewController: NSViewController {

    weak var delegate: ClipboardPermissionContentViewControllerDelegate?

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "Copy clipboard to guest?")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        // Buttons
        let denyButton = NSButton(title: "Deny", target: self, action: #selector(denyClicked))
        denyButton.bezelStyle = .rounded
        denyButton.keyEquivalent = "\u{1b}"
        denyButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(denyButton)

        let onceButton = NSButton(title: "Once", target: self, action: #selector(onceClicked))
        onceButton.bezelStyle = .rounded
        onceButton.keyEquivalent = "\r"
        onceButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(onceButton)

        let alwaysButton = NSButton(title: "Always", target: self, action: #selector(alwaysClicked))
        alwaysButton.bezelStyle = .rounded
        alwaysButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(alwaysButton)

        // Layout
        let padding: CGFloat = 16

        NSLayoutConstraint.activate([
            subtitleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            alwaysButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            alwaysButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            alwaysButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            onceButton.centerYAnchor.constraint(equalTo: alwaysButton.centerYAnchor),
            onceButton.trailingAnchor.constraint(equalTo: alwaysButton.leadingAnchor, constant: -8),

            denyButton.centerYAnchor.constraint(equalTo: alwaysButton.centerYAnchor),
            denyButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            container.widthAnchor.constraint(equalToConstant: 260),
        ])

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKeyAndOrderFront(nil)
    }

    override func keyDown(with event: NSEvent) {
        delegate?.contentViewControllerDidDeny(self)
    }

    @objc private func denyClicked() {
        delegate?.contentViewControllerDidDeny(self)
    }

    @objc private func onceClicked() {
        delegate?.contentViewControllerDidAllowOnce(self)
    }

    @objc private func alwaysClicked() {
        delegate?.contentViewControllerDidAlwaysAllow(self)
    }
}
