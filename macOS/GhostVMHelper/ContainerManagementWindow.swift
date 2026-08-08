import AppKit
import GhostVMKit

@MainActor
final class ContainerManagementWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Section: Int, CaseIterable {
        case containers, images, volumes, logs

        var title: String {
            switch self {
            case .containers: return "Containers"
            case .images: return "Images"
            case .volumes: return "Volumes"
            case .logs: return "Logs"
            }
        }
    }

    private struct Item: Codable {
        let id: String
        let name: String
        let detail: String
        let status: String
        let managerReference: String?
    }

    private let layout: VMFileLayout
    private let runtime: () -> ContainerBridgeService?
    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let addButton = NSButton()
    private var section = Section.containers
    private var items: [Item] = []
    private var filteredItems: [Item] = []
    private var imageStoreReference: String?

    init(vmName: String, layout: VMFileLayout, runtime: @escaping () -> ContainerBridgeService?) {
        self.layout = layout
        self.runtime = runtime
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Containers - \(vmName)"
        window.minSize = NSSize(width: 650, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("GhostVMContainerManagement")
        super.init(window: window)
        buildUI(in: window)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        refresh()
    }

    private func buildUI(in window: NSWindow) {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: "Container Management")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let sectionControl = NSSegmentedControl(
            labels: Section.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(sectionChanged(_:))
        )
        sectionControl.selectedSegment = section.rawValue

        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: self,
            action: #selector(refreshClicked)
        )
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.toolTip = "Refresh"

        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")
        addButton.title = ""
        addButton.target = self
        addButton.action = #selector(addClicked)
        addButton.bezelStyle = .texturedRounded
        addButton.isEnabled = false

        searchField.placeholderString = "Search"
        searchField.delegate = self

        summaryLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .right

        let header = NSStackView(views: [title, NSView(), sectionControl, refreshButton, addButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let filterBar = NSStackView(views: [summaryLabel, NSView(), searchField])
        filterBar.orientation = .horizontal
        filterBar.alignment = .centerY
        searchField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        addColumn("name", title: "Name", width: 230)
        addColumn("detail", title: "Details", width: 310)
        addColumn("status", title: "Status", width: 150)
        addColumn("menu", title: "", width: 44)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 42
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = true

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let stack = NSStackView(views: [header, filterBar, scrollView, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        filterBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
        ])
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        if identifier == "menu" { column.resizingMask = [] }
        tableView.addTableColumn(column)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredItems.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let item = filteredItems[row]
        if identifier == "menu" {
            let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Actions")!, target: self, action: #selector(showItemMenu(_:)))
            button.bezelStyle = .inline
            button.isBordered = false
            button.tag = row
            return button
        }
        let value: String
        switch identifier {
        case "name": value = item.name
        case "detail": value = item.detail
        default: value = item.status
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = identifier == "status" ? statusColor(item.status) : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func statusColor(_ status: String) -> NSColor {
        switch status.lowercased() {
        case "running": return .systemGreen
        case "stopped", "exited": return .secondaryLabelColor
        case "stopping": return .systemOrange
        default: return .labelColor
        }
    }

    @objc private func sectionChanged(_ sender: NSSegmentedControl) {
        section = Section(rawValue: sender.selectedSegment) ?? .containers
        searchField.stringValue = ""
        addButton.isEnabled = section == .images || section == .volumes
        refresh()
    }

    @objc private func refreshClicked() { refresh() }

    private func refresh() {
        statusLabel.stringValue = "Refreshing..."
        Task { @MainActor in
            do {
                switch section {
                case .containers: items = try await loadContainers()
                case .images: items = try await loadImages()
                case .volumes: items = try await loadVolumes()
                case .logs: items = try loadLogs()
                }
                applyFilter()
                summaryLabel.stringValue = "\(items.count) \(section.title.lowercased())"
                statusLabel.stringValue = items.isEmpty ? emptyMessage : "Updated \(Date().formatted(date: .omitted, time: .shortened))"
            } catch {
                if section == .containers, let cached = try? readContainerCache(), !cached.isEmpty {
                    items = cached
                    applyFilter()
                    summaryLabel.stringValue = "\(items.count) containers - last known"
                }
                statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    private var emptyMessage: String {
        switch section {
        case .containers: return "No containers"
        case .images: return "No images"
        case .volumes: return "No volumes"
        case .logs: return "No retained container logs"
        }
    }

    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredItems = query.isEmpty ? items : items.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.detail.localizedCaseInsensitiveContains(query)
        }
        tableView.reloadData()
    }

    private func invoke(_ method: String, _ parameters: [String: GhostboxJSONValue] = [:]) async throws -> GhostboxDirectValue {
        guard let runtime = runtime() else {
            throw NSError(domain: "GhostVMContainers", code: 1, userInfo: [NSLocalizedDescriptionKey: "Container runtime is unavailable"])
        }
        let response = try await runtime.invokeRuntime(GhostboxDirectRequest(method: .init(rawValue: method), parameters: parameters))
        if let error = response.error {
            throw NSError(domain: "GhostVMContainers", code: 2, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
        guard let result = response.result else {
            throw NSError(domain: "GhostVMContainers", code: 3, userInfo: [NSLocalizedDescriptionKey: "Container runtime returned no result"])
        }
        return result
    }

    private func loadContainers() async throws -> [Item] {
        let result = try await invoke("container.list")
        guard case .array(let values) = result.jsonValue else { return [] }
        let loaded = values.compactMap { value -> Item? in
            guard case .object(let object) = value,
                  let reference = object.string("reference"),
                  let name = object.string("name") else { return nil }
            let cpu = object.integer("cpuCount").map(String.init) ?? "-"
            let memory = object.unsignedInteger("memoryBytes").map(formatBytes) ?? "-"
            return Item(
                id: reference,
                name: name,
                detail: "CPU \(cpu)  Memory \(memory)",
                status: object.string("status") ?? "unknown",
                managerReference: object.string("managerReference")
            )
        }
        try writeContainerCache(loaded)
        return loaded
    }

    private func loadImages() async throws -> [Item] {
        let store = try await invoke("imageStore.default")
        guard let storeReference = store.referenceValue else { return [] }
        imageStoreReference = storeReference
        let list = try await invoke("imageStore.list", ["imageStore": .string(storeReference)])
        var loaded: [Item] = []
        for reference in list.referencesValue ?? [] {
            let name = try await invoke("image.reference", ["image": .string(reference)]).jsonValue?.stringValue ?? reference
            let digest = try await invoke("image.digest", ["image": .string(reference)]).jsonValue?.stringValue ?? ""
            loaded.append(Item(id: reference, name: name, detail: digest, status: "Available", managerReference: nil))
        }
        return loaded
    }

    private func loadVolumes() async throws -> [Item] {
        let list = try await invoke("volume.list")
        var loaded: [Item] = []
        for reference in list.referencesValue ?? [] {
            let inspected = try await invoke("volume.inspect", ["volume": .string(reference)])
            guard case .object(let object) = inspected.jsonValue else { continue }
            loaded.append(Item(
                id: reference,
                name: object.string("name") ?? reference,
                detail: "\(object.string("format") ?? "raw") - \(object.unsignedInteger("sizeInBytes").map(formatBytes) ?? "-")",
                status: "Persistent",
                managerReference: nil
            ))
        }
        return loaded
    }

    private func loadLogs() throws -> [Item] {
        let root = layout.containerRuntimeLogsURL
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { !$0.hasDirectoryPath }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return Item(
                    id: url.path,
                    name: url.deletingPathExtension().lastPathComponent,
                    detail: values?.fileSize.map { formatBytes(UInt64($0)) } ?? "",
                    status: values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "",
                    managerReference: nil
                )
            }
            .sorted { $0.status > $1.status }
    }

    @objc private func showItemMenu(_ sender: NSButton) {
        guard sender.tag < filteredItems.count else { return }
        let item = filteredItems[sender.tag]
        let menu = NSMenu()
        switch section {
        case .containers:
            addMenuItem("Start", action: #selector(startContainer(_:)), item: item, to: menu)
            addMenuItem("Stop", action: #selector(stopContainer(_:)), item: item, to: menu)
            addMenuItem("Restart", action: #selector(restartContainer(_:)), item: item, to: menu)
            if item.managerReference != nil {
                menu.addItem(.separator())
                addMenuItem("Remove...", action: #selector(removeContainer(_:)), item: item, to: menu)
            }
        case .images:
            addMenuItem("Copy Reference", action: #selector(copyItemName(_:)), item: item, to: menu)
            menu.addItem(.separator())
            addMenuItem("Remove...", action: #selector(removeImage(_:)), item: item, to: menu)
        case .volumes:
            addMenuItem("Reveal in Finder", action: #selector(revealVolume(_:)), item: item, to: menu)
            menu.addItem(.separator())
            addMenuItem("Remove...", action: #selector(removeVolume(_:)), item: item, to: menu)
        case .logs:
            addMenuItem("Open", action: #selector(openLog(_:)), item: item, to: menu)
            addMenuItem("Reveal in Finder", action: #selector(revealLog(_:)), item: item, to: menu)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }

    private func addMenuItem(_ title: String, action: Selector, item: Item, to menu: NSMenu) {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menuItem.representedObject = item.id
        if let manager = item.managerReference { menuItem.identifier = NSUserInterfaceItemIdentifier(manager) }
        menu.addItem(menuItem)
    }

    private func perform(_ method: String, parameters: [String: GhostboxJSONValue]) {
        Task { @MainActor in
            do {
                _ = try await invoke(method, parameters)
                refresh()
            } catch {
                present(error)
            }
        }
    }

    @objc private func startContainer(_ sender: NSMenuItem) {
        perform("container.start", parameters: ["container": .string(sender.representedObject as! String)])
    }

    @objc private func stopContainer(_ sender: NSMenuItem) {
        perform("container.stop", parameters: ["container": .string(sender.representedObject as! String)])
    }

    @objc private func restartContainer(_ sender: NSMenuItem) {
        let reference = sender.representedObject as! String
        Task { @MainActor in
            do {
                _ = try await invoke("container.stop", ["container": .string(reference)])
                _ = try await invoke("container.start", ["container": .string(reference)])
                refresh()
            } catch { present(error) }
        }
    }

    @objc private func removeContainer(_ sender: NSMenuItem) {
        guard confirmRemoval("container"), let manager = sender.identifier?.rawValue else { return }
        perform("manager.delete", parameters: [
            "manager": .string(manager),
            "container": .string(sender.representedObject as! String),
        ])
    }

    @objc private func removeImage(_ sender: NSMenuItem) {
        guard confirmRemoval("image"), let store = imageStoreReference,
              let item = items.first(where: { $0.id == sender.representedObject as? String }) else { return }
        perform("imageStore.delete", parameters: [
            "imageStore": .string(store),
            "reference": .string(item.name),
            "performCleanup": .boolean(true),
        ])
    }

    @objc private func removeVolume(_ sender: NSMenuItem) {
        guard confirmRemoval("volume") else { return }
        perform("volume.delete", parameters: ["volume": .string(sender.representedObject as! String)])
    }

    @objc private func copyItemName(_ sender: NSMenuItem) {
        guard let item = items.first(where: { $0.id == sender.representedObject as? String }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.name, forType: .string)
    }

    @objc private func revealVolume(_ sender: NSMenuItem) {
        let name = (sender.representedObject as! String).replacingOccurrences(of: "@volume/", with: "")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: layout.containerRuntimeVolumesURL.appendingPathComponent(name).path)
    }

    @objc private func openLog(_ sender: NSMenuItem) { NSWorkspace.shared.open(URL(fileURLWithPath: sender.representedObject as! String)) }
    @objc private func revealLog(_ sender: NSMenuItem) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sender.representedObject as! String)]) }

    @objc private func addClicked() {
        switch section {
        case .images: promptForImage()
        case .volumes: promptForVolume()
        default: break
        }
    }

    private func promptForImage() {
        let field = NSTextField(string: "")
        field.placeholderString = "registry.example/image:tag"
        guard runPrompt(title: "Pull Image", message: "Enter an OCI image reference.", accessory: field), !field.stringValue.isEmpty else { return }
        Task { @MainActor in
            do {
                let store = try await invoke("imageStore.default").referenceValue
                guard let store else { return }
                _ = try await invoke("imageStore.pull", ["imageStore": .string(store), "reference": .string(field.stringValue)])
                refresh()
            } catch { present(error) }
        }
    }

    private func promptForVolume() {
        let name = NSTextField(string: "")
        name.placeholderString = "volume-name"
        let size = NSTextField(string: "8")
        let stack = NSStackView(views: [NSTextField(labelWithString: "Name"), name, NSTextField(labelWithString: "Size (GB)"), size])
        stack.orientation = .vertical
        stack.alignment = .leading
        name.widthAnchor.constraint(equalToConstant: 280).isActive = true
        size.widthAnchor.constraint(equalToConstant: 280).isActive = true
        guard runPrompt(title: "Create Volume", message: "Create persistent storage in this VM bundle.", accessory: stack),
              !name.stringValue.isEmpty, let gigabytes = UInt64(size.stringValue), gigabytes > 0 else { return }
        perform("volume.create", parameters: ["volume": .string(name.stringValue), "size": .unsignedInteger(gigabytes * 1_073_741_824)])
    }

    private func runPrompt(title: String, message: String, accessory: NSView) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = accessory
        alert.addButton(withTitle: title.components(separatedBy: " ").first ?? "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRemoval(_ noun: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove \(noun)?"
        alert.informativeText = "This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
    }

    private func writeContainerCache(_ values: [Item]) throws {
        try FileManager.default.createDirectory(at: layout.containerRuntimeDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: layout.containerRuntimeMetadataURL, options: .atomic)
    }

    private func readContainerCache() throws -> [Item] {
        try JSONDecoder().decode([Item].self, from: Data(contentsOf: layout.containerRuntimeMetadataURL))
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

private extension Dictionary where Key == String, Value == GhostboxJSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func integer(_ key: String) -> Int64? {
        guard case .integer(let value) = self[key] else { return nil }
        return value
    }

    func unsignedInteger(_ key: String) -> UInt64? {
        switch self[key] {
        case .unsignedInteger(let value): return value
        case .integer(let value) where value >= 0: return UInt64(value)
        default: return nil
        }
    }
}

private extension GhostboxJSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
