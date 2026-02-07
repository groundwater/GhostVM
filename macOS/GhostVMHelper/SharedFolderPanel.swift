import AppKit

/// Shared folder configuration for display
struct SharedFolderEntry: Identifiable {
    let id: UUID
    var path: String
    var readOnly: Bool

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Delegate protocol for shared folder panel actions
protocol SharedFolderPanelDelegate: AnyObject {
    func sharedFolderPanel(_ panel: SharedFolderPanel, didAddFolder path: String, readOnly: Bool)
    func sharedFolderPanel(_ panel: SharedFolderPanel, didRemoveFolderWithID id: UUID)
}

/// Sheet-based shared folder editor (immune to FocusableVMView responder stealing)
final class SharedFolderPanel: NSObject {

    weak var delegate: SharedFolderPanelDelegate?

    private var sheetWindow: NSWindow?
    private var entries: [SharedFolderEntry] = []
    private var contentViewController: SharedFolderContentViewController?

    func show(in parentWindow: NSWindow) {
        let vc = SharedFolderContentViewController()
        vc.delegate = self
        vc.setEntries(entries)
        contentViewController = vc

        let sheetWindow = NSWindow(contentViewController: vc)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = "Shared Folders"
        self.sheetWindow = sheetWindow

        parentWindow.beginSheet(sheetWindow)
    }

    func close() {
        if let sheet = sheetWindow, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
        sheetWindow = nil
        contentViewController = nil
    }

    func setEntries(_ newEntries: [SharedFolderEntry]) {
        entries = newEntries
        contentViewController?.setEntries(entries)
    }
}

extension SharedFolderPanel: SharedFolderContentViewControllerDelegate {
    func contentViewController(_ vc: SharedFolderContentViewController, didAddFolder path: String, readOnly: Bool) {
        delegate?.sharedFolderPanel(self, didAddFolder: path, readOnly: readOnly)
    }

    func contentViewController(_ vc: SharedFolderContentViewController, didRemoveFolderWithID id: UUID) {
        delegate?.sharedFolderPanel(self, didRemoveFolderWithID: id)
    }
}

// MARK: - Content View Controller

protocol SharedFolderContentViewControllerDelegate: AnyObject {
    func contentViewController(_ vc: SharedFolderContentViewController, didAddFolder path: String, readOnly: Bool)
    func contentViewController(_ vc: SharedFolderContentViewController, didRemoveFolderWithID id: UUID)
}

final class SharedFolderContentViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    weak var delegate: SharedFolderContentViewControllerDelegate?

    private var entries: [SharedFolderEntry] = []
    private var tableView: NSTableView!
    private var readOnlyCheckbox: NSButton!
    private var errorLabel: NSTextField!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        container.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = NSTextField(labelWithString: "Shared Folders")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Table view for existing folders
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = 30

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 100
        tableView.addTableColumn(nameColumn)

        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Path"
        pathColumn.width = 240
        tableView.addTableColumn(pathColumn)

        let readOnlyColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("readOnly"))
        readOnlyColumn.title = "R/O"
        readOnlyColumn.width = 30
        tableView.addTableColumn(readOnlyColumn)

        let deleteColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("delete"))
        deleteColumn.title = ""
        deleteColumn.width = 28
        tableView.addTableColumn(deleteColumn)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // Add folder controls
        let addButton = NSButton(title: "Add Folder\u{2026}", target: self, action: #selector(addFolder))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        container.addSubview(addButton)

        readOnlyCheckbox = NSButton(checkboxWithTitle: "Read Only", target: nil, action: nil)
        readOnlyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        readOnlyCheckbox.state = .on
        container.addSubview(readOnlyCheckbox)

        errorLabel = NSTextField(labelWithString: "")
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.isHidden = true
        container.addSubview(errorLabel)

        let doneButton = NSButton(title: "Done", target: self, action: #selector(dismissSheet))
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        container.addSubview(doneButton)

        // Layout
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.heightAnchor.constraint(equalToConstant: 160),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            readOnlyCheckbox.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            readOnlyCheckbox.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 12),

            errorLabel.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            doneButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            container.bottomAnchor.constraint(equalTo: doneButton.bottomAnchor, constant: 12)
        ])

        self.view = container
    }

    func setEntries(_ newEntries: [SharedFolderEntry]) {
        entries = newEntries
        tableView?.reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]

        switch tableColumn?.identifier.rawValue {
        case "name":
            let cell = NSTextField(labelWithString: entry.displayName)
            cell.lineBreakMode = .byTruncatingTail
            return centeredCellView(content: cell)
        case "path":
            let cell = NSTextField(labelWithString: entry.path)
            cell.textColor = .secondaryLabelColor
            cell.font = .systemFont(ofSize: 11)
            cell.lineBreakMode = .byTruncatingMiddle
            return centeredCellView(content: cell)
        case "readOnly":
            let cell = NSTextField(labelWithString: entry.readOnly ? "R/O" : "R/W")
            cell.textColor = .secondaryLabelColor
            cell.font = .systemFont(ofSize: 10)
            cell.alignment = .center
            return centeredCellView(content: cell)
        case "delete":
            let button = SharedFolderRemoveButton(target: self, action: #selector(removeFolder(_:)))
            button.tag = row
            return centeredCellView(content: button)
        default:
            return nil
        }
    }

    /// Wraps a subview in an NSTableCellView with vertical centering.
    private func centeredCellView(content: NSView) -> NSTableCellView {
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Actions

    @objc private func addFolder() {
        errorLabel.isHidden = true

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "Select a folder to share with the VM"

        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            let path = url.path

            // Check for duplicates
            if self.entries.contains(where: { $0.path == path }) {
                self.showError("Folder already shared")
                return
            }

            let readOnly = self.readOnlyCheckbox.state == .on
            self.delegate?.contentViewController(self, didAddFolder: path, readOnly: readOnly)
        }
    }

    @objc private func dismissSheet() {
        if let sheet = view.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
    }

    @objc private func removeFolder(_ sender: NSButton) {
        let row = sender.tag
        guard row < entries.count else { return }
        let entry = entries[row]
        delegate?.contentViewController(self, didRemoveFolderWithID: entry.id)
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }
}

// MARK: - Remove Button

/// A subtle remove button that shows a muted `xmark` and turns red on hover.
private final class SharedFolderRemoveButton: NSButton {

    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    convenience init(target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        bezelStyle = .inline
        isBordered = false
        applyStyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyStyle()
    }

    private func applyStyle() {
        let color: NSColor = isHovered ? .systemRed : .tertiaryLabelColor
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        image = NSImage(systemSymbolName: "minus.square", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(config)
    }
}
