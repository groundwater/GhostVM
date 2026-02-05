import AppKit

/// NSToolbar implementation for the VM helper window.
/// Provides quick access to VM status and controls.
final class HelperToolbar: NSObject, NSToolbarDelegate, PortForwardPanelDelegate {

    // MARK: - Toolbar Item Identifiers

    private enum ItemID {
        static let guestToolsStatus = NSToolbarItem.Identifier("guestToolsStatus")
        static let portForwards = NSToolbarItem.Identifier("portForwards")
        static let clipboardSync = NSToolbarItem.Identifier("clipboardSync")
        static let queuedFiles = NSToolbarItem.Identifier("queuedFiles")
        static let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
        static let shutDown = NSToolbarItem.Identifier("shutDown")
        static let terminate = NSToolbarItem.Identifier("terminate")
    }

    // MARK: - Properties

    weak var delegate: HelperToolbarDelegate?

    private let toolbar: NSToolbar
    private var guestToolsConnected = false
    private var portForwardCount = 0
    private var clipboardSyncMode = "disabled"
    private var queuedFileCount = 0

    private var guestToolsItem: NSToolbarItem?
    private var portForwardsItem: NSMenuToolbarItem?
    private var clipboardSyncItem: NSMenuToolbarItem?
    private var queuedFilesItem: NSToolbarItem?
    private var shutDownItem: NSToolbarItem?
    private var terminateItem: NSToolbarItem?

    private weak var window: NSWindow?
    private var portForwardPanel: PortForwardPanel?
    private var portForwardEntries: [PortForwardEntry] = []

    // MARK: - Initialization

    override init() {
        toolbar = NSToolbar(identifier: "HelperToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    // MARK: - State Updates

    func setGuestToolsConnected(_ connected: Bool) {
        guestToolsConnected = connected
        updateGuestToolsButton()
    }

    func setPortForwardCount(_ count: Int) {
        portForwardCount = count
        updatePortForwardsButton()
    }

    func setPortForwardEntries(_ entries: [PortForwardEntry]) {
        portForwardEntries = entries
        portForwardCount = entries.count
        updatePortForwardsButton()
        rebuildPortForwardsMenu()
        portForwardPanel?.setEntries(entries)
    }

    func setClipboardSyncMode(_ mode: String) {
        clipboardSyncMode = mode
        updateClipboardSyncButton()
        rebuildClipboardSyncMenu()
    }

    func setQueuedFileCount(_ count: Int) {
        queuedFileCount = count
        updateQueuedFilesButton()
    }

    func setVMRunning(_ running: Bool) {
        shutDownItem?.isEnabled = running
        terminateItem?.isEnabled = running
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemID.guestToolsStatus,
            ItemID.portForwards,
            ItemID.clipboardSync,
            ItemID.queuedFiles,
            ItemID.flexibleSpace,
            ItemID.shutDown,
            ItemID.terminate
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.guestToolsStatus:
            return makeGuestToolsItem()
        case ItemID.portForwards:
            return makePortForwardsItem()
        case ItemID.clipboardSync:
            return makeClipboardSyncItem()
        case ItemID.queuedFiles:
            return makeQueuedFilesItem()
        case ItemID.shutDown:
            return makeShutDownItem()
        case ItemID.terminate:
            return makeTerminateItem()
        default:
            return nil
        }
    }

    // MARK: - Item Creation

    private func makeGuestToolsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.guestToolsStatus)
        item.label = "Guest Tools"
        item.paletteLabel = "Guest Tools Status"
        item.isEnabled = false // Status indicator, not clickable

        guestToolsItem = item
        updateGuestToolsButton()

        return item
    }

    private func makePortForwardsItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: ItemID.portForwards)
        item.label = "Ports"
        item.paletteLabel = "Port Forwards"
        item.toolTip = "Manage port forwards"
        item.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Port Forwards")
        item.showsIndicator = true

        portForwardsItem = item
        rebuildPortForwardsMenu()

        return item
    }

    private func makeClipboardSyncItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: ItemID.clipboardSync)
        item.label = "Clipboard"
        item.paletteLabel = "Clipboard Sync"
        item.toolTip = "Clipboard sync mode"
        item.showsIndicator = true

        clipboardSyncItem = item
        updateClipboardSyncButton()
        rebuildClipboardSyncMenu()

        return item
    }

    private func makeQueuedFilesItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.queuedFiles)
        item.label = "Files"
        item.paletteLabel = "Queued Files"
        item.toolTip = "Receive files from guest"
        item.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Receive Files")
        item.target = self
        item.action = #selector(receiveQueuedFiles)

        queuedFilesItem = item

        return item
    }

    private func makeShutDownItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.shutDown)
        item.label = "Shut Down"
        item.paletteLabel = "Shut Down"
        item.toolTip = "Shut down the guest OS gracefully"
        item.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Shut Down")
        item.target = self
        item.action = #selector(shutDownVM)

        shutDownItem = item
        return item
    }

    private func makeTerminateItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.terminate)
        item.label = "Terminate"
        item.paletteLabel = "Terminate"
        item.toolTip = "Force terminate VM immediately"
        item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Terminate")
        item.target = self
        item.action = #selector(terminateVM)

        terminateItem = item
        return item
    }

    // MARK: - Button Updates

    private func updateGuestToolsButton() {
        guard let item = guestToolsItem else { return }

        let symbolName = "app.connected.to.app.below.fill"
        let color: NSColor = guestToolsConnected ? .systemGreen : .systemGray

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Guest Tools") {
            let config = NSImage.SymbolConfiguration(paletteColors: [color])
            item.image = image.withSymbolConfiguration(config)
        }
        item.toolTip = guestToolsConnected ? "GhostTools is connected" : "GhostTools is not connected"
    }

    private func updatePortForwardsButton() {
        guard let item = portForwardsItem else { return }
        if portForwardCount > 0 {
            item.label = "\(portForwardCount) Port\(portForwardCount == 1 ? "" : "s")"
        } else {
            item.label = "Ports"
        }
    }

    private func updateClipboardSyncButton() {
        guard let item = clipboardSyncItem else { return }

        let symbolName: String
        switch clipboardSyncMode {
        case "bidirectional":
            symbolName = "arrow.left.arrow.right.circle.fill"
        case "hostToGuest":
            symbolName = "arrow.right.circle.fill"
        case "guestToHost":
            symbolName = "arrow.left.circle.fill"
        default:
            symbolName = "clipboard"
        }

        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipboard Sync")
    }

    private func updateQueuedFilesButton() {
        guard let item = queuedFilesItem else { return }
        if queuedFileCount > 0 {
            item.label = "\(queuedFileCount) File\(queuedFileCount == 1 ? "" : "s")"
        } else {
            item.label = "Files"
        }
    }

    // MARK: - Menu Builders

    private func rebuildClipboardSyncMenu() {
        guard let item = clipboardSyncItem else { return }

        let menu = NSMenu()
        let modes: [(String, String)] = [
            ("Bidirectional", "bidirectional"),
            ("Host \u{2192} Guest", "hostToGuest"),
            ("Guest \u{2192} Host", "guestToHost"),
            ("Disabled", "disabled")
        ]

        for (title, mode) in modes {
            let menuItem = NSMenuItem(title: title, action: #selector(setClipboardMode(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = mode
            menuItem.state = (mode == clipboardSyncMode) ? .on : .off
            menu.addItem(menuItem)
        }

        item.menu = menu
    }

    private func rebuildPortForwardsMenu() {
        guard let item = portForwardsItem else { return }

        let menu = NSMenu()

        if !portForwardEntries.isEmpty {
            for entry in portForwardEntries {
                let menuItem = NSMenuItem(title: "localhost:\(entry.hostPort) \u{2192} :\(entry.guestPort)", action: #selector(copyPortForwardURL(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = entry.hostPort
                menuItem.toolTip = "Click to copy URL"
                menu.addItem(menuItem)
            }
            menu.addItem(NSMenuItem.separator())
        }

        let editItem = NSMenuItem(title: "Edit Port Forwards\u{2026}", action: #selector(editPortForwards(_:)), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        item.menu = menu
    }

    // MARK: - Actions

    @objc private func copyPortForwardURL(_ sender: NSMenuItem) {
        guard let hostPort = sender.representedObject as? UInt16 else { return }
        let urlString = "http://localhost:\(hostPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
    }

    @objc private func setClipboardMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        clipboardSyncMode = mode
        updateClipboardSyncButton()
        rebuildClipboardSyncMenu()
        delegate?.toolbar(self, didSelectClipboardSyncMode: mode)
    }

    @objc private func editPortForwards(_ sender: NSMenuItem) {
        // Delay to next run loop iteration so the menu fully dismisses first;
        // otherwise the transient popover immediately closes with the menu.
        DispatchQueue.main.async { [self] in
            guard let contentView = window?.contentView else {
                delegate?.toolbarDidRequestPortForwardEditor(self)
                return
            }

            portForwardPanel?.close()

            let panel = PortForwardPanel()
            panel.delegate = self
            panel.setEntries(portForwardEntries)
            // Anchor to top-center of the content view, pointing up toward toolbar
            let anchorRect = NSRect(x: contentView.bounds.midX - 1, y: contentView.bounds.maxY, width: 2, height: 1)
            panel.show(relativeTo: anchorRect, of: contentView, preferredEdge: .maxY)
            portForwardPanel = panel
        }
    }

    @objc private func receiveQueuedFiles() {
        delegate?.toolbarDidRequestReceiveFiles(self)
    }

    @objc private func shutDownVM() {
        delegate?.toolbarDidRequestShutDown(self)
    }

    @objc private func terminateVM() {
        delegate?.toolbarDidRequestTerminate(self)
    }

    // MARK: - PortForwardPanelDelegate

    func portForwardPanel(_ panel: PortForwardPanel, didAddForward hostPort: UInt16, guestPort: UInt16) {
        delegate?.toolbar(self, didAddPortForward: hostPort, guestPort: guestPort)
    }

    func portForwardPanel(_ panel: PortForwardPanel, didRemoveForwardWithHostPort hostPort: UInt16) {
        delegate?.toolbar(self, didRemovePortForwardWithHostPort: hostPort)
    }
}

// MARK: - Delegate Protocol

protocol HelperToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: HelperToolbar, didSelectClipboardSyncMode mode: String)
    func toolbar(_ toolbar: HelperToolbar, didAddPortForward hostPort: UInt16, guestPort: UInt16)
    func toolbar(_ toolbar: HelperToolbar, didRemovePortForwardWithHostPort hostPort: UInt16)
    func toolbarDidRequestPortForwardEditor(_ toolbar: HelperToolbar)
    func toolbarDidRequestReceiveFiles(_ toolbar: HelperToolbar)
    func toolbarDidRequestShutDown(_ toolbar: HelperToolbar)
    func toolbarDidRequestTerminate(_ toolbar: HelperToolbar)
}
