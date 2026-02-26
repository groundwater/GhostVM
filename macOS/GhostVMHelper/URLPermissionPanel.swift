import AppKit
import GhostVMKit

/// Delegate protocol for URL permission content view controller actions
protocol URLPermissionContentViewControllerDelegate: AnyObject {
    func contentViewControllerDidDeny(_ vc: URLPermissionContentViewController)
    func contentViewControllerDidAllowOnce(_ vc: URLPermissionContentViewController)
    func contentViewControllerDidAlwaysAllow(_ vc: URLPermissionContentViewController)
}

final class URLPermissionContentViewController: NSViewController, PopoverContent {

    weak var delegate: URLPermissionContentViewControllerDelegate?
    private var titleLabel: NSTextField?
    private var urlLabel: NSTextField?

    /// The single URL this prompt is for.
    private(set) var urlString: String = ""

    let dismissBehavior: PopoverDismissBehavior = .requiresExplicitAction
    let preferredToolbarAnchor = NSToolbarItem.Identifier("captureCommands")

    func handleEnterKey() -> Bool {
        delegate?.contentViewControllerDidAllowOnce(self)
        return true
    }

    func handleEscapeKey() -> Bool {
        delegate?.contentViewControllerDidDeny(self)
        return true
    }

    func setURL(_ url: String) {
        urlString = url
        let domain = URL(string: url)?.host ?? url
        titleLabel?.stringValue = "Open \(domain)?"
        guard let label = urlLabel else { return }
        label.stringValue = URLUtilities.truncateMiddle(url, maxLength: 60)
        label.toolTip = url
    }

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        // Title
        let titleField = NSTextField(labelWithString: "Open URL?")
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleField)
        self.titleLabel = titleField

        // URL display
        let urlField = NSTextField(labelWithString: "")
        urlField.font = .systemFont(ofSize: 11)
        urlField.textColor = .secondaryLabelColor
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(urlField)
        self.urlLabel = urlField

        // Populate from stored data if setURL was called before loadView (queued VC).
        if !urlString.isEmpty {
            let domain = URL(string: urlString)?.host ?? urlString
            titleField.stringValue = "Open \(domain)?"
            urlField.stringValue = URLUtilities.truncateMiddle(urlString, maxLength: 60)
            urlField.toolTip = urlString
        }

        // Buttons
        let denyButton = NSButton(title: "Deny", target: self, action: #selector(denyClicked))
        denyButton.bezelStyle = .rounded
        denyButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(denyButton)

        let onceButton = NSButton(title: "Open", target: self, action: #selector(onceClicked))
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
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            urlField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            urlField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            urlField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            alwaysButton.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 12),
            alwaysButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            alwaysButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            onceButton.centerYAnchor.constraint(equalTo: alwaysButton.centerYAnchor),
            onceButton.trailingAnchor.constraint(equalTo: alwaysButton.leadingAnchor, constant: -8),

            denyButton.centerYAnchor.constraint(equalTo: alwaysButton.centerYAnchor),
            denyButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            container.widthAnchor.constraint(equalToConstant: 300),
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
