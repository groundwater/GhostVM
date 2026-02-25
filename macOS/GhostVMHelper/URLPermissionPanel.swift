import AppKit
import GhostVMKit

/// Delegate protocol for URL permission panel actions
protocol URLPermissionPanelDelegate: AnyObject {
    func urlPermissionPanelDidDeny(_ panel: URLPermissionPanel)
    func urlPermissionPanelDidAllowOnce(_ panel: URLPermissionPanel)
    func urlPermissionPanelDidAlwaysAllow(_ panel: URLPermissionPanel)
}

/// NSPopover-based panel prompting the user to allow opening a URL from the guest
final class URLPermissionPanel: NSObject, NSPopoverDelegate {

    weak var delegate: URLPermissionPanelDelegate?
    var onClose: (() -> Void)?

    private var popover: NSPopover?
    private var alertWindow: NSWindow?
    private var contentViewController: URLPermissionContentViewController?
    private var currentURLs: [String] = []

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.delegate = self

        let vc = URLPermissionContentViewController()
        vc.delegate = self
        contentViewController = vc

        popover.contentViewController = vc
        popover.show(relativeTo: positioningRect, of: positioningView, preferredEdge: preferredEdge)
        self.popover = popover
    }

    func showAsAlert(in window: NSWindow) {
        let urlDescription: String
        if currentURLs.count == 1 {
            urlDescription = URLUtilities.truncateMiddle(currentURLs[0], maxLength: 60)
        } else if currentURLs.count > 1 {
            urlDescription = "\(currentURLs.count) URLs from guest"
        } else {
            urlDescription = "URL from guest"
        }

        let alert = NSAlert()
        alert.messageText = "Open URL?"
        alert.informativeText = urlDescription
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Always")
        alert.addButton(withTitle: "Deny")
        alertWindow = window
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.delegate?.urlPermissionPanelDidAllowOnce(self)
            case .alertSecondButtonReturn:
                self.delegate?.urlPermissionPanelDidAlwaysAllow(self)
            default:
                self.delegate?.urlPermissionPanelDidDeny(self)
            }
            self.alertWindow = nil
            self.onClose?()
        }
    }

    func close() {
        popover?.close()
        if let window = alertWindow {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            alertWindow = nil
            onClose?()
        }
    }

    var isShown: Bool {
        (popover?.isShown ?? false) || alertWindow != nil
    }

    func setURLs(_ urls: [String]) {
        currentURLs = urls
        contentViewController?.setURLs(urls)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        contentViewController = nil
        onClose?()
    }
}

extension URLPermissionPanel: URLPermissionContentViewControllerDelegate {
    func contentViewControllerDidDeny(_ vc: URLPermissionContentViewController) {
        delegate?.urlPermissionPanelDidDeny(self)
    }

    func contentViewControllerDidAllowOnce(_ vc: URLPermissionContentViewController) {
        delegate?.urlPermissionPanelDidAllowOnce(self)
    }

    func contentViewControllerDidAlwaysAllow(_ vc: URLPermissionContentViewController) {
        delegate?.urlPermissionPanelDidAlwaysAllow(self)
    }
}

// MARK: - Content View Controller

protocol URLPermissionContentViewControllerDelegate: AnyObject {
    func contentViewControllerDidDeny(_ vc: URLPermissionContentViewController)
    func contentViewControllerDidAllowOnce(_ vc: URLPermissionContentViewController)
    func contentViewControllerDidAlwaysAllow(_ vc: URLPermissionContentViewController)
}

final class URLPermissionContentViewController: NSViewController {

    weak var delegate: URLPermissionContentViewControllerDelegate?
    private var urlLabel: NSTextField?

    func setURLs(_ urls: [String]) {
        guard let label = urlLabel else { return }
        if urls.count == 1 {
            label.stringValue = URLUtilities.truncateMiddle(urls[0], maxLength: 60)
            label.toolTip = urls[0]
        } else {
            label.stringValue = "\(urls.count) URLs from guest"
            label.toolTip = urls.joined(separator: "\n")
        }
    }

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        // Title
        let titleLabel = NSTextField(labelWithString: "Open URL?")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // URL display
        let urlField = NSTextField(labelWithString: "")
        urlField.font = .systemFont(ofSize: 11)
        urlField.textColor = .secondaryLabelColor
        urlField.lineBreakMode = .byTruncatingMiddle
        urlField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(urlField)
        self.urlLabel = urlField

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
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),

            urlField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
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
