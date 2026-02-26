import AppKit

/// Delegate protocol for clipboard permission content view controller actions
protocol ClipboardPermissionContentViewControllerDelegate: AnyObject {
    func contentViewControllerDidDeny(_ vc: ClipboardPermissionContentViewController)
    func contentViewControllerDidAllowOnce(_ vc: ClipboardPermissionContentViewController)
    func contentViewControllerDidAlwaysAllow(_ vc: ClipboardPermissionContentViewController)
}

final class ClipboardPermissionContentViewController: NSViewController, PopoverContent {

    weak var delegate: ClipboardPermissionContentViewControllerDelegate?

    let dismissBehavior: PopoverDismissBehavior = .requiresExplicitAction
    let preferredToolbarAnchor = NSToolbarItem.Identifier("clipboardSync")

    func handleEnterKey() -> Bool {
        delegate?.contentViewControllerDidAllowOnce(self)
        return true
    }

    func handleEscapeKey() -> Bool {
        delegate?.contentViewControllerDidDeny(self)
        return true
    }

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
