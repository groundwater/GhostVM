import AppKit

/// NSPopover-based panel showing GhostTools installation help
final class GuestToolsInfoPanel: NSObject, NSPopoverDelegate {

    var onClose: (() -> Void)?

    private var popover: NSPopover?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        let vc = GuestToolsInfoContentViewController()
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
        onClose?()
    }
}

// MARK: - Content View Controller

private final class GuestToolsInfoContentViewController: NSViewController {
    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        // Title
        let titleLabel = NSTextField(labelWithString: "Guest Tools Not Found")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Body
        let bodyLabel = NSTextField(wrappingLabelWithString: "GhostTools should install automatically from the mounted disk image. If it didn\u{2019}t start, open the GhostTools volume in Finder and launch GhostTools.app.")
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bodyLabel)

        // Layout
        let padding: CGFloat = 16

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            bodyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            bodyLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            container.widthAnchor.constraint(equalToConstant: 280),
        ])

        self.view = container
    }
}
