import AppKit

/// NSToolbar implementation for the VM helper window.
/// Provides quick access to VM status and controls.
final class HelperToolbar: NSObject, NSToolbarDelegate, PortForwardPanelDelegate, SharedFolderPanelDelegate, QueuedFilesPanelDelegate {

    // MARK: - Toolbar Item Identifiers

    private enum ItemID {
        static let guestToolsStatus = NSToolbarItem.Identifier("guestToolsStatus")
        static let portForwards = NSToolbarItem.Identifier("portForwards")
        static let sharedFolders = NSToolbarItem.Identifier("sharedFolders")
        static let clipboardSync = NSToolbarItem.Identifier("clipboardSync")
        static let captureKeys = NSToolbarItem.Identifier("captureKeys")
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
    private var sharedFolderCount = 0
    private var clipboardSyncMode = "disabled"
    private var captureSystemKeysEnabled = true
    private var queuedFileCount = 0
    private var queuedFileNames: [String] = []

    private var guestToolsItem: NSToolbarItem?
    private var portForwardsItem: NSToolbarItem?
    private var sharedFoldersItem: NSToolbarItem?
    private var clipboardSyncItem: NSToolbarItem?
    private var captureKeysItem: NSToolbarItem?
    private var queuedFilesItem: NSToolbarItem?
    private var shutDownItem: NSToolbarItem?
    private var terminateItem: NSToolbarItem?

    private var portForwardsMenu = NSMenu()
    private var sharedFoldersMenu = NSMenu()
    private var clipboardSyncMenu = NSMenu()

    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    private weak var window: NSWindow?
    private var portForwardPanel: PortForwardPanel?
    private var portForwardEntries: [PortForwardEntry] = []
    private var sharedFolderPanel: SharedFolderPanel?
    private var sharedFolderEntries: [SharedFolderEntry] = []
    private var queuedFilesPanel: QueuedFilesPanel?
    private var previousQueuedFileCount = 0

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

    func setSharedFolderEntries(_ entries: [SharedFolderEntry]) {
        sharedFolderEntries = entries
        sharedFolderCount = entries.count
        updateSharedFoldersButton()
        rebuildSharedFoldersMenu()
        sharedFolderPanel?.setEntries(entries)
    }

    func setClipboardSyncMode(_ mode: String) {
        clipboardSyncMode = mode
        updateClipboardSyncButton()
        rebuildClipboardSyncMenu()
    }

    func setCaptureSystemKeys(_ enabled: Bool) {
        captureSystemKeysEnabled = enabled
        updateCaptureKeysButton()
    }

    func setQueuedFileCount(_ count: Int) {
        queuedFileCount = count
        updateQueuedFilesButton()
    }

    func setVMRunning(_ running: Bool) {
        (shutDownItem?.view as? NSButton)?.isEnabled = running
        (terminateItem?.view as? NSButton)?.isEnabled = running
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemID.guestToolsStatus,
            ItemID.portForwards,
            ItemID.sharedFolders,
            ItemID.clipboardSync,
            ItemID.captureKeys,
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
        case ItemID.sharedFolders:
            return makeSharedFoldersItem()
        case ItemID.clipboardSync:
            return makeClipboardSyncItem()
        case ItemID.captureKeys:
            return makeCaptureKeysItem()
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

        let button = NSButton(image: NSImage(systemSymbolName: "app.connected.to.app.below.fill",
            accessibilityDescription: "Guest Tools")!.withSymbolConfiguration(iconConfig)!,
            target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.isBordered = true
        button.isEnabled = false
        item.view = button

        guestToolsItem = item
        updateGuestToolsButton()

        return item
    }

    private func makePortForwardsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.portForwards)
        item.label = "Ports"
        item.paletteLabel = "Port Forwards"
        item.toolTip = "Manage port forwards"

        let button = NSButton(image: NSImage(systemSymbolName: "powerplug", accessibilityDescription: "Port Forwards")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(showPortForwardsMenu(_:)))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        portForwardsItem = item
        rebuildPortForwardsMenu()

        return item
    }

    private func makeSharedFoldersItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.sharedFolders)
        item.label = "Folders"
        item.paletteLabel = "Shared Folders"
        item.toolTip = "Manage shared folders"

        let button = NSButton(image: NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Shared Folders")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(showSharedFoldersMenu(_:)))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        sharedFoldersItem = item
        rebuildSharedFoldersMenu()

        return item
    }

    private func makeClipboardSyncItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.clipboardSync)
        item.label = "Clipboard"
        item.paletteLabel = "Clipboard Sync"
        item.toolTip = "Clipboard sync mode"

        let button = NSButton(image: NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard Sync")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(showClipboardSyncMenu(_:)))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        clipboardSyncItem = item
        updateClipboardSyncButton()
        rebuildClipboardSyncMenu()

        return item
    }

    private func makeCaptureKeysItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.captureKeys)
        item.label = "System Keys"
        item.paletteLabel = "Capture System Keys"

        let button = NSButton(image: NSImage(systemSymbolName: "cursorarrow.square.fill", accessibilityDescription: "Capture System Keys")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(toggleCaptureKeys))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        captureKeysItem = item
        updateCaptureKeysButton()

        return item
    }

    private func makeQueuedFilesItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.queuedFiles)
        item.label = "Files"
        item.paletteLabel = "Queued Files"
        item.toolTip = "Receive files from guest"

        let button = NSButton(image: NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Receive Files")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(receiveQueuedFiles))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        item.isHidden = true
        queuedFilesItem = item

        return item
    }

    private func makeShutDownItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.shutDown)
        item.label = "Shut Down"
        item.paletteLabel = "Shut Down"
        item.toolTip = "Shut down the guest OS gracefully"

        let button = NSButton(image: NSImage(systemSymbolName: "power", accessibilityDescription: "Shut Down")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(shutDownVM))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        shutDownItem = item
        return item
    }

    private func makeTerminateItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.terminate)
        item.label = "Terminate"
        item.paletteLabel = "Terminate"
        item.toolTip = "Force terminate VM immediately"

        let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Terminate")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(terminateVM))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        terminateItem = item
        return item
    }

    // MARK: - Button Updates

    private func updateGuestToolsButton() {
        guard let item = guestToolsItem, let button = item.view as? NSButton else { return }

        let symbolName = "app.connected.to.app.below.fill"
        let color: NSColor = guestToolsConnected ? .systemGreen : .systemGray

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Guest Tools") {
            let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
            let combined = colorConfig.applying(iconConfig)
            button.image = image.withSymbolConfiguration(combined)
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

    private func updateSharedFoldersButton() {
        guard let item = sharedFoldersItem else { return }
        if sharedFolderCount > 0 {
            item.label = "\(sharedFolderCount) Folder\(sharedFolderCount == 1 ? "" : "s")"
        } else {
            item.label = "Folders"
        }
    }

    private func updateClipboardSyncButton() {
        guard let item = clipboardSyncItem, let button = item.view as? NSButton else { return }

        let symbolName: String
        switch clipboardSyncMode {
        case "bidirectional":
            symbolName = "clipboard.fill"
        case "hostToGuest":
            symbolName = "doc.on.clipboard"
        case "guestToHost":
            symbolName = "doc.on.clipboard.fill"
        default:
            symbolName = "clipboard"
        }

        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipboard Sync")?.withSymbolConfiguration(iconConfig)
    }

    private func updateCaptureKeysButton() {
        guard let item = captureKeysItem, let button = item.view as? NSButton else { return }

        let symbolName = captureSystemKeysEnabled ? "cursorarrow.square.fill" : "cursorarrow.square"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Capture System Keys") {
            button.image = image.withSymbolConfiguration(iconConfig)
        }
        item.toolTip = captureSystemKeysEnabled ? "System keys captured by VM" : "System keys handled by macOS"
    }

    private func updateQueuedFilesButton() {
        guard let item = queuedFilesItem else { return }

        let wasZero = previousQueuedFileCount == 0
        previousQueuedFileCount = queuedFileCount

        if queuedFileCount > 0 {
            item.label = "\(queuedFileCount) File\(queuedFileCount == 1 ? "" : "s")"
            item.isHidden = false
            if wasZero {
                delegate?.toolbarDidDetectNewQueuedFiles(self)
            }
        } else {
            item.label = "Files"
            item.isHidden = true
        }
    }

    // MARK: - Menu Builders

    private func rebuildClipboardSyncMenu() {
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

        clipboardSyncMenu = menu
    }

    private func rebuildPortForwardsMenu() {
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

        portForwardsMenu = menu
    }

    private func rebuildSharedFoldersMenu() {
        let menu = NSMenu()

        if !sharedFolderEntries.isEmpty {
            for entry in sharedFolderEntries {
                let title = "\(entry.displayName)\(entry.readOnly ? " (R/O)" : "")"
                let menuItem = NSMenuItem(title: title, action: #selector(revealSharedFolder(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = entry.path
                menuItem.toolTip = entry.path
                menu.addItem(menuItem)
            }
            menu.addItem(NSMenuItem.separator())
        }

        let editItem = NSMenuItem(title: "Edit Shared Folders\u{2026}", action: #selector(editSharedFolders(_:)), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        sharedFoldersMenu = menu
    }

    // MARK: - Actions

    @objc private func showPortForwardsMenu(_ sender: NSButton) {
        portForwardsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func showSharedFoldersMenu(_ sender: NSButton) {
        sharedFoldersMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func showClipboardSyncMenu(_ sender: NSButton) {
        clipboardSyncMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func copyPortForwardURL(_ sender: NSMenuItem) {
        guard let hostPort = sender.representedObject as? UInt16 else { return }
        let urlString = "http://localhost:\(hostPort)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
    }

    @objc private func revealSharedFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc private func editSharedFolders(_ sender: NSMenuItem) {
        let targetWindow = window ?? NSApp.keyWindow
        guard let targetWindow = targetWindow else { return }

        sharedFolderPanel?.close()

        let panel = SharedFolderPanel()
        panel.delegate = self
        panel.setEntries(sharedFolderEntries)
        panel.show(in: targetWindow)
        sharedFolderPanel = panel
    }

    @objc private func setClipboardMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        clipboardSyncMode = mode
        updateClipboardSyncButton()
        rebuildClipboardSyncMenu()
        delegate?.toolbar(self, didSelectClipboardSyncMode: mode)
    }

    @objc private func editPortForwards(_ sender: NSMenuItem) {
        let targetWindow = window ?? NSApp.keyWindow
        guard let targetWindow = targetWindow else {
            delegate?.toolbarDidRequestPortForwardEditor(self)
            return
        }

        portForwardPanel?.close()

        let panel = PortForwardPanel()
        panel.delegate = self
        panel.setEntries(portForwardEntries)
        panel.show(in: targetWindow)
        portForwardPanel = panel
    }

    @objc private func toggleCaptureKeys() {
        captureSystemKeysEnabled.toggle()
        updateCaptureKeysButton()
        delegate?.toolbar(self, didToggleCaptureSystemKeys: captureSystemKeysEnabled)
    }

    @objc private func receiveQueuedFiles() {
        showQueuedFilesPopover()
    }

    func setQueuedFileNames(_ names: [String]) {
        queuedFileNames = names
        queuedFilesPanel?.setFileNames(names)
    }

    func showQueuedFilesPopoverIfNeeded() {
        guard queuedFileCount > 0, queuedFilesPanel == nil else { return }
        showQueuedFilesPopover()
    }

    func showQueuedFilesPopover() {
        guard let button = queuedFilesItem?.view else { return }

        queuedFilesPanel?.close()

        let panel = QueuedFilesPanel()
        panel.delegate = self
        panel.setFileNames(queuedFileNames)
        panel.onClose = { [weak self] in
            guard let self = self else { return }
            self.queuedFilesPanel = nil
            self.delegate?.toolbarQueuedFilesPanelDidClose(self)
        }
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        queuedFilesPanel = panel
    }

    @objc private func shutDownVM() {
        delegate?.toolbarDidRequestShutDown(self)
    }

    @objc private func terminateVM() {
        delegate?.toolbarDidRequestTerminate(self)
    }

    // MARK: - PortForwardPanelDelegate

    func portForwardPanel(_ panel: PortForwardPanel, didAddForward hostPort: UInt16, guestPort: UInt16) {
        if let error = delegate?.toolbar(self, didAddPortForward: hostPort, guestPort: guestPort) {
            portForwardPanel?.showError(error)
        }
    }

    func portForwardPanel(_ panel: PortForwardPanel, didRemoveForwardWithHostPort hostPort: UInt16) {
        delegate?.toolbar(self, didRemovePortForwardWithHostPort: hostPort)
    }

    // MARK: - SharedFolderPanelDelegate

    func sharedFolderPanel(_ panel: SharedFolderPanel, didAddFolder path: String, readOnly: Bool) {
        delegate?.toolbar(self, didAddSharedFolder: path, readOnly: readOnly)
    }

    func sharedFolderPanel(_ panel: SharedFolderPanel, didRemoveFolderWithID id: UUID) {
        delegate?.toolbar(self, didRemoveSharedFolderWithID: id)
    }

    // MARK: - QueuedFilesPanelDelegate

    func queuedFilesPanelDidAllow(_ panel: QueuedFilesPanel) {
        panel.close()
        queuedFilesPanel = nil
        queuedFileNames = []
        delegate?.toolbarDidRequestReceiveFiles(self)
    }

    func queuedFilesPanelDidDeny(_ panel: QueuedFilesPanel) {
        panel.close()
        queuedFilesPanel = nil
        queuedFileNames = []
        delegate?.toolbarDidRequestDenyFiles(self)
    }
}

// MARK: - Delegate Protocol

protocol HelperToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: HelperToolbar, didSelectClipboardSyncMode mode: String)
    func toolbar(_ toolbar: HelperToolbar, didToggleCaptureSystemKeys enabled: Bool)
    @discardableResult
    func toolbar(_ toolbar: HelperToolbar, didAddPortForward hostPort: UInt16, guestPort: UInt16) -> String?
    func toolbar(_ toolbar: HelperToolbar, didRemovePortForwardWithHostPort hostPort: UInt16)
    func toolbar(_ toolbar: HelperToolbar, didAddSharedFolder path: String, readOnly: Bool)
    func toolbar(_ toolbar: HelperToolbar, didRemoveSharedFolderWithID id: UUID)
    func toolbarDidRequestPortForwardEditor(_ toolbar: HelperToolbar)
    func toolbarDidRequestReceiveFiles(_ toolbar: HelperToolbar)
    func toolbarDidRequestDenyFiles(_ toolbar: HelperToolbar)
    func toolbarDidDetectNewQueuedFiles(_ toolbar: HelperToolbar)
    func toolbarDidRequestShutDown(_ toolbar: HelperToolbar)
    func toolbarDidRequestTerminate(_ toolbar: HelperToolbar)
    func toolbarQueuedFilesPanelDidClose(_ toolbar: HelperToolbar)
}
