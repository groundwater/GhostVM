import AppKit

/// Delegate protocol for port forward permission panel actions
protocol PortForwardPermissionPanelDelegate: AnyObject {
    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didBlockPort guestPort: UInt16)
    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didRemoveForwardWithHostPort hostPort: UInt16)
    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didToggleAutoPortMap enabled: Bool)
    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didUnblockPort port: UInt16)
    func portForwardPermissionPanelDidUnblockAll(_ panel: PortForwardPermissionPanel)
    func portForwardPermissionPanelDidRequestAddPortForward(_ panel: PortForwardPermissionPanel)
}

/// Unified NSPopover-based panel for port forward management.
/// Shown both on auto-detect notifications and toolbar button clicks.
final class PortForwardPermissionPanel: NSObject, NSPopoverDelegate {

    weak var delegate: PortForwardPermissionPanelDelegate?
    var onClose: (() -> Void)?

    private var popover: NSPopover?
    private var contentViewController: PortForwardPermissionContentViewController?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self

        let vc = PortForwardPermissionContentViewController()
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

    // MARK: - Data Forwarding

    func setEntries(_ entries: [PortForwardEntry]) {
        contentViewController?.setEntries(entries)
    }

    func setAutoPortMapEnabled(_ enabled: Bool) {
        contentViewController?.setAutoPortMapEnabled(enabled)
    }

    func setBlockedPortDescriptions(_ descriptions: [String]) {
        contentViewController?.setBlockedPortDescriptions(descriptions)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        contentViewController = nil
        onClose?()
    }
}

extension PortForwardPermissionPanel: PortForwardPermissionContentViewControllerDelegate {
    func contentViewController(_ vc: PortForwardPermissionContentViewController, didBlockPort guestPort: UInt16) {
        delegate?.portForwardPermissionPanel(self, didBlockPort: guestPort)
    }

    func contentViewController(_ vc: PortForwardPermissionContentViewController, didRemoveForwardWithHostPort hostPort: UInt16) {
        delegate?.portForwardPermissionPanel(self, didRemoveForwardWithHostPort: hostPort)
    }

    func contentViewController(_ vc: PortForwardPermissionContentViewController, didToggleAutoPortMap enabled: Bool) {
        delegate?.portForwardPermissionPanel(self, didToggleAutoPortMap: enabled)
    }

    func contentViewController(_ vc: PortForwardPermissionContentViewController, didUnblockPort port: UInt16) {
        delegate?.portForwardPermissionPanel(self, didUnblockPort: port)
    }

    func contentViewControllerDidUnblockAll(_ vc: PortForwardPermissionContentViewController) {
        delegate?.portForwardPermissionPanelDidUnblockAll(self)
    }

    func contentViewControllerDidRequestEditor(_ vc: PortForwardPermissionContentViewController) {
        delegate?.portForwardPermissionPanelDidRequestAddPortForward(self)
    }
}

// MARK: - Content View Controller

protocol PortForwardPermissionContentViewControllerDelegate: AnyObject {
    func contentViewController(_ vc: PortForwardPermissionContentViewController, didBlockPort guestPort: UInt16)
    func contentViewController(_ vc: PortForwardPermissionContentViewController, didRemoveForwardWithHostPort hostPort: UInt16)
    func contentViewController(_ vc: PortForwardPermissionContentViewController, didToggleAutoPortMap enabled: Bool)
    func contentViewController(_ vc: PortForwardPermissionContentViewController, didUnblockPort port: UInt16)
    func contentViewControllerDidUnblockAll(_ vc: PortForwardPermissionContentViewController)
    func contentViewControllerDidRequestEditor(_ vc: PortForwardPermissionContentViewController)
}

final class PortForwardPermissionContentViewController: NSViewController {

    weak var delegate: PortForwardPermissionContentViewControllerDelegate?

    private var entries: [PortForwardEntry] = []
    private var blockedDescriptions: [String] = []
    private var autoPortMapEnabled = false
    private var isLocallyRemoving = false
    private var needsRebuildAfterAnimation = false

    private var autoMapCheckbox: NSButton!
    private var portListStack: NSStackView!
    private var portScrollView: NSScrollView!
    private var scrollHeightConstraint: NSLayoutConstraint!
    private var blockedSection: NSView!
    private var blockedStack: NSStackView!
    private var emptyLabel: NSTextField!

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active

        let padding: CGFloat = 16

        // Auto Port Map checkbox
        autoMapCheckbox = NSButton(checkboxWithTitle: "Auto Port Map", target: self, action: #selector(autoMapToggled))
        autoMapCheckbox.state = autoPortMapEnabled ? .on : .off
        autoMapCheckbox.font = .systemFont(ofSize: 12)
        autoMapCheckbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(autoMapCheckbox)

        // Separator after checkbox
        let sep1 = NSBox()
        sep1.boxType = .separator
        sep1.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep1)

        // Port list in scroll view
        portScrollView = NSScrollView()
        portScrollView.translatesAutoresizingMaskIntoConstraints = false
        portScrollView.hasVerticalScroller = true
        portScrollView.borderType = .noBorder
        portScrollView.drawsBackground = false

        portListStack = NSStackView()
        portListStack.orientation = .vertical
        portListStack.alignment = .leading
        portListStack.spacing = 4
        portListStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = portListStack
        clipView.drawsBackground = false
        portScrollView.contentView = clipView
        portListStack.widthAnchor.constraint(equalTo: clipView.widthAnchor).isActive = true

        container.addSubview(portScrollView)

        // Empty state label
        emptyLabel = NSTextField(labelWithString: "No active port forwards")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        // Blocked ports section (hidden by default)
        blockedSection = NSView()
        blockedSection.translatesAutoresizingMaskIntoConstraints = false
        blockedSection.isHidden = true

        let blockedSep = NSBox()
        blockedSep.boxType = .separator
        blockedSep.translatesAutoresizingMaskIntoConstraints = false
        blockedSection.addSubview(blockedSep)

        let blockedTitle = NSTextField(labelWithString: "Blocked Ports")
        blockedTitle.font = .systemFont(ofSize: 11, weight: .medium)
        blockedTitle.textColor = .secondaryLabelColor
        blockedTitle.translatesAutoresizingMaskIntoConstraints = false
        blockedSection.addSubview(blockedTitle)

        blockedStack = NSStackView()
        blockedStack.orientation = .vertical
        blockedStack.alignment = .leading
        blockedStack.spacing = 4
        blockedStack.translatesAutoresizingMaskIntoConstraints = false
        blockedSection.addSubview(blockedStack)

        let unblockAllButton = NSButton(title: "Unblock All", target: self, action: #selector(unblockAllClicked))
        unblockAllButton.bezelStyle = .inline
        unblockAllButton.font = .systemFont(ofSize: 11)
        unblockAllButton.translatesAutoresizingMaskIntoConstraints = false
        blockedSection.addSubview(unblockAllButton)

        NSLayoutConstraint.activate([
            blockedSep.topAnchor.constraint(equalTo: blockedSection.topAnchor),
            blockedSep.leadingAnchor.constraint(equalTo: blockedSection.leadingAnchor),
            blockedSep.trailingAnchor.constraint(equalTo: blockedSection.trailingAnchor),

            blockedTitle.topAnchor.constraint(equalTo: blockedSep.bottomAnchor, constant: 8),
            blockedTitle.leadingAnchor.constraint(equalTo: blockedSection.leadingAnchor),

            blockedStack.topAnchor.constraint(equalTo: blockedTitle.bottomAnchor, constant: 6),
            blockedStack.leadingAnchor.constraint(equalTo: blockedSection.leadingAnchor),
            blockedStack.trailingAnchor.constraint(equalTo: blockedSection.trailingAnchor),

            unblockAllButton.topAnchor.constraint(equalTo: blockedStack.bottomAnchor, constant: 6),
            unblockAllButton.leadingAnchor.constraint(equalTo: blockedSection.leadingAnchor),
            unblockAllButton.bottomAnchor.constraint(equalTo: blockedSection.bottomAnchor),
        ])

        container.addSubview(blockedSection)

        // Bottom separator
        let sep2 = NSBox()
        sep2.boxType = .separator
        sep2.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep2)

        // Edit button
        let editButton = NSButton(title: "Add Port Forward\u{2026}", target: self, action: #selector(editClicked))
        editButton.bezelStyle = .inline
        editButton.font = .systemFont(ofSize: 12)
        editButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(editButton)

        // Layout
        NSLayoutConstraint.activate([
            autoMapCheckbox.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            autoMapCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            autoMapCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -padding),

            sep1.topAnchor.constraint(equalTo: autoMapCheckbox.bottomAnchor, constant: 10),
            sep1.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            sep1.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            portScrollView.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 8),
            portScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            portScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            emptyLabel.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 8),
            emptyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            emptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            blockedSection.topAnchor.constraint(equalTo: portScrollView.bottomAnchor, constant: 8),
            blockedSection.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            blockedSection.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            sep2.topAnchor.constraint(equalTo: blockedSection.bottomAnchor, constant: 8),
            sep2.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            sep2.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),

            editButton.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 8),
            editButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            editButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),

            container.widthAnchor.constraint(equalToConstant: 300),
        ])

        scrollHeightConstraint = portScrollView.heightAnchor.constraint(equalToConstant: 24)
        scrollHeightConstraint.isActive = true

        rebuildPortList()
        rebuildBlockedSection()
        updateEmptyState()

        self.view = container
    }

    // MARK: - Public

    func setEntries(_ entries: [PortForwardEntry]) {
        self.entries = entries
        guard !isLocallyRemoving else {
            needsRebuildAfterAnimation = true
            return
        }
        rebuildPortList()
        updateEmptyState()
    }

    func setAutoPortMapEnabled(_ enabled: Bool) {
        autoPortMapEnabled = enabled
        autoMapCheckbox?.state = enabled ? .on : .off
    }

    func setBlockedPortDescriptions(_ descriptions: [String]) {
        blockedDescriptions = descriptions
        rebuildBlockedSection()
    }

    // MARK: - Private

    private func updateEmptyState() {
        let empty = entries.isEmpty
        emptyLabel?.isHidden = !empty
        portScrollView?.isHidden = empty
    }

    private func updateScrollViewHeight() {
        guard let portListStack = portListStack, let scrollHeightConstraint = scrollHeightConstraint else { return }
        portListStack.layoutSubtreeIfNeeded()
        let fittingHeight = portListStack.fittingSize.height
        scrollHeightConstraint.constant = min(max(fittingHeight, 24), 200)
    }

    private func rebuildPortList() {
        guard let portListStack = portListStack else { return }

        for view in portListStack.arrangedSubviews {
            portListStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for entry in entries {
            let row = makePortRow(for: entry)
            portListStack.addArrangedSubview(row)
        }

        updateScrollViewHeight()
    }

    private func makePortRow(for entry: PortForwardEntry) -> NSStackView {
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
        if let name = entry.processName, !name.isEmpty {
            desc = "\(name) \(entry.hostPort)\u{2192}\(entry.guestPort)"
        } else {
            desc = "\(entry.hostPort)\u{2192}\(entry.guestPort)"
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
        copyButton.tag = Int(entry.hostPort)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.widthAnchor.constraint(equalToConstant: 16).isActive = true
        copyButton.heightAnchor.constraint(equalToConstant: 16).isActive = true
        row.addArrangedSubview(copyButton)

        // Block/remove button
        let removeButton = NSButton(image: NSImage(systemSymbolName: "xmark.octagon", accessibilityDescription: "Block port forward")!, target: self, action: #selector(removePortClicked(_:)))
        removeButton.bezelStyle = .inline
        removeButton.isBordered = false
        removeButton.tag = Int(entry.hostPort)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        removeButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
        row.addArrangedSubview(removeButton)

        return row
    }

    private func rebuildBlockedSection() {
        guard let blockedStack = blockedStack else { return }

        for view in blockedStack.arrangedSubviews {
            blockedStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        blockedSection?.isHidden = blockedDescriptions.isEmpty

        for desc in blockedDescriptions {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY

            let label = NSTextField(labelWithString: desc)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)

            // Extract port number from description (e.g. "localhost:8023" -> 8023)
            if let portStr = desc.split(separator: ":").last, let port = UInt16(portStr) {
                let unblockButton = NSButton(title: "Unblock", target: self, action: #selector(unblockPortClicked(_:)))
                unblockButton.bezelStyle = .inline
                unblockButton.font = .systemFont(ofSize: 11)
                unblockButton.tag = Int(port)
                unblockButton.translatesAutoresizingMaskIntoConstraints = false
                row.addArrangedSubview(unblockButton)
            }

            blockedStack.addArrangedSubview(row)
        }
    }

    // MARK: - Actions

    @objc private func autoMapToggled() {
        let enabled = autoMapCheckbox.state == .on
        autoPortMapEnabled = enabled
        delegate?.contentViewController(self, didToggleAutoPortMap: enabled)
    }

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

    @objc private func removePortClicked(_ sender: NSButton) {
        let hostPort = UInt16(sender.tag)
        guard let entry = entries.first(where: { $0.hostPort == hostPort }) else { return }
        guard let row = portListStack.arrangedSubviews.first(where: { sender.isDescendant(of: $0) }) else { return }

        // Remove from data model
        entries.removeAll { $0.hostPort == hostPort }

        // Flag prevents setEntries callbacks from rebuilding during animation
        isLocallyRemoving = true

        if entry.isAutoMapped {
            delegate?.contentViewController(self, didBlockPort: entry.guestPort)
        } else {
            delegate?.contentViewController(self, didRemoveForwardWithHostPort: hostPort)
        }

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
            self.updateEmptyState()
        })
    }

    @objc private func unblockPortClicked(_ sender: NSButton) {
        let port = UInt16(sender.tag)
        delegate?.contentViewController(self, didUnblockPort: port)
    }

    @objc private func unblockAllClicked() {
        delegate?.contentViewControllerDidUnblockAll(self)
    }

    @objc private func editClicked() {
        delegate?.contentViewControllerDidRequestEditor(self)
    }
}
