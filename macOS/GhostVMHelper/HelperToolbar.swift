import AppKit

// MARK: - Shared Folder Menu Helpers

/// Custom click gesture that carries the folder path for reveal-in-Finder.
private final class SharedFolderClickGesture: NSClickGestureRecognizer {
    var folderPath: String = ""
    weak var owningMenu: NSMenu?
}

/// Container view for custom menu items that draws the system selection highlight on hover.
private final class HighlightingMenuItemView: NSView {
    var onHighlightChanged: ((Bool) -> Void)?
    private var isHighlighted = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHighlighted = true
        onHighlightChanged?(true)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHighlighted = false
        onHighlightChanged?(false)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4)
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

/// NSToolbar implementation for the VM helper window.
/// Provides quick access to VM status and controls.
final class HelperToolbar: NSObject, NSToolbarDelegate, NSMenuDelegate, PortForwardPanelDelegate, SharedFolderPanelDelegate, QueuedFilesPanelDelegate, ClipboardPermissionPanelDelegate, URLPermissionPanelDelegate, PortForwardPermissionPanelDelegate, PortForwardNotificationPanelDelegate, IconChooserPanelDelegate {

    // MARK: - Toolbar Item Identifiers

    private enum ItemID {
        static let guestToolsStatus = NSToolbarItem.Identifier("guestToolsStatus")
        static let portForwards = NSToolbarItem.Identifier("portForwards")
        static let sharedFolders = NSToolbarItem.Identifier("sharedFolders")
        static let clipboardSync = NSToolbarItem.Identifier("clipboardSync")
        static let iconChooser = NSToolbarItem.Identifier("iconChooser")
        static let captureKeys = NSToolbarItem.Identifier("captureKeys")
        static let captureCommands = NSToolbarItem.Identifier("captureCommands")
        static let queuedFiles = NSToolbarItem.Identifier("queuedFiles")
        static let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace
        static let shutDown = NSToolbarItem.Identifier("shutDown")
        static let terminate = NSToolbarItem.Identifier("terminate")
    }

    // MARK: - Properties

    weak var delegate: HelperToolbarDelegate?

    private let toolbar: NSToolbar
    private var guestToolsStatus: GuestToolsStatus = .connecting
    private var portForwardCount = 0
    private var sharedFolderCount = 0
    private var clipboardSyncMode = "disabled"
    private var captureSystemKeysEnabled = true
    private var captureQuitEnabled = false
    private var captureHideEnabled = false
    private var openURLsAutomaticallyEnabled = false
    private var autoPortMapEnabled = false
    private var queuedFileCount = 0
    private var queuedFileNames: [String] = []
    private var vmRunning = true
    private var shutDownEnabled = true

    private var guestToolsItem: NSToolbarItem?
    private weak var guestToolsDot: NSView?
    private weak var guestToolsLabel: NSTextField?
    private var iconChooserItem: NSToolbarItem?
    private var portForwardsItem: NSToolbarItem?
    private var sharedFoldersItem: NSMenuToolbarItem?
    private var clipboardSyncItem: NSToolbarItem?
    private var captureKeysItem: NSToolbarItem?
    private var captureCommandsItem: NSMenuToolbarItem?
    private var queuedFilesItem: NSToolbarItem?
    private var shutDownItem: NSToolbarItem?
    private var terminateItem: NSToolbarItem?

    private var sharedFoldersMenu = NSMenu()
    private var captureCommandsMenu = NSMenu()

    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)

    private weak var window: NSWindow?
    private var portForwardPanel: PortForwardPanel?
    private var portForwardEntries: [PortForwardEntry] = []
    private var sharedFolderPanel: SharedFolderPanel?
    private var sharedFolderEntries: [SharedFolderEntry] = []
    private var queuedFilesPanel: QueuedFilesPanel?
    private var clipboardPermissionPanel: ClipboardPermissionPanel?
    private var urlPermissionPanel: URLPermissionPanel?
    private var portForwardPermissionPanel: PortForwardPermissionPanel?
    private var portForwardNotificationPanel: PortForwardNotificationPanel?
    private var iconChooserPanel: IconChooserPanel?
    private var guestToolsInfoPanel: GuestToolsInfoPanel?
    private var previousQueuedFileCount = 0
    private var blockedPortDescriptions: [String] = []

    // Status text animation state
    private var statusAnimationTimer: Timer?
    private var statusDisappearTimer: Timer?
    private var statusAnimationTarget: String = ""
    private var statusAnimationIndex: Int = 0
    private var lastAnimatedStatus: GuestToolsStatus?

    // MARK: - Initialization

    override init() {
        toolbar = NSToolbar(identifier: "HelperToolbar")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
    }

    func attach(to window: NSWindow) {
        self.window = window
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    // MARK: - State Updates

    func setGuestToolsStatus(_ status: GuestToolsStatus) {
        let wasNotFound = guestToolsStatus == .notFound
        guestToolsStatus = status
        updateGuestToolsButton()

        if status == .notFound && !wasNotFound {
            // Auto-show popover on first transition to notFound
            showGuestToolsInfoPopover()
        } else if status != .notFound {
            // Close popover when status recovers
            guestToolsInfoPanel?.close()
            guestToolsInfoPanel = nil
        }
    }

    func setPortForwardCount(_ count: Int) {
        portForwardCount = count
        updatePortForwardsButton()
    }

    func setPortForwardEntries(_ entries: [PortForwardEntry]) {
        portForwardEntries = entries
        portForwardCount = entries.count
        updatePortForwardsButton()
        portForwardPermissionPanel?.setEntries(entries)
        portForwardPanel?.setEntries(entries)
    }

    func setSharedFolderEntries(_ entries: [SharedFolderEntry]) {
        sharedFolderEntries = entries
        sharedFolderCount = entries.count
        updateSharedFoldersButton()
        rebuildSharedFoldersMenu()
        rebuildCaptureCommandsMenu()
        sharedFolderPanel?.setEntries(entries)
    }

    func setClipboardSyncMode(_ mode: String) {
        clipboardSyncMode = mode
        updateClipboardSyncButton()
        rebuildCaptureCommandsMenu()
    }

    func setCaptureSystemKeys(_ enabled: Bool) {
        captureSystemKeysEnabled = enabled
        updateCaptureKeysButton()
    }

    func setCaptureQuit(_ enabled: Bool) {
        captureQuitEnabled = enabled
        rebuildCaptureCommandsMenu()
    }

    func setCaptureHide(_ enabled: Bool) {
        captureHideEnabled = enabled
        rebuildCaptureCommandsMenu()
    }

    func setOpenURLsAutomatically(_ enabled: Bool) {
        openURLsAutomaticallyEnabled = enabled
        rebuildCaptureCommandsMenu()
    }

    func setAutoPortMapEnabled(_ enabled: Bool) {
        autoPortMapEnabled = enabled
        updatePortForwardsButton()
        portForwardPermissionPanel?.setAutoPortMapEnabled(enabled)
    }

    func setBlockedPortDescriptions(_ ports: [String]) {
        blockedPortDescriptions = ports
        portForwardPermissionPanel?.setBlockedPortDescriptions(ports)
    }

    func setQueuedFileCount(_ count: Int) {
        queuedFileCount = count
        updateQueuedFilesButton()
        rebuildCaptureCommandsMenu()
    }

    func setVMRunning(_ running: Bool) {
        vmRunning = running
        (shutDownItem?.view as? NSButton)?.isEnabled = running
        (terminateItem?.view as? NSButton)?.isEnabled = running
        rebuildCaptureCommandsMenu()
    }

    func setShutDownEnabled(_ enabled: Bool) {
        shutDownEnabled = enabled
        (shutDownItem?.view as? NSButton)?.isEnabled = enabled
        rebuildCaptureCommandsMenu()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemID.guestToolsStatus,
            ItemID.iconChooser,
            ItemID.portForwards,
            ItemID.sharedFolders,
            ItemID.clipboardSync,
            ItemID.captureKeys,
            ItemID.captureCommands,
            ItemID.queuedFiles,
            ItemID.flexibleSpace,
            ItemID.shutDown,
            ItemID.terminate
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ItemID.guestToolsStatus,
            ItemID.iconChooser,
            ItemID.portForwards,
            ItemID.sharedFolders,
            ItemID.clipboardSync,
            ItemID.captureKeys,
            ItemID.captureCommands,
            ItemID.queuedFiles,
            ItemID.shutDown,
            ItemID.terminate,
            .space,
            .flexibleSpace
        ]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ItemID.guestToolsStatus:
            return makeGuestToolsItem()
        case ItemID.iconChooser:
            return makeIconChooserItem()
        case ItemID.portForwards:
            return makePortForwardsItem()
        case ItemID.sharedFolders:
            return makeSharedFoldersItem()
        case ItemID.clipboardSync:
            return makeClipboardSyncItem()
        case ItemID.captureKeys:
            return makeCaptureKeysItem()
        case ItemID.captureCommands:
            return makeCaptureCommandsItem()
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

        // Use frame-based layout to avoid triggering constraint updates during
        // toolbar relayout (AppKit's _postWindowNeedsUpdateConstraints crashes
        // if constraints are added inside a display cycle — seen with Vision Pro
        // virtual displays).
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 16, height: 22))
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(guestToolsClicked)

        // Status dot (8×8 colored circle)
        let dot = NSView(frame: NSRect(x: 4, y: 7, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        button.addSubview(dot)
        guestToolsDot = dot

        // Status label (starts zero-width; resizeGuestToolsButton adjusts)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.frame = NSRect(x: 18, y: 1, width: 0, height: 20)
        button.addSubview(label)
        guestToolsLabel = label

        item.view = button

        guestToolsItem = item
        updateGuestToolsButton()

        return item
    }

    private func makeIconChooserItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.iconChooser)
        item.label = "Icon"
        item.paletteLabel = "Change Icon"
        item.toolTip = "Change VM icon"
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

        let button = NSButton(image: NSImage(systemSymbolName: "photo", accessibilityDescription: "Icon")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(iconChooserClicked))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        iconChooserItem = item
        return item
    }

    private func makePortForwardsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.portForwards)
        item.label = "Ports"
        item.paletteLabel = "Port Forwards"
        item.toolTip = "Manage port forwards"
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

        let button = NSButton(image: portForwardsIcon()!, target: self, action: #selector(portForwardsClicked))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        portForwardsItem = item
        updatePortForwardsButton()

        return item
    }

    private func makeSharedFoldersItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: ItemID.sharedFolders)
        item.label = "Folders"
        item.paletteLabel = "Shared Folders"
        item.toolTip = "Manage shared folders"
        item.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "Shared Folders")?.withSymbolConfiguration(iconConfig)
        item.showsIndicator = false
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

        sharedFoldersItem = item
        rebuildSharedFoldersMenu()

        return item
    }

    private func makeClipboardSyncItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.clipboardSync)
        item.label = "Clipboard"
        item.paletteLabel = "Clipboard Sync"
        item.toolTip = "Toggle clipboard sync"
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

        let button = NSButton(image: NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipboard Sync")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(toggleClipboardSync))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        clipboardSyncItem = item
        updateClipboardSyncButton()

        return item
    }

    private func makeCaptureKeysItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.captureKeys)
        item.label = "Capture Inputs"
        item.paletteLabel = "Capture Inputs"
        item.toolTip = "Toggle input capture"
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

        let button = NSButton(image: NSImage(systemSymbolName: "cursorarrow.square.fill", accessibilityDescription: "Capture Inputs")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(toggleCaptureSystemKeys))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        captureKeysItem = item
        updateCaptureKeysButton()

        return item
    }

    private func makeCaptureCommandsItem() -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: ItemID.captureCommands)
        item.label = "Menu"
        item.paletteLabel = "VM Menu"
        item.toolTip = "VM actions and settings"
        item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "VM Menu")?.withSymbolConfiguration(iconConfig)
        item.showsIndicator = false
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

        captureCommandsMenu.delegate = self
        item.menu = captureCommandsMenu
        captureCommandsItem = item
        rebuildCaptureCommandsMenu()

        return item
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === captureCommandsMenu {
            rebuildCaptureCommandsMenu()
        }
    }

    private func makeQueuedFilesItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: ItemID.queuedFiles)
        item.label = "Files"
        item.paletteLabel = "Queued Files"
        item.toolTip = "Receive files from guest"
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

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
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

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
        item.minSize = NSSize(width: 36, height: 32)
        item.maxSize = NSSize(width: 36, height: 32)

        let button = NSButton(image: NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Terminate")!.withSymbolConfiguration(iconConfig)!, target: self, action: #selector(terminateVM))
        button.bezelStyle = .toolbar
        button.isBordered = true
        item.view = button

        terminateItem = item
        return item
    }

    // MARK: - Button Updates

    private func updateGuestToolsButton() {
        guard let item = guestToolsItem else { return }
        guard let dot = guestToolsDot, let label = guestToolsLabel else { return }

        let shouldAnimate = lastAnimatedStatus != guestToolsStatus
        lastAnimatedStatus = guestToolsStatus

        switch guestToolsStatus {
        case .connecting:
            dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            label.textColor = .secondaryLabelColor
            item.toolTip = "GhostTools is connecting"
            if shouldAnimate {
                animateStatusText(to: "Connecting\u{2026}", disappearAfter: nil)
            }
        case .connected:
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            label.textColor = .labelColor
            item.toolTip = "GhostTools is connected"
            if shouldAnimate {
                animateStatusText(to: "Guest Tools Connected", disappearAfter: 1.5)
            }
        case .notFound:
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            label.textColor = .secondaryLabelColor
            item.toolTip = "GhostTools not found — click for help"
            if shouldAnimate {
                animateStatusText(to: "Not Found", disappearAfter: nil)
            }
        }
    }

    private func updatePortForwardsButton() {
        guard let item = portForwardsItem else { return }
        if portForwardCount > 0 {
            item.label = "\(portForwardCount) Port\(portForwardCount == 1 ? "" : "s")"
        } else {
            item.label = "Ports"
        }
        (item.view as? NSButton)?.image = portForwardsIcon()
    }

    private func updateSharedFoldersButton() {
        guard let item = sharedFoldersItem else { return }
        if sharedFolderCount > 0 {
            item.label = "\(sharedFolderCount) Folder\(sharedFolderCount == 1 ? "" : "s")"
        } else {
            item.label = "Folders"
        }
        let symbolName = sharedFolderCount > 0 ? "folder.fill.badge.gearshape" : "folder.badge.gearshape"
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Shared Folders")?.withSymbolConfiguration(iconConfig)
    }

    private func updateClipboardSyncButton() {
        guard let item = clipboardSyncItem, let button = item.view as? NSButton else { return }

        let enabled = clipboardSyncMode != "disabled"
        let symbolName = enabled ? "clipboard.fill" : "clipboard"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipboard Sync")?.withSymbolConfiguration(iconConfig)
        item.toolTip = enabled ? "Clipboard sync enabled" : "Clipboard sync disabled"
    }

    private func updateCaptureKeysButton() {
        guard let item = captureKeysItem, let button = item.view as? NSButton else { return }

        let symbolName = captureSystemKeysEnabled ? "cursorarrow.square.fill" : "cursorarrow.square"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Capture Inputs")?.withSymbolConfiguration(iconConfig)
        item.toolTip = captureSystemKeysEnabled ? "Inputs captured by VM" : "Inputs handled by macOS"

        rebuildCaptureCommandsMenu()
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

    // MARK: - Status Text Animation

    private func cancelStatusAnimation() {
        statusAnimationTimer?.invalidate()
        statusAnimationTimer = nil
        statusDisappearTimer?.invalidate()
        statusDisappearTimer = nil
    }

    private func animateStatusText(to target: String, disappearAfter: TimeInterval?) {
        cancelStatusAnimation()
        statusAnimationTarget = target
        statusAnimationIndex = 0

        statusAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] timer in
            guard let self = self, let label = self.statusLabel() else { timer.invalidate(); return }
            self.statusAnimationIndex += 1
            label.stringValue = String(self.statusAnimationTarget.suffix(self.statusAnimationIndex))
            self.resizeGuestToolsButton()

            if self.statusAnimationIndex >= self.statusAnimationTarget.count {
                timer.invalidate()
                self.statusAnimationTimer = nil

                if let delay = disappearAfter {
                    self.statusDisappearTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                        self?.statusDisappearTimer = nil
                        self?.animateStatusDisappear()
                    }
                }
            }
        }
    }

    private func animateStatusDisappear() {
        statusAnimationTimer?.invalidate()
        statusAnimationTimer = nil

        statusAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] timer in
            guard let self = self, let label = self.statusLabel() else { timer.invalidate(); return }
            let current = label.stringValue
            if current.isEmpty {
                timer.invalidate()
                self.statusAnimationTimer = nil
                return
            }
            label.stringValue = String(current.dropLast())
            self.resizeGuestToolsButton()
        }
    }

    /// Helper to find the status label inside the guest tools toolbar item.
    private func statusLabel() -> NSTextField? {
        return guestToolsLabel
    }

    /// Resize the guest tools button to fit the dot + current label text.
    private func resizeGuestToolsButton() {
        guard let button = guestToolsItem?.view,
              let label = guestToolsLabel else { return }
        label.sizeToFit()
        let width: CGFloat
        if label.stringValue.isEmpty {
            width = 16  // 4 padding + 8 dot + 4 padding
        } else {
            width = 18 + label.frame.width + 4  // dot(4+8) + spacing(6) + text + padding(4)
        }
        button.setFrameSize(NSSize(width: width, height: button.frame.height))
    }

    // MARK: - Menu Builders


    private func rebuildCaptureCommandsMenu() {
        captureCommandsMenu.removeAllItems()

        // --- Clipboard Sync submenu ---
        let clipboardSubmenu = NSMenu()
        let clipModes: [(title: String, mode: String)] = [
            ("Off", "disabled"),
            ("Host \u{2192} Guest", "host-to-guest"),
            ("Guest \u{2192} Host", "guest-to-host"),
            ("Bidirectional", "bidirectional"),
        ]
        for entry in clipModes {
            let item = NSMenuItem(title: entry.title, action: #selector(selectClipboardSyncMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.mode
            item.state = clipboardSyncMode == entry.mode ? .on : .off
            clipboardSubmenu.addItem(item)
        }
        let clipboardItem = NSMenuItem(title: "Clipboard Sync", action: nil, keyEquivalent: "")
        clipboardItem.submenu = clipboardSubmenu
        captureCommandsMenu.addItem(clipboardItem)

        captureCommandsMenu.addItem(NSMenuItem.separator())

        // --- Port Forwards ---
        let portsItem = NSMenuItem(title: "Port Forwards\u{2026}", action: #selector(portForwardsFromMenu), keyEquivalent: "")
        portsItem.target = self
        captureCommandsMenu.addItem(portsItem)

        // --- Shared Folders submenu ---
        let foldersSubmenu = NSMenu()
        for entry in sharedFolderEntries {
            let folderItem = NSMenuItem(title: "\(entry.displayName)\(entry.readOnly ? " (R/O)" : "")", action: #selector(revealSharedFolderFromMenu(_:)), keyEquivalent: "")
            folderItem.target = self
            folderItem.representedObject = entry.path
            folderItem.toolTip = entry.path
            foldersSubmenu.addItem(folderItem)
        }
        if !sharedFolderEntries.isEmpty {
            foldersSubmenu.addItem(NSMenuItem.separator())
        }
        let editFoldersItem = NSMenuItem(title: "Edit Shared Folders\u{2026}", action: #selector(editSharedFoldersFromMenu), keyEquivalent: "")
        editFoldersItem.target = self
        foldersSubmenu.addItem(editFoldersItem)

        let foldersItem = NSMenuItem(title: "Shared Folders", action: nil, keyEquivalent: "")
        foldersItem.submenu = foldersSubmenu
        captureCommandsMenu.addItem(foldersItem)

        captureCommandsMenu.addItem(NSMenuItem.separator())

        // --- Input behavior (existing items) ---
        let urlItem = NSMenuItem(title: "Open URLs Automatically", action: #selector(toggleOpenURLsAutomatically), keyEquivalent: "")
        urlItem.target = self
        urlItem.state = openURLsAutomaticallyEnabled ? .on : .off
        captureCommandsMenu.addItem(urlItem)

        let captureItem = NSMenuItem(title: "Capture All Inputs", action: #selector(toggleCaptureSystemKeysFromMenu), keyEquivalent: "")
        captureItem.target = self
        captureItem.state = captureSystemKeysEnabled ? .on : .off
        captureCommandsMenu.addItem(captureItem)

        let shortcutsSubmenu = NSMenu()
        let hideItem = NSMenuItem(title: "Hide \u{2318}H", action: #selector(toggleCaptureHide), keyEquivalent: "")
        hideItem.target = self
        hideItem.state = captureHideEnabled ? .on : .off
        shortcutsSubmenu.addItem(hideItem)
        let quitItem = NSMenuItem(title: "Quit \u{2318}Q", action: #selector(toggleCaptureQuit), keyEquivalent: "")
        quitItem.target = self
        quitItem.state = captureQuitEnabled ? .on : .off
        shortcutsSubmenu.addItem(quitItem)
        let shortcutsItem = NSMenuItem(title: "Intercept Shortcuts", action: nil, keyEquivalent: "")
        shortcutsItem.submenu = shortcutsSubmenu
        captureCommandsMenu.addItem(shortcutsItem)

        captureCommandsMenu.addItem(NSMenuItem.separator())

        // --- Actions ---
        if queuedFileCount > 0 {
            let filesTitle = "Receive \(queuedFileCount) File\(queuedFileCount == 1 ? "" : "s")"
            let filesItem = NSMenuItem(title: filesTitle, action: #selector(receiveQueuedFiles), keyEquivalent: "")
            filesItem.target = self
            captureCommandsMenu.addItem(filesItem)
        }

        let iconItem = NSMenuItem(title: "Change VM Icon\u{2026}", action: #selector(iconChooserFromMenu), keyEquivalent: "")
        iconItem.target = self
        captureCommandsMenu.addItem(iconItem)

        captureCommandsMenu.addItem(NSMenuItem.separator())

        // --- VM lifecycle ---
        let shutItem = NSMenuItem(title: "Shut Down", action: #selector(shutDownVM), keyEquivalent: "")
        shutItem.target = self
        shutItem.isEnabled = vmRunning && shutDownEnabled
        captureCommandsMenu.addItem(shutItem)

        let termItem = NSMenuItem(title: "Terminate", action: #selector(terminateVM), keyEquivalent: "")
        termItem.target = self
        termItem.isEnabled = vmRunning
        captureCommandsMenu.addItem(termItem)
    }

    private func portForwardsIcon() -> NSImage? {
        let symbolName = autoPortMapEnabled ? "powerplug.fill" : "powerplug"
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Port Forwards")?.withSymbolConfiguration(iconConfig)
    }

    private func rebuildSharedFoldersMenu() {
        let menu = NSMenu()

        if !sharedFolderEntries.isEmpty {
            for entry in sharedFolderEntries {
                let menuItem = NSMenuItem()
                menuItem.view = makeSharedFolderMenuItemView(for: entry, in: menu)
                menu.addItem(menuItem)
            }
            menu.addItem(NSMenuItem.separator())
        }

        let editItem = NSMenuItem(title: "Edit Shared Folders\u{2026}", action: #selector(editSharedFolders(_:)), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        sharedFoldersMenu = menu
        sharedFoldersItem?.menu = menu
    }

    private func makeSharedFolderMenuItemView(for entry: SharedFolderEntry, in menu: NSMenu) -> NSView {
        let wrapper = HighlightingMenuItemView()

        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 10)

        // Folder icon
        let iconView = NSImageView()
        let folderImage = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
        iconView.image = folderImage
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
        container.addArrangedSubview(iconView)

        // Folder name (clickable to reveal in Finder)
        let label = NSTextField(labelWithString: "\(entry.displayName)\(entry.readOnly ? " (R/O)" : "")")
        label.font = .menuFont(ofSize: 0)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = entry.path
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.addArrangedSubview(label)

        // Click gesture on the row to reveal in Finder
        let click = SharedFolderClickGesture(target: self, action: #selector(sharedFolderRowClicked(_:)))
        click.folderPath = entry.path
        click.owningMenu = menu
        wrapper.addGestureRecognizer(click)

        // Register views for highlight color switching
        wrapper.onHighlightChanged = { highlighted in
            let tint: NSColor = highlighted ? .white : .secondaryLabelColor
            let textColor: NSColor = highlighted ? .white : .labelColor
            iconView.contentTintColor = tint
            label.textColor = textColor
        }

        // Layout: embed container in wrapper
        wrapper.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            wrapper.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        return wrapper
    }

    // MARK: - Actions

    @objc private func guestToolsClicked() {
        guard guestToolsStatus == .notFound else { return }
        showGuestToolsInfoPopover()
    }

    private func showGuestToolsInfoPopover() {
        guard let view = guestToolsItem?.view else { return }

        guestToolsInfoPanel?.close()

        let panel = GuestToolsInfoPanel()
        panel.onClose = { [weak self] in
            self?.guestToolsInfoPanel = nil
        }
        panel.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        guestToolsInfoPanel = panel
    }

    @objc private func iconChooserClicked() {
        if iconChooserPanel?.isShown == true {
            iconChooserPanel?.close()
        } else {
            delegate?.toolbarDidRequestIconChooser(self)
        }
    }

    @objc private func toggleClipboardSync() {
        let newMode = (clipboardSyncMode == "disabled") ? "bidirectional" : "disabled"
        clipboardSyncMode = newMode
        updateClipboardSyncButton()
        delegate?.toolbar(self, didSelectClipboardSyncMode: newMode)
    }

    @objc private func portForwardsClicked() {
        // Close notification panel if shown
        if portForwardNotificationPanel?.isShown == true {
            portForwardNotificationPanel?.close()
            portForwardNotificationPanel = nil
        }

        // Toggle management panel
        if portForwardPermissionPanel?.isShown == true {
            portForwardPermissionPanel?.close()
        } else {
            showPortForwardPermissionPopover()
        }
    }

    @objc private func revealSharedFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc private func sharedFolderRowClicked(_ sender: NSClickGestureRecognizer) {
        guard let gesture = sender as? SharedFolderClickGesture else { return }
        gesture.owningMenu?.cancelTracking()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: gesture.folderPath)
    }

    @objc private func editSharedFolders(_ sender: NSMenuItem) {
        showSharedFolderEditor()
    }

    func showSharedFolderEditor() {
        let targetWindow = window ?? NSApp.keyWindow
        guard let targetWindow = targetWindow else { return }

        sharedFolderPanel?.close()

        let panel = SharedFolderPanel()
        panel.delegate = self
        panel.setEntries(sharedFolderEntries)
        panel.show(in: targetWindow)
        sharedFolderPanel = panel
    }


    private func editPortForwards() {
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

    @objc private func toggleCaptureSystemKeys() {
        captureSystemKeysEnabled.toggle()
        updateCaptureKeysButton()
        delegate?.toolbar(self, didToggleCaptureSystemKeys: captureSystemKeysEnabled)
    }

    @objc private func toggleCaptureQuit() {
        captureQuitEnabled.toggle()
        rebuildCaptureCommandsMenu()
        delegate?.toolbar(self, didToggleCaptureQuit: captureQuitEnabled)
    }

    @objc private func toggleCaptureHide() {
        captureHideEnabled.toggle()
        rebuildCaptureCommandsMenu()
        delegate?.toolbar(self, didToggleCaptureHide: captureHideEnabled)
    }

    @objc private func toggleOpenURLsAutomatically() {
        openURLsAutomaticallyEnabled.toggle()
        rebuildCaptureCommandsMenu()
        delegate?.toolbar(self, didToggleOpenURLsAutomatically: openURLsAutomaticallyEnabled)
    }

    @objc private func toggleCaptureSystemKeysFromMenu() {
        captureSystemKeysEnabled.toggle()
        updateCaptureKeysButton()
        rebuildCaptureCommandsMenu()
        delegate?.toolbar(self, didToggleCaptureSystemKeys: captureSystemKeysEnabled)
    }

    @objc private func selectClipboardSyncMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        clipboardSyncMode = mode
        updateClipboardSyncButton()
        rebuildCaptureCommandsMenu()
        delegate?.toolbar(self, didSelectClipboardSyncMode: mode)
    }

    @objc private func portForwardsFromMenu() {
        portForwardsClicked()
    }

    @objc private func revealSharedFolderFromMenu(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc private func editSharedFoldersFromMenu() {
        showSharedFolderEditor()
    }

    @objc private func iconChooserFromMenu() {
        delegate?.toolbarDidRequestIconChooser(self)
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
        queuedFilesPanel?.close()

        let panel = QueuedFilesPanel()
        panel.delegate = self
        panel.setFileNames(queuedFileNames)
        panel.onClose = { [weak self] in
            guard let self = self else { return }
            self.queuedFilesPanel = nil
            self.delegate?.toolbarQueuedFilesPanelDidClose(self)
        }

        if let button = queuedFilesItem?.view, button.window != nil {
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let window = self.window {
            panel.showAsSheet(in: window)
        } else {
            return
        }
        queuedFilesPanel = panel
    }

    func showIconChooserPopover(bundleURL: URL) {
        iconChooserPanel?.close()

        let panel = IconChooserPanel()
        panel.delegate = self
        panel.onClose = { [weak self] in
            self?.iconChooserPanel = nil
        }

        if let button = iconChooserItem?.view, button.window != nil {
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY, bundleURL: bundleURL)
        } else if let window = self.window {
            panel.showAsSheet(in: window, bundleURL: bundleURL)
        } else {
            return
        }
        iconChooserPanel = panel
    }

    func showClipboardPermissionPopover() {
        guard let button = clipboardSyncItem?.view else { return }

        clipboardPermissionPanel?.close()

        let panel = ClipboardPermissionPanel()
        panel.delegate = self
        panel.onClose = { [weak self] in
            guard let self = self else { return }
            self.clipboardPermissionPanel = nil
            self.delegate?.toolbarClipboardPermissionPanelDidClose(self)
        }
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        clipboardPermissionPanel = panel
    }

    func closeClipboardPermissionPopover() {
        clipboardPermissionPanel?.close()
        clipboardPermissionPanel = nil
    }

    var isClipboardPermissionPopoverShown: Bool {
        clipboardPermissionPanel?.isShown ?? false
    }

    func showURLPermissionPopover() {
        guard let view = guestToolsItem?.view else { return }

        urlPermissionPanel?.close()

        let panel = URLPermissionPanel()
        panel.delegate = self
        panel.onClose = { [weak self] in
            guard let self = self else { return }
            self.urlPermissionPanel = nil
            self.delegate?.toolbarURLPermissionPanelDidClose(self)
        }
        panel.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        urlPermissionPanel = panel
    }

    func closeURLPermissionPopover() {
        urlPermissionPanel?.close()
        urlPermissionPanel = nil
    }

    var isURLPermissionPopoverShown: Bool {
        urlPermissionPanel?.isShown ?? false
    }

    func setURLPermissionURLs(_ urls: [String]) {
        urlPermissionPanel?.setURLs(urls)
    }

    func showPortForwardPermissionPopover() {
        portForwardPermissionPanel?.close()

        let panel = PortForwardPermissionPanel()
        panel.delegate = self
        panel.onClose = { [weak self] in
            guard let self = self else { return }
            self.portForwardPermissionPanel = nil
            self.delegate?.toolbarPortForwardPermissionPanelDidClose(self)
        }

        if let button = portForwardsItem?.view, button.window != nil {
            panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let window = self.window {
            panel.showAsSheet(in: window)
        } else {
            return
        }
        panel.setEntries(portForwardEntries)
        panel.setAutoPortMapEnabled(autoPortMapEnabled)
        panel.setBlockedPortDescriptions(blockedPortDescriptions)
        portForwardPermissionPanel = panel
    }

    func closePortForwardPermissionPopover() {
        portForwardNotificationPanel?.close()
        portForwardNotificationPanel = nil
    }

    var isPortForwardPermissionPopoverShown: Bool {
        portForwardNotificationPanel?.isShown ?? false
    }

    func setPortForwardPermissionMappings(_ mappings: [(guestPort: UInt16, hostPort: UInt16, processName: String?)]) {
        portForwardNotificationPanel?.setPortMappings(mappings)
    }

    func addPortForwardPermissionMappings(_ mappings: [(guestPort: UInt16, hostPort: UInt16, processName: String?)]) {
        portForwardNotificationPanel?.addPortMappings(mappings)
    }

    func showPortForwardNotificationPopover() {
        guard let button = portForwardsItem?.view else { return }

        portForwardNotificationPanel?.close()

        let panel = PortForwardNotificationPanel()
        panel.delegate = self
        panel.onClose = { [weak self] in
            guard let self = self else { return }
            self.portForwardNotificationPanel = nil
            self.delegate?.toolbarPortForwardPermissionPanelDidClose(self)
        }
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        portForwardNotificationPanel = panel
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

    func sharedFolderPanel(_ panel: SharedFolderPanel, didSetReadOnly readOnly: Bool, forFolderWithID id: UUID) {
        delegate?.toolbar(self, didSetSharedFolderReadOnly: readOnly, forID: id)
    }

    // MARK: - QueuedFilesPanelDelegate

    func queuedFilesPanelDidAllow(_ panel: QueuedFilesPanel) {
        NSLog("HelperToolbar: Save clicked, delegate=%@", delegate != nil ? "present" : "NIL")
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

    // MARK: - ClipboardPermissionPanelDelegate

    func clipboardPermissionPanelDidDeny(_ panel: ClipboardPermissionPanel) {
        panel.close()
        clipboardPermissionPanel = nil
        delegate?.toolbarClipboardPermissionDidDeny(self)
    }

    func clipboardPermissionPanelDidAllowOnce(_ panel: ClipboardPermissionPanel) {
        panel.close()
        clipboardPermissionPanel = nil
        delegate?.toolbarClipboardPermissionDidAllowOnce(self)
    }

    func clipboardPermissionPanelDidAlwaysAllow(_ panel: ClipboardPermissionPanel) {
        panel.close()
        clipboardPermissionPanel = nil
        delegate?.toolbarClipboardPermissionDidAlwaysAllow(self)
    }

    // MARK: - URLPermissionPanelDelegate

    func urlPermissionPanelDidDeny(_ panel: URLPermissionPanel) {
        panel.close()
        urlPermissionPanel = nil
        delegate?.toolbarURLPermissionDidDeny(self)
    }

    func urlPermissionPanelDidAllowOnce(_ panel: URLPermissionPanel) {
        panel.close()
        urlPermissionPanel = nil
        delegate?.toolbarURLPermissionDidAllowOnce(self)
    }

    func urlPermissionPanelDidAlwaysAllow(_ panel: URLPermissionPanel) {
        panel.close()
        urlPermissionPanel = nil
        delegate?.toolbarURLPermissionDidAlwaysAllow(self)
    }

    // MARK: - PortForwardPermissionPanelDelegate

    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didBlockPort guestPort: UInt16) {
        delegate?.toolbar(self, didBlockAutoForwardedPort: guestPort)
    }

    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didRemoveForwardWithHostPort hostPort: UInt16) {
        delegate?.toolbar(self, didRemovePortForwardWithHostPort: hostPort)
    }

    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didToggleAutoPortMap enabled: Bool) {
        autoPortMapEnabled = enabled
        updatePortForwardsButton()
        delegate?.toolbar(self, didToggleAutoPortMap: enabled)
    }

    func portForwardPermissionPanel(_ panel: PortForwardPermissionPanel, didUnblockPort port: UInt16) {
        delegate?.toolbar(self, didUnblockPort: port)
    }

    func portForwardPermissionPanelDidUnblockAll(_ panel: PortForwardPermissionPanel) {
        delegate?.toolbarDidUnblockAllPorts(self)
    }

    func portForwardPermissionPanelDidRequestAddPortForward(_ panel: PortForwardPermissionPanel) {
        panel.close()
        portForwardPermissionPanel = nil
        editPortForwards()
    }

    // MARK: - PortForwardNotificationPanelDelegate

    func portForwardNotificationPanel(_ panel: PortForwardNotificationPanel, didBlockPort guestPort: UInt16) {
        delegate?.toolbar(self, didBlockAutoForwardedPort: guestPort)
    }

    // MARK: - IconChooserPanelDelegate

    func iconChooserPanel(_ panel: IconChooserPanel, didSelectMode mode: String?, icon: NSImage?) {
        delegate?.toolbar(self, didSelectIconMode: mode, icon: icon)
    }
}

// MARK: - Delegate Protocol

protocol HelperToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: HelperToolbar, didSelectClipboardSyncMode mode: String)
    func toolbar(_ toolbar: HelperToolbar, didToggleCaptureSystemKeys enabled: Bool)
    func toolbar(_ toolbar: HelperToolbar, didToggleCaptureQuit enabled: Bool)
    func toolbar(_ toolbar: HelperToolbar, didToggleCaptureHide enabled: Bool)
    func toolbar(_ toolbar: HelperToolbar, didToggleOpenURLsAutomatically enabled: Bool)
    func toolbar(_ toolbar: HelperToolbar, didToggleAutoPortMap enabled: Bool)
    @discardableResult
    func toolbar(_ toolbar: HelperToolbar, didAddPortForward hostPort: UInt16, guestPort: UInt16) -> String?
    func toolbar(_ toolbar: HelperToolbar, didRemovePortForwardWithHostPort hostPort: UInt16)
    func toolbar(_ toolbar: HelperToolbar, didAddSharedFolder path: String, readOnly: Bool)
    func toolbar(_ toolbar: HelperToolbar, didRemoveSharedFolderWithID id: UUID)
    func toolbar(_ toolbar: HelperToolbar, didSetSharedFolderReadOnly readOnly: Bool, forID id: UUID)
    func toolbarDidRequestPortForwardEditor(_ toolbar: HelperToolbar)
    func toolbarDidRequestReceiveFiles(_ toolbar: HelperToolbar)
    func toolbarDidRequestDenyFiles(_ toolbar: HelperToolbar)
    func toolbarDidDetectNewQueuedFiles(_ toolbar: HelperToolbar)
    func toolbarDidRequestShutDown(_ toolbar: HelperToolbar)
    func toolbarDidRequestTerminate(_ toolbar: HelperToolbar)
    func toolbarQueuedFilesPanelDidClose(_ toolbar: HelperToolbar)
    func toolbarClipboardPermissionDidDeny(_ toolbar: HelperToolbar)
    func toolbarClipboardPermissionDidAllowOnce(_ toolbar: HelperToolbar)
    func toolbarClipboardPermissionDidAlwaysAllow(_ toolbar: HelperToolbar)
    func toolbarClipboardPermissionPanelDidClose(_ toolbar: HelperToolbar)
    func toolbarURLPermissionDidDeny(_ toolbar: HelperToolbar)
    func toolbarURLPermissionDidAllowOnce(_ toolbar: HelperToolbar)
    func toolbarURLPermissionDidAlwaysAllow(_ toolbar: HelperToolbar)
    func toolbarURLPermissionPanelDidClose(_ toolbar: HelperToolbar)
    func toolbar(_ toolbar: HelperToolbar, didBlockAutoForwardedPort port: UInt16)
    func toolbarPortForwardPermissionPanelDidClose(_ toolbar: HelperToolbar)
    func toolbar(_ toolbar: HelperToolbar, didUnblockPort port: UInt16)
    func toolbarDidUnblockAllPorts(_ toolbar: HelperToolbar)
    func toolbarDidRequestIconChooser(_ toolbar: HelperToolbar)
    func toolbar(_ toolbar: HelperToolbar, didSelectIconMode mode: String?, icon: NSImage?)
}
