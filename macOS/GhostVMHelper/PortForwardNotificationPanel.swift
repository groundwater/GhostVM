import AppKit

/// Delegate protocol for port forward notification content view controller actions
protocol PortForwardNotificationContentViewControllerDelegate: AnyObject {
    func notificationContentViewController(_ vc: PortForwardNotificationContentViewController, didBlockPort guestPort: UInt16)
}

final class PortForwardNotificationContentViewController: NSViewController, PopoverContent {

    weak var delegate: PortForwardNotificationContentViewControllerDelegate?

    let dismissBehavior: PopoverDismissBehavior = .semiTransient
    let preferredToolbarAnchor: NSToolbarItem.Identifier? = NSToolbarItem.Identifier("portForwards")

    func handleEscapeKey() -> Bool {
        // Dismiss handled by PopoverManager
        return false
    }

    private var mappings: [(guestPort: UInt16, hostPort: UInt16, processName: String?)] = []
    private var isLocallyRemoving = false
    private var needsRebuildAfterAnimation = false

    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var portListStack: NSStackView!

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        let padding: CGFloat = 16

        // Title
        titleLabel = NSTextField(labelWithString: "Auto Port Forward")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Subtitle
        subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitleLabel)

        // Port list stack
        portListStack = NSStackView()
        portListStack.orientation = .vertical
        portListStack.alignment = .leading
        portListStack.spacing = 4
        portListStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(portListStack)

        // Layout
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),

            portListStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            portListStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            portListStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            portListStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            container.widthAnchor.constraint(equalToConstant: 280),
        ])

        self.view = container
    }

    // MARK: - Public

    func setPortMappings(_ newMappings: [(guestPort: UInt16, hostPort: UInt16, processName: String?)]) {
        mappings = newMappings
        guard !isLocallyRemoving else {
            needsRebuildAfterAnimation = true
            return
        }
        rebuildPortList()
        updateSubtitle()
    }

    func addPortMappings(_ newMappings: [(guestPort: UInt16, hostPort: UInt16, processName: String?)]) {
        let existingGuests = Set(mappings.map { $0.guestPort })
        let added = newMappings.filter { !existingGuests.contains($0.guestPort) }
        guard !added.isEmpty else { return }

        for mapping in added {
            mappings.append(mapping)
            if let portListStack = portListStack {
                let row = makePortRow(guestPort: mapping.guestPort, hostPort: mapping.hostPort, processName: mapping.processName)
                portListStack.addArrangedSubview(row)
            }
        }
        updateSubtitle()
    }

    // MARK: - Private

    private func updateSubtitle() {
        let count = mappings.count
        subtitleLabel?.stringValue = "Forwarded \(count) port\(count == 1 ? "" : "s")"
    }

    private func rebuildPortList() {
        guard let portListStack = portListStack else { return }

        for view in portListStack.arrangedSubviews {
            portListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for mapping in mappings {
            let row = makePortRow(guestPort: mapping.guestPort, hostPort: mapping.hostPort, processName: mapping.processName)
            portListStack.addArrangedSubview(row)
        }
    }

    private func makePortRow(guestPort: UInt16, hostPort: UInt16, processName: String? = nil) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        // Plug icon
        if let plugImage = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "Port") {
            let icon = NSImageView(image: plugImage)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
            row.addArrangedSubview(icon)
        }

        // Description label
        let desc: String
        if let name = processName, !name.isEmpty {
            desc = "\(name) \(hostPort)\u{2192}\(guestPort)"
        } else {
            desc = "\(hostPort)\u{2192}\(guestPort)"
        }
        let label = NSTextField(labelWithString: desc)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        // Copy button
        let copyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Copy URL")!, target: self, action: #selector(copyPortClicked(_:)))
        copyButton.bezelStyle = .inline
        copyButton.isBordered = false
        copyButton.tag = Int(hostPort)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        copyButton.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row.addArrangedSubview(copyButton)

        // Block button
        let blockButton = NSButton(image: NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: "Block port forward")!, target: self, action: #selector(blockPortClicked(_:)))
        blockButton.bezelStyle = .inline
        blockButton.isBordered = false
        blockButton.tag = Int(guestPort)
        blockButton.translatesAutoresizingMaskIntoConstraints = false
        blockButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        blockButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(blockButton)

        return row
    }

    // MARK: - Actions

    @objc private func copyPortClicked(_ sender: NSButton) {
        let hostPort = UInt16(sender.tag)
        let urlString = "http://localhost:\(hostPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)

        // Flash checkmark briefly
        let originalImage = sender.image
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            sender.image = originalImage
        }
    }

    @objc private func blockPortClicked(_ sender: NSButton) {
        let guestPort = UInt16(sender.tag)
        guard let row = portListStack.arrangedSubviews.first(where: { sender.isDescendant(of: $0) }) else { return }

        // Remove from data model
        mappings.removeAll { $0.guestPort == guestPort }

        // Flag prevents setPortMappings callbacks from rebuilding during animation
        isLocallyRemoving = true

        // Notify delegate
        delegate?.notificationContentViewController(self, didBlockPort: guestPort)

        // Keep isLocallyRemoving set until animation completes
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.allowsImplicitAnimation = true
            row.animator().isHidden = true
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.portListStack.removeArrangedSubview(row)
            row.removeFromSuperview()
            self.isLocallyRemoving = false
            if self.needsRebuildAfterAnimation {
                self.needsRebuildAfterAnimation = false
                self.rebuildPortList()
            }
            self.updateSubtitle()
        })
    }
}
