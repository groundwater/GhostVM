import AppKit

/// Port forward configuration for display
struct PortForwardEntry: Identifiable {
    let id = UUID()
    var hostPort: UInt16
    var guestPort: UInt16
    var enabled: Bool
}

/// Delegate protocol for port forward panel actions
protocol PortForwardPanelDelegate: AnyObject {
    func portForwardPanel(_ panel: PortForwardPanel, didAddForward hostPort: UInt16, guestPort: UInt16)
    func portForwardPanel(_ panel: PortForwardPanel, didRemoveForwardWithHostPort hostPort: UInt16)
}

/// Sheet-based port forward editor (immune to FocusableVMView responder stealing)
final class PortForwardPanel: NSObject {

    weak var delegate: PortForwardPanelDelegate?

    private var sheetWindow: NSWindow?
    private var entries: [PortForwardEntry] = []
    private var contentViewController: PortForwardContentViewController?

    func show(in parentWindow: NSWindow) {
        let vc = PortForwardContentViewController()
        vc.delegate = self
        vc.setEntries(entries)
        contentViewController = vc

        let sheetWindow = NSWindow(contentViewController: vc)
        sheetWindow.styleMask = [.titled, .closable]
        sheetWindow.title = "Port Forwards"
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

    func setEntries(_ newEntries: [PortForwardEntry]) {
        entries = newEntries
        contentViewController?.setEntries(entries)
    }
}

extension PortForwardPanel: PortForwardContentViewControllerDelegate {
    func contentViewController(_ vc: PortForwardContentViewController, didAddForward hostPort: UInt16, guestPort: UInt16) {
        delegate?.portForwardPanel(self, didAddForward: hostPort, guestPort: guestPort)
    }

    func contentViewController(_ vc: PortForwardContentViewController, didRemoveForwardWithHostPort hostPort: UInt16) {
        delegate?.portForwardPanel(self, didRemoveForwardWithHostPort: hostPort)
    }
}

// MARK: - Content View Controller

protocol PortForwardContentViewControllerDelegate: AnyObject {
    func contentViewController(_ vc: PortForwardContentViewController, didAddForward hostPort: UInt16, guestPort: UInt16)
    func contentViewController(_ vc: PortForwardContentViewController, didRemoveForwardWithHostPort hostPort: UInt16)
}

final class PortForwardContentViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    weak var delegate: PortForwardContentViewControllerDelegate?

    private var entries: [PortForwardEntry] = []
    private var tableView: NSTableView!
    private var hostPortField: NSTextField!
    private var guestPortField: NSTextField!
    private var addButton: NSButton!
    private var errorLabel: NSTextField!

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        container.translatesAutoresizingMaskIntoConstraints = false

        // Title
        let titleLabel = NSTextField(labelWithString: "Port Forwards")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        // Table view for existing forwards
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = nil
        tableView.rowHeight = 24

        let hostColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("host"))
        hostColumn.title = "Host"
        hostColumn.width = 60
        tableView.addTableColumn(hostColumn)

        let arrowColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("arrow"))
        arrowColumn.title = ""
        arrowColumn.width = 20
        tableView.addTableColumn(arrowColumn)

        let guestColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("guest"))
        guestColumn.title = "Guest"
        guestColumn.width = 60
        tableView.addTableColumn(guestColumn)

        let deleteColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("delete"))
        deleteColumn.title = ""
        deleteColumn.width = 24
        tableView.addTableColumn(deleteColumn)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // Add new forward fields
        let hostLabel = NSTextField(labelWithString: "Host:")
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostLabel)

        hostPortField = NSTextField()
        hostPortField.translatesAutoresizingMaskIntoConstraints = false
        hostPortField.placeholderString = "8080"
        hostPortField.delegate = self
        container.addSubview(hostPortField)

        let arrowLabel = NSTextField(labelWithString: "→")
        arrowLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(arrowLabel)

        let guestLabel = NSTextField(labelWithString: "Guest:")
        guestLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(guestLabel)

        guestPortField = NSTextField()
        guestPortField.translatesAutoresizingMaskIntoConstraints = false
        guestPortField.placeholderString = "80"
        guestPortField.delegate = self
        container.addSubview(guestPortField)

        addButton = NSButton(title: "Add", target: self, action: #selector(addForward))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        container.addSubview(addButton)

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
            scrollView.heightAnchor.constraint(equalToConstant: 140),

            hostLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            hostLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            hostPortField.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            hostPortField.leadingAnchor.constraint(equalTo: hostLabel.trailingAnchor, constant: 4),
            hostPortField.widthAnchor.constraint(equalToConstant: 50),

            arrowLabel.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            arrowLabel.leadingAnchor.constraint(equalTo: hostPortField.trailingAnchor, constant: 8),

            guestLabel.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            guestLabel.leadingAnchor.constraint(equalTo: arrowLabel.trailingAnchor, constant: 8),

            guestPortField.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            guestPortField.leadingAnchor.constraint(equalTo: guestLabel.trailingAnchor, constant: 4),
            guestPortField.widthAnchor.constraint(equalToConstant: 50),

            addButton.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            errorLabel.topAnchor.constraint(equalTo: hostLabel.bottomAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            doneButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            doneButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            container.bottomAnchor.constraint(equalTo: doneButton.bottomAnchor, constant: 12)
        ])

        self.view = container
    }

    func setEntries(_ newEntries: [PortForwardEntry]) {
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
        case "host":
            let cell = NSTextField(labelWithString: "\(entry.hostPort)")
            cell.alignment = .right
            return cell
        case "arrow":
            let cell = NSTextField(labelWithString: "→")
            cell.alignment = .center
            return cell
        case "guest":
            let cell = NSTextField(labelWithString: "\(entry.guestPort)")
            return cell
        case "delete":
            let button = RemoveButton(target: self, action: #selector(removeForward(_:)))
            button.tag = row
            return button
        default:
            return nil
        }
    }

    // MARK: - Actions

    @objc private func addForward() {
        errorLabel.isHidden = true

        guard let hostPortStr = hostPortField.stringValue.isEmpty ? nil : hostPortField.stringValue,
              let hostPort = UInt16(hostPortStr) else {
            showError("Invalid host port")
            return
        }

        guard let guestPortStr = guestPortField.stringValue.isEmpty ? nil : guestPortField.stringValue,
              let guestPort = UInt16(guestPortStr) else {
            showError("Invalid guest port")
            return
        }

        // Check for duplicates
        if entries.contains(where: { $0.hostPort == hostPort }) {
            showError("Host port \(hostPort) already in use")
            return
        }

        delegate?.contentViewController(self, didAddForward: hostPort, guestPort: guestPort)
        hostPortField.stringValue = ""
        guestPortField.stringValue = ""
    }

    @objc private func dismissSheet() {
        if let sheet = view.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        }
    }

    @objc private func removeForward(_ sender: NSButton) {
        let row = sender.tag
        guard row < entries.count else { return }
        let entry = entries[row]
        delegate?.contentViewController(self, didRemoveForwardWithHostPort: entry.hostPort)
    }

    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        errorLabel.isHidden = true
    }
}

// MARK: - Remove Button

/// A subtle remove button that shows a muted `xmark` and turns red on hover.
private final class RemoveButton: NSButton {

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
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove")?
            .withSymbolConfiguration(config)
    }
}
