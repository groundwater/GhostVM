import AppKit
import SwiftUI

enum GhostFileItemID: Hashable, Codable {
    case share(UUID)
    case mount(UUID)
    case discovered(UUID)
}

private struct GhostFileRowItem: Identifiable, Hashable {
    enum Kind { case share, mount }
    enum Status: Hashable {
        case online
        case starting
        case stopped
        case mounted
        case degraded
        case error(String)
        case offline
        case failed(String)

        var isActive: Bool {
            switch self {
            case .online, .starting, .mounted, .degraded, .error, .offline: true
            case .stopped, .failed: false
            }
        }

        var label: String {
            switch self {
            case .online: "Online"
            case .starting: "Starting"
            case .stopped: "Stopped"
            case .mounted: "Mounted"
            case .degraded: "Degraded"
            case .error: "Error"
            case .offline: "Offline"
            case .failed: "Error"
            }
        }
    }

    let id: GhostFileItemID
    let kind: Kind
    let name: String
    let location: String
    let detail: String?
    let status: Status
    let readOnly: Bool
}

struct GhostFileContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var library: GhostFileLibrary
    @EnvironmentObject private var mountLibrary: GhostFileMountLibrary
    @StateObject private var discovery = GhostFileDiscovery()
    @AppStorage("ghostfile.sharesExpanded") private var sharesExpanded = true
    @AppStorage("ghostfile.mountsExpanded") private var mountsExpanded = true
    @AppStorage("ghostfile.discoverExpanded") private var discoverExpanded = true
    @AppStorage("ghostfile.discoverSelfShares") private var discoverSelfShares = false
    @State private var selection: Set<GhostFileItemID> = []
    @State private var focusedItemID: GhostFileItemID?
    @State private var selectionAnchorID: GhostFileItemID?
    @State private var pendingDeletion: Set<GhostFileItemID> = []
    @State private var showingAddMount = false
    @State private var addMountSelectionID: UUID?
    @State private var completedExtensionStartupScan = false
    @State private var showingExtensionAssistant = false
    @FocusState private var tableHasFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            appHeader
            Divider()

            if let message = library.generalError ?? mountLibrary.generalError {
                errorBanner(message)
                Divider()
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    GhostFileSection(
                        title: "Shares",
                        count: shareCount,
                        emptyMessage: "No shares yet. Use + to add a folder.",
                        items: shareItems,
                        selectionOrder: visibleItemIDs,
                        actionItems: visibleItems,
                        expanded: $sharesExpanded,
                        selection: $selection,
                        focusedItemID: $focusedItemID,
                        selectionAnchorID: $selectionAnchorID,
                        focusTable: { tableHasFocus = true },
                        openDetails: openDetails,
                        start: start,
                        stop: stop,
                        reveal: reveal,
                        setReadOnly: { library.setReadOnly($1, for: $0) },
                        requestDelete: { pendingDeletion = Set($0.map(\.id)) }
                    )
                    Divider()
                    GhostFileSection(
                        title: "Mounts",
                        count: mountCount,
                        emptyMessage: "No mounts yet. Use + to add a connection.",
                        items: mountItems,
                        selectionOrder: visibleItemIDs,
                        actionItems: visibleItems,
                        expanded: $mountsExpanded,
                        selection: $selection,
                        focusedItemID: $focusedItemID,
                        selectionAnchorID: $selectionAnchorID,
                        focusTable: { tableHasFocus = true },
                        openDetails: openDetails,
                        start: start,
                        stop: stop,
                        reveal: reveal,
                        setReadOnly: { library.setReadOnly($1, for: $0) },
                        requestDelete: { pendingDeletion = Set($0.map(\.id)) }
                    )
                    Divider()
                    GhostFileDiscoverSection(
                        shares: visibleDiscoveredShares,
                        isSearching: discovery.isSearching,
                        selectionOrder: visibleItemIDs,
                        expanded: $discoverExpanded,
                        selection: $selection,
                        focusedItemID: $focusedItemID,
                        selectionAnchorID: $selectionAnchorID,
                        focusTable: { tableHasFocus = true },
                        openDetails: { openWindow(value: $0) },
                        addMount: { share in
                            addMountSelectionID = share.id
                            showingAddMount = true
                        }
                    )
                }
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.25))
            .focusable()
            .focused($tableHasFocus)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                moveSelection(
                    by: press.key == .upArrow ? -1 : 1,
                    extending: press.modifiers.contains(.shift)
                )
                return .handled
            }
            .onKeyPress(KeyEquivalent("a"), phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                selectAllVisibleItems()
                return .handled
            }
            .onAppear { tableHasFocus = true }
        }
        .alert(deleteAlertTitle, isPresented: deleteAlertIsPresented) {
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
            Button("Delete", role: .destructive) {
                let deletion = pendingDeletion
                let shareIDs = Set(deletion.compactMap { id -> UUID? in
                    guard case .share(let shareID) = id else { return nil }
                    return shareID
                })
                let mountIDs = Set(deletion.compactMap { id -> UUID? in
                    guard case .mount(let mountID) = id else { return nil }
                    return mountID
                })
                library.delete(shareIDs)
                Task {
                    await mountLibrary.delete(mountIDs)
                    selection.subtract(deletion)
                    pendingDeletion = []
                }
            }
        } message: {
            Text("This removes the saved configuration. It does not delete any source files.")
        }
        .sheet(isPresented: $showingAddMount) {
            GhostFileAddMountView(
                discovery: discovery,
                initialShareID: addMountSelectionID,
                localShareIDs: localShareIDs,
                discoverSelfShares: discoverSelfShares
            )
                .id(addMountSelectionID)
                .environmentObject(mountLibrary)
        }
        .sheet(isPresented: $showingExtensionAssistant) {
            GhostFileExtensionAssistantView(manager: mountLibrary.manager)
        }
        .task {
            updateDiscoveryForDisclosure()
            await mountLibrary.refreshExtensionStatus()
            guard !Task.isCancelled else { return }
            completedExtensionStartupScan = true
            showingExtensionAssistant = mountLibrary.manager.extensionHealth.requiresAttention
        }
        .task {
            await mountLibrary.monitorHealth()
        }
        .onChange(of: discoverExpanded) { _, _ in
            updateDiscoveryForDisclosure()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, completedExtensionStartupScan else { return }
            Task { await mountLibrary.refreshExtensionStatus() }
        }
        .onDisappear {
            discovery.stop()
        }
    }

    private var shareItems: [GhostFileRowItem] {
        library.shares.map { share in
            let folder = library.folderURL(for: share.id)
            return GhostFileRowItem(
                id: .share(share.id),
                kind: .share,
                name: share.name,
                location: abbreviatedPath(folder),
                detail: library.shareURL(for: share.id)?.absoluteString,
                status: rowStatus(library.status(for: share.id)),
                readOnly: share.readOnly
            )
        }
    }

    private var localShareIDs: Set<UUID> {
        Set(library.shares.map(\.id))
    }

    private var visibleDiscoveredShares: [DiscoveredGhostFileShare] {
        GhostFileDiscoveryVisibility.visibleShares(
            from: discovery.shares,
            localShareIDs: localShareIDs,
            discoverSelfShares: discoverSelfShares
        )
    }

    private func updateDiscoveryForDisclosure() {
        if discoverExpanded {
            discovery.start()
        } else {
            discovery.stop()
        }
    }

    private var visibleItems: [GhostFileRowItem] {
        (sharesExpanded ? shareItems : []) + (mountsExpanded ? mountItems : [])
    }

    private var visibleItemIDs: [GhostFileItemID] {
        visibleItems.map(\.id) + (discoverExpanded
            ? visibleDiscoveredShares.map { .discovered($0.id) }
            : [])
    }

    private var shareCount: String {
        guard !shareItems.isEmpty else { return "0 configured" }
        let online = shareItems.filter { $0.status == .online }.count
        return "\(online) of \(shareItems.count) online"
    }

    private var mountItems: [GhostFileRowItem] {
        mountLibrary.mounts.map { mount in
            GhostFileRowItem(
                id: .mount(mount.id),
                kind: .mount,
                name: mount.name,
                location: URL(string: mount.sourceURL)?.host ?? mount.sourceURL,
                detail: mountLibrary.requestedMountPoint(for: mount.id)?.path,
                status: rowStatus(mountLibrary.status(for: mount.id)),
                readOnly: mount.readOnly
            )
        }
    }

    private var mountCount: String {
        guard !mountItems.isEmpty else { return "0 configured" }
        let mounted = mountItems.filter { $0.status.isActive }.count
        return "\(mounted) of \(mountItems.count) mounted"
    }

    private var appHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GhostFile").font(.title2.weight(.semibold))
                Text("Local shares and mounted folders")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !completedExtensionStartupScan || mountLibrary.manager.extensionHealth == .checking {
                ProgressView()
                    .controlSize(.small)
                    .help("Checking file system extension")
            } else if mountLibrary.manager.extensionHealth.requiresAttention {
                Button { showingExtensionAssistant = true } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("File system extension needs attention")
            }
            Menu {
                Button("Add Share") {
                    if let share = library.addShareUsingPanel() {
                        openWindow(value: GhostFileItemID.share(share.id))
                    }
                }
                Button("Add Mount") {
                    addMountSelectionID = nil
                    showingAddMount = true
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 14, height: 14)
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Add")

            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button {
                library.generalError = nil
                mountLibrary.generalError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
    }

    private func openDetails(_ item: GhostFileRowItem) {
        openWindow(value: item.id)
    }

    private func start(_ items: [GhostFileRowItem]) {
        var mountIDs: [UUID] = []
        for item in items {
            switch item.id {
            case .share(let id):
                library.start(id)
            case .mount(let id):
                mountIDs.append(id)
            case .discovered:
                break
            }
        }
        Task {
            for id in mountIDs {
                await mountLibrary.mount(id)
            }
        }
    }

    private func stop(_ items: [GhostFileRowItem]) {
        var mountIDs: [UUID] = []
        for item in items {
            switch item.id {
            case .share(let id):
                library.stop(id)
            case .mount(let id):
                mountIDs.append(id)
            case .discovered:
                break
            }
        }
        Task {
            for id in mountIDs {
                await mountLibrary.unmount(id)
            }
        }
    }

    private func reveal(_ items: [GhostFileRowItem]) {
        for item in items {
            switch item.id {
            case .share(let id): library.reveal(id)
            case .mount(let id): mountLibrary.reveal(id)
            case .discovered: break
            }
        }
    }

    private func moveSelection(by offset: Int, extending: Bool) {
        guard !visibleItemIDs.isEmpty else { return }
        let currentIndex = focusedItemID.flatMap { id in
            visibleItemIDs.firstIndex(of: id)
        }
        let fallbackIndex = offset > 0 ? -1 : visibleItemIDs.count
        let destinationIndex = min(
            max((currentIndex ?? fallbackIndex) + offset, 0),
            visibleItemIDs.count - 1
        )
        let destinationID = visibleItemIDs[destinationIndex]

        if extending {
            let anchorID = selectionAnchorID ?? focusedItemID ?? destinationID
            selectionAnchorID = anchorID
            selection = rangeSelection(from: anchorID, through: destinationID)
        } else {
            selection = [destinationID]
            selectionAnchorID = destinationID
        }
        focusedItemID = destinationID
    }

    private func rangeSelection(
        from anchorID: GhostFileItemID,
        through destinationID: GhostFileItemID
    ) -> Set<GhostFileItemID> {
        guard let anchorIndex = visibleItemIDs.firstIndex(of: anchorID),
              let destinationIndex = visibleItemIDs.firstIndex(of: destinationID) else {
            return [destinationID]
        }
        let bounds = min(anchorIndex, destinationIndex)...max(anchorIndex, destinationIndex)
        return Set(visibleItemIDs[bounds])
    }

    private func selectAllVisibleItems() {
        selection = Set(visibleItemIDs)
        if focusedItemID == nil || !selection.contains(focusedItemID!) {
            focusedItemID = visibleItemIDs.first
        }
        selectionAnchorID = visibleItemIDs.first
    }

    private func abbreviatedPath(_ url: URL?) -> String {
        guard let url else { return "Folder unavailable" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }

    private func rowStatus(_ status: GhostFileShareStatus) -> GhostFileRowItem.Status {
        switch status {
        case .stopped: .stopped
        case .starting: .starting
        case .online: .online
        case .failed(let message): .failed(message)
        }
    }

    private func rowStatus(_ status: GhostFileSavedMountStatus) -> GhostFileRowItem.Status {
        switch status {
        case .stopped: .stopped
        case .mounting: .starting
        case .mounted: .mounted
        case .online: .online
        case .degraded: .degraded
        case .error(_, let message): .error(message)
        case .offline: .offline
        case .failed(let message): .failed(message)
        }
    }

    private var deleteAlertIsPresented: Binding<Bool> {
        Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion = [] } }
        )
    }

    private var deleteAlertTitle: String {
        pendingDeletion.count == 1
            ? "Delete Item?"
            : "Delete \(pendingDeletion.count) Items?"
    }
}

private struct GhostFileSection: View {
    let title: String
    let count: String
    let emptyMessage: String
    let items: [GhostFileRowItem]
    let selectionOrder: [GhostFileItemID]
    let actionItems: [GhostFileRowItem]
    @Binding var expanded: Bool
    @Binding var selection: Set<GhostFileItemID>
    @Binding var focusedItemID: GhostFileItemID?
    @Binding var selectionAnchorID: GhostFileItemID?
    let focusTable: () -> Void
    let openDetails: (GhostFileRowItem) -> Void
    let start: ([GhostFileRowItem]) -> Void
    let stop: ([GhostFileRowItem]) -> Void
    let reveal: ([GhostFileRowItem]) -> Void
    let setReadOnly: (UUID, Bool) -> Void
    let requestDelete: ([GhostFileRowItem]) -> Void
    @State private var pressedItemID: GhostFileItemID?

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader
            if expanded {
                columnHeader
                Divider()
                if items.isEmpty {
                    HStack {
                        Text(emptyMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                } else {
                    ForEach(items) { item in
                        row(item)
                        if item.id != items.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: 12)
            Text(title.uppercased()).font(.callout.weight(.semibold))
            Text(count).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded {
                let hiddenIDs = Set(items.map(\.id))
                selection.subtract(hiddenIDs)
                if let focusedItemID, hiddenIDs.contains(focusedItemID) {
                    self.focusedItemID = selection.first
                }
                if let selectionAnchorID, hiddenIDs.contains(selectionAnchorID) {
                    self.selectionAnchorID = selection.first
                }
            }
            expanded.toggle()
        }
    }

    private var columnHeader: some View {
        GhostFileColumns(
            name: { Text("NAME") },
            location: { Text(title == "Shares" ? "FOLDER" : "SOURCE") },
            access: { Text("ACCESS") },
            status: { Text("STATUS") },
            menu: { Color.clear }
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
    }

    private func row(_ item: GhostFileRowItem) -> some View {
        GhostFileColumns(
            name: { Text(item.name).fontWeight(.medium).lineLimit(1) },
            location: {
                Text(item.location)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            },
            access: {
                if item.kind == .share {
                    Toggle("", isOn: Binding(
                        get: { item.readOnly },
                        set: { value in
                            guard case .share(let shareID) = item.id else { return }
                            setReadOnly(shareID, value)
                        }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help(item.readOnly ? "Read only" : "Read & write")
                } else {
                    Text(item.readOnly ? "Read only" : "Read & write")
                        .foregroundStyle(.secondary)
                }
            },
            status: {
                HStack(spacing: 7) {
                    Image(systemName: statusSymbol(for: item))
                        .font(.body)
                        .foregroundStyle(statusColor(for: item.status))
                        .frame(width: 19)
                    Text(item.status.label)
                        .foregroundStyle(statusTextColor(for: item.status))
                        .lineLimit(1)
                }
                .help(statusHelp(for: item.status))
            },
            menu: {
                Menu {
                    rowMenuItems(for: item)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 20)
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More actions for \(item.name)")
            }
        )
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(selection.contains(item.id) ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .overlay {
            GhostFileMouseSelectionProbe(
                rightClick: { prepareContextSelection(for: item) },
                doubleClick: {
                    select(item, modifiers: [])
                    openDetails(item)
                }
            )
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedItemID != item.id else { return }
                    pressedItemID = item.id
                    focusTable()
                    select(item, modifiers: NSEvent.modifierFlags)
                }
                .onEnded { _ in pressedItemID = nil }
        )
        .contextMenu { rowMenuItems(for: item) }
    }

    @ViewBuilder
    private func rowMenuItems(for item: GhostFileRowItem) -> some View {
        let selectedItems = effectiveSelectedItems(for: item)
        let revealableItems = selectedItems.filter {
            $0.kind == .share || $0.status.isActive || $0.detail != nil
        }

        Button("Open Details") {
            for selectedItem in selectedItems { openDetails(selectedItem) }
        }
        Divider()
        if selectedItems.contains(where: { $0.kind == .share && !$0.status.isActive }) {
            Button("Start Sharing") {
                start(selectedItems.filter { $0.kind == .share && !$0.status.isActive })
            }
        }
        if selectedItems.contains(where: { $0.kind == .share && $0.status.isActive }) {
            Button("Stop Sharing") {
                stop(selectedItems.filter { $0.kind == .share && $0.status.isActive })
            }
        }
        if selectedItems.contains(where: { $0.kind == .mount && !$0.status.isActive }) {
            Button("Mount") {
                start(selectedItems.filter { $0.kind == .mount && !$0.status.isActive })
            }
        }
        if selectedItems.contains(where: { $0.kind == .mount && $0.status.isActive }) {
            Button("Unmount") {
                stop(selectedItems.filter { $0.kind == .mount && $0.status.isActive })
            }
        }
        Button("Reveal in Finder") { reveal(revealableItems) }
            .disabled(revealableItems.isEmpty)
        Divider()
        Button(deleteTitle(for: selectedItems.count), role: .destructive) {
            requestDelete(selectedItems)
        }
    }

    private func select(_ item: GhostFileRowItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.shift) {
            let anchorID = selectionAnchorID ?? focusedItemID ?? item.id
            selectionAnchorID = anchorID
            selection = rangeSelection(from: anchorID, through: item.id)
        } else if modifiers.contains(.command) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
            selectionAnchorID = item.id
        } else if !(selection.count > 1 && selection.contains(item.id)) {
            selection = [item.id]
            selectionAnchorID = item.id
        }
        focusedItemID = item.id
    }

    private func rangeSelection(
        from anchorID: GhostFileItemID,
        through destinationID: GhostFileItemID
    ) -> Set<GhostFileItemID> {
        guard let anchorIndex = selectionOrder.firstIndex(of: anchorID),
              let destinationIndex = selectionOrder.firstIndex(of: destinationID) else {
            return [destinationID]
        }
        let bounds = min(anchorIndex, destinationIndex)...max(anchorIndex, destinationIndex)
        return Set(selectionOrder[bounds])
    }

    private func effectiveSelectedItems(for clickedItem: GhostFileRowItem) -> [GhostFileRowItem] {
        let effectiveIDs = selection.contains(clickedItem.id) ? selection : [clickedItem.id]
        return actionItems.filter { effectiveIDs.contains($0.id) }
    }

    private func prepareContextSelection(for item: GhostFileRowItem) {
        guard !selection.contains(item.id) else { return }
        selection = [item.id]
        focusedItemID = item.id
        selectionAnchorID = item.id
        focusTable()
    }

    private func deleteTitle(for count: Int) -> String {
        count == 1 ? "Delete…" : "Delete \(count) Items…"
    }

    private func statusSymbol(for item: GhostFileRowItem) -> String {
        switch (item.kind, item.status) {
        case (.share, .online): "folder.fill.badge.person.crop"
        case (.share, .starting): "folder.badge.clock"
        case (.share, .stopped): "folder"
        case (.share, .mounted): "folder.fill.badge.person.crop"
        case (.share, .degraded): "folder.badge.questionmark"
        case (.share, .error): "folder.fill.badge.xmark"
        case (.share, .offline): "folder"
        case (.share, .failed): "folder.fill.badge.xmark"
        case (.mount, .online): "externaldrive.fill.badge.checkmark"
        case (.mount, .starting): "externaldrive.badge.timemachine"
        case (.mount, .stopped): "externaldrive.fill.badge.wifi"
        case (.mount, .mounted): "externaldrive.connected.to.line.below.fill"
        case (.mount, .degraded): "externaldrive.fill.badge.wifi"
        case (.mount, .error): "externaldrive.fill.badge.xmark"
        case (.mount, .offline): "externaldrive.fill"
        case (.mount, .failed): "externaldrive.fill.badge.xmark"
        }
    }

    private func statusColor(for status: GhostFileRowItem.Status) -> Color {
        switch status {
        case .online, .mounted: .green
        case .starting: .blue
        case .stopped: .secondary
        case .degraded: .orange
        case .error, .failed: .red
        case .offline: .secondary
        }
    }

    private func statusTextColor(for status: GhostFileRowItem.Status) -> Color {
        if case .degraded = status { return .orange }
        if case .error = status { return .red }
        if case .failed = status { return .red }
        return .secondary
    }

    private func statusHelp(for status: GhostFileRowItem.Status) -> String {
        if case .error(let message) = status { return message }
        if case .failed(let message) = status { return message }
        return status.label
    }
}

private struct GhostFileDiscoverSection: View {
    let shares: [DiscoveredGhostFileShare]
    let isSearching: Bool
    let selectionOrder: [GhostFileItemID]
    @Binding var expanded: Bool
    @Binding var selection: Set<GhostFileItemID>
    @Binding var focusedItemID: GhostFileItemID?
    @Binding var selectionAnchorID: GhostFileItemID?
    let focusTable: () -> Void
    let openDetails: (DiscoveredGhostFileShare) -> Void
    let addMount: (DiscoveredGhostFileShare) -> Void
    @State private var pressedShareID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            sectionHeader
            if expanded {
                columnHeader
                Divider()
                if shares.isEmpty {
                    HStack {
                        if isSearching {
                            ProgressView().controlSize(.small)
                        }
                        Text(isSearching
                            ? "Looking for nearby GhostFile shares…"
                            : "No nearby GhostFile shares found.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 46)
                } else {
                    ForEach(shares) { share in
                        row(share)
                        if share.id != shares.last?.id {
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
        .onChange(of: shares.map(\.id)) { _, availableIDs in
            let availableItemIDs = Set(availableIDs.map { GhostFileItemID.discovered($0) })
            let removedItemIDs = selection.filter { itemID in
                guard case .discovered = itemID else { return false }
                return !availableItemIDs.contains(itemID)
            }
            guard !removedItemIDs.isEmpty else { return }
            selection.subtract(removedItemIDs)
            if let focusedItemID, removedItemIDs.contains(focusedItemID) {
                self.focusedItemID = selection.first
            }
            if let selectionAnchorID, removedItemIDs.contains(selectionAnchorID) {
                self.selectionAnchorID = selection.first
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .frame(width: 12)
            Text("DISCOVER").font(.callout.weight(.semibold))
            Text(discoveryCount).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture {
            if expanded {
                let hiddenIDs = Set(shares.map { GhostFileItemID.discovered($0.id) })
                selection.subtract(hiddenIDs)
                if let focusedItemID, hiddenIDs.contains(focusedItemID) {
                    self.focusedItemID = selection.first
                }
                if let selectionAnchorID, hiddenIDs.contains(selectionAnchorID) {
                    self.selectionAnchorID = selection.first
                }
            }
            expanded.toggle()
        }
    }

    private var discoveryCount: String {
        switch shares.count {
        case 0: isSearching ? "searching" : "0 nearby"
        case 1: "1 nearby"
        default: "\(shares.count) nearby"
        }
    }

    private var columnHeader: some View {
        GhostFileDiscoverColumns(
            name: { Text("NAME") },
            host: { Text("HOST") },
            service: { Text("SERVICE") },
            port: { Text("PORT") },
            menu: { Color.clear }
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.7))
    }

    private func row(_ share: DiscoveredGhostFileShare) -> some View {
        let itemID = GhostFileItemID.discovered(share.id)
        return GhostFileDiscoverColumns(
            name: {
                HStack(spacing: 7) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                        .frame(width: 19)
                    Text(share.name).fontWeight(.medium).lineLimit(1)
                }
            },
            host: {
                Text(share.host)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            },
            service: {
                Text(share.serviceType)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            },
            port: {
                Text(String(share.port))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            },
            menu: {
                Menu {
                    menuItems(for: share)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 20)
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More actions for \(share.name)")
            }
        )
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(selection.contains(itemID) ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .overlay {
            GhostFileMouseSelectionProbe(
                rightClick: { prepareContextSelection(for: share) },
                doubleClick: {
                    select(share, modifiers: [])
                    openDetails(share)
                }
            )
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressedShareID != share.id else { return }
                    pressedShareID = share.id
                    focusTable()
                    select(share, modifiers: NSEvent.modifierFlags)
                }
                .onEnded { _ in pressedShareID = nil }
        )
        .contextMenu { menuItems(for: share) }
    }

    @ViewBuilder
    private func menuItems(for share: DiscoveredGhostFileShare) -> some View {
        let selectedShares = effectiveSelectedShares(for: share)
        Button("Open Details") {
            for selectedShare in selectedShares { openDetails(selectedShare) }
        }
        Divider()
        Button("Add Mount…") {
            if let selectedShare = selectedShares.first { addMount(selectedShare) }
        }
        .disabled(selectedShares.count != 1)
    }

    private func select(
        _ share: DiscoveredGhostFileShare,
        modifiers: NSEvent.ModifierFlags
    ) {
        let itemID = GhostFileItemID.discovered(share.id)
        if modifiers.contains(.shift) {
            let anchorID = selectionAnchorID ?? focusedItemID ?? itemID
            selectionAnchorID = anchorID
            selection = rangeSelection(from: anchorID, through: itemID)
        } else if modifiers.contains(.command) {
            if selection.contains(itemID) {
                selection.remove(itemID)
            } else {
                selection.insert(itemID)
            }
            selectionAnchorID = itemID
        } else if !(selection.count > 1 && selection.contains(itemID)) {
            selection = [itemID]
            selectionAnchorID = itemID
        }
        focusedItemID = itemID
    }

    private func rangeSelection(
        from anchorID: GhostFileItemID,
        through destinationID: GhostFileItemID
    ) -> Set<GhostFileItemID> {
        guard let anchorIndex = selectionOrder.firstIndex(of: anchorID),
              let destinationIndex = selectionOrder.firstIndex(of: destinationID) else {
            return [destinationID]
        }
        let bounds = min(anchorIndex, destinationIndex)...max(anchorIndex, destinationIndex)
        return Set(selectionOrder[bounds])
    }

    private func effectiveSelectedShares(
        for clickedShare: DiscoveredGhostFileShare
    ) -> [DiscoveredGhostFileShare] {
        let clickedID = GhostFileItemID.discovered(clickedShare.id)
        let effectiveIDs = selection.contains(clickedID) ? selection : [clickedID]
        return shares.filter { effectiveIDs.contains(.discovered($0.id)) }
    }

    private func prepareContextSelection(for share: DiscoveredGhostFileShare) {
        let itemID = GhostFileItemID.discovered(share.id)
        guard !selection.contains(itemID) else { return }
        selection = [itemID]
        focusedItemID = itemID
        selectionAnchorID = itemID
        focusTable()
    }
}

private struct GhostFileMouseSelectionProbe: NSViewRepresentable {
    let rightClick: () -> Void
    let doubleClick: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.rightClick = rightClick
        view.doubleClick = doubleClick
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.rightClick = rightClick
        nsView.doubleClick = doubleClick
    }

    final class ProbeView: NSView {
        var rightClick: (() -> Void)?
        var doubleClick: (() -> Void)?
        private var lastHandledRightClickEventNumber: Int?
        private var lastHandledDoubleClickEventNumber: Int?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            if event.type == .rightMouseDown,
               lastHandledRightClickEventNumber != event.eventNumber {
                lastHandledRightClickEventNumber = event.eventNumber
                rightClick?()
            } else if event.type == .leftMouseDown,
                      event.clickCount == 2,
                      lastHandledDoubleClickEventNumber != event.eventNumber {
                lastHandledDoubleClickEventNumber = event.eventNumber
                doubleClick?()
            }
            return nil
        }
    }
}

private struct GhostFileColumns<Name: View, Location: View, Access: View, Status: View, MenuContent: View>: View {
    @ViewBuilder let name: () -> Name
    @ViewBuilder let location: () -> Location
    @ViewBuilder let access: () -> Access
    @ViewBuilder let status: () -> Status
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 12) {
            name().frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            location().frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
            access().frame(width: 108, alignment: .leading)
            status().frame(width: 132, alignment: .leading)
            menu().frame(width: 30, alignment: .center)
        }
    }
}

private struct GhostFileDiscoverColumns<Name: View, Host: View, Service: View, Port: View, MenuContent: View>: View {
    @ViewBuilder let name: () -> Name
    @ViewBuilder let host: () -> Host
    @ViewBuilder let service: () -> Service
    @ViewBuilder let port: () -> Port
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 12) {
            name().frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            host().frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            service().frame(width: 130, alignment: .leading)
            port().frame(width: 70, alignment: .leading)
            menu().frame(width: 30, alignment: .center)
        }
    }
}

struct GhostFileDiscoveredDetailView: View {
    @EnvironmentObject private var mountLibrary: GhostFileMountLibrary
    let share: DiscoveredGhostFileShare
    @State private var showingAddMount = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(share.name).font(.title2.weight(.semibold))
                    Text("Available nearby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Mount…") { showingAddMount = true }
                    .buttonStyle(.borderedProminent)
            }
            .padding(18)
            Divider()
            Form {
                Section("Service") {
                    LabeledContent("Host", value: share.host)
                    LabeledContent("Type", value: share.serviceType)
                    LabeledContent("Port", value: String(share.port))
                    LabeledContent("Transport", value: share.transport)
                }
                Section("Share") {
                    LabeledContent("Identifier", value: share.id.uuidString.lowercased())
                    LabeledContent("Access", value: share.readOnly ? "Read only" : "Read & write")
                    LabeledContent("URL") {
                        Text(share.url?.absoluteString ?? "Unavailable")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                Section("Security") {
                    Label(
                        "This identity came from unauthenticated local-network discovery.",
                        systemImage: "exclamationmark.shield"
                    )
                    .foregroundStyle(.orange)
                    LabeledContent("Public-key fingerprint") {
                        Text(share.publicKeyPin)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text("Compare this fingerprint with the sharing Mac before entering an access key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $showingAddMount) {
            GhostFileAddMountView(initialShare: share)
                .environmentObject(mountLibrary)
        }
    }
}

struct GhostFileDetailView: View {
    @EnvironmentObject private var library: GhostFileLibrary
    @EnvironmentObject private var mountLibrary: GhostFileMountLibrary
    let itemID: GhostFileItemID

    var body: some View {
        switch itemID {
        case .share(let id):
            if let share = library.share(withID: id) {
                GhostFileShareDetailEditor(share: share)
            } else {
                ContentUnavailableView("Share Not Found", systemImage: "folder.badge.questionmark")
            }
        case .mount(let id):
            if let mount = mountLibrary.mount(withID: id) {
                GhostFileMountDetailEditor(mount: mount)
            } else {
                ContentUnavailableView("Mount Not Found", systemImage: "externaldrive.badge.questionmark")
            }
        case .discovered:
            ContentUnavailableView(
                "Discovered Share Not Found",
                systemImage: "dot.radiowaves.left.and.right"
            )
        }
    }
}

private struct GhostFileShareDetailEditor: View {
    private struct Draft: Equatable {
        let name: String
        let portText: String
        let accessKey: String
        let replacementFolder: URL?
    }

    @EnvironmentObject private var library: GhostFileLibrary
    let share: SavedGhostFileShare
    @State private var name: String
    @State private var portText: String
    @State private var readOnly: Bool
    @State private var accessKey = ""
    @State private var replacementFolder: URL?
    @State private var editorError: String?
    @State private var didLoadAccessKey = false
    @State private var lastSavedDraft: Draft?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var publicKeyPin: String?
    @State private var showingIdentityRotationConfirmation = false

    init(share: SavedGhostFileShare) {
        self.share = share
        _name = State(initialValue: share.name)
        _portText = State(initialValue: String(share.preferredPort))
        _readOnly = State(initialValue: share.readOnly)
    }

    var body: some View {
        let status = library.status(for: share.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.person.crop")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2.weight(.semibold))
                    Text(statusLabel(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isActive(status) ? "Stop" : "Start") {
                    if isActive(status) {
                        _ = flushAutosave()
                        library.stop(share.id)
                    } else if flushAutosave() {
                        library.start(share.id)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive(status) ? .red : .green)
                .controlSize(.large)
            }
            .padding(18)

            Divider()

            Form {
                Section("Folder") {
                    LabeledContent("Source") {
                        HStack {
                            Text(displayedFolder?.path ?? "Folder unavailable")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Reveal") { library.reveal(share.id) }
                                .disabled(replacementFolder != nil)
                            Button("Change…") { chooseReplacementFolder() }
                        }
                    }
                }
                Section("Connection") {
                    TextField("Share name", text: $name)
                        .onSubmit { _ = flushAutosave() }
                    LabeledContent(
                        "Share URL",
                        value: library.shareURL(for: share.id)?.absoluteString ?? "Available when online"
                    )
                    LabeledContent("Public-key fingerprint") {
                        Text(publicKeyPin ?? "Unavailable")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(publicKeyPin == nil ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    TextField("Preferred port", text: $portText)
                        .onSubmit { _ = flushAutosave() }
                    HStack {
                        SecureField("Access key", text: $accessKey)
                            .onSubmit { _ = flushAutosave() }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(accessKey, forType: .string)
                        }
                        Button("Regenerate") {
                            accessKey = UUID().uuidString.lowercased()
                        }
                    }
                    Button("Rotate Share Identity…", role: .destructive) {
                        showingIdentityRotationConfirmation = true
                    }
                    .disabled(isActive(status))
                }
                Section("Access") {
                    Toggle("Read only", isOn: Binding(
                        get: { readOnly },
                        set: { value in
                            library.setReadOnly(value, for: share.id)
                            readOnly = library.share(withID: share.id)?.readOnly ?? readOnly
                        }
                    ))
                    Text("Changes apply immediately to current and new client connections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Activity") {
                    LabeledContent("Requests", value: String(library.requestCount(for: share.id)))
                }
                if case .failed(let message) = status {
                    Section("Error") {
                        Text(message).foregroundStyle(.red)
                    }
                }
                if let editorError {
                    Section {
                        Text(editorError).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .task { loadAccessKeyIfNeeded() }
        .confirmationDialog(
            "Rotate this share’s TLS identity?",
            isPresented: $showingIdentityRotationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Rotate Identity", role: .destructive) {
                library.rotateTLSIdentity(for: share.id)
                loadPublicKeyPin()
            }
        } message: {
            Text("Existing links and saved mounts will no longer trust this share. Send clients the new link before reconnecting.")
        }
        .onChange(of: name) { _, _ in scheduleAutosave() }
        .onChange(of: portText) { _, _ in scheduleAutosave() }
        .onChange(of: accessKey) { _, _ in scheduleAutosave() }
        .onDisappear { _ = flushAutosave() }
    }

    private func isActive(_ status: GhostFileShareStatus) -> Bool {
        status == .online || status == .starting
    }

    private func statusLabel(_ status: GhostFileShareStatus) -> String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .online: "Online"
        case .failed: "Failed"
        }
    }

    private var displayedFolder: URL? {
        replacementFolder ?? library.folderURL(for: share.id)
    }

    private var parsedPort: UInt16? {
        UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var draft: Draft {
        Draft(
            name: name,
            portText: portText,
            accessKey: accessKey,
            replacementFolder: replacementFolder
        )
    }

    private func scheduleAutosave(delay: Duration = .milliseconds(400)) {
        guard didLoadAccessKey, draft != lastSavedDraft else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            _ = save()
            autosaveTask = nil
        }
    }

    @discardableResult
    private func flushAutosave() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard didLoadAccessKey else { return false }
        guard draft != lastSavedDraft else { return true }
        return save()
    }

    @discardableResult
    private func save() -> Bool {
        guard let preferredPort = parsedPort else {
            editorError = "The port must be between 0 and 65535. Use 0 to choose automatically."
            return false
        }
        do {
            try library.updateShare(
                share.id,
                name: name,
                preferredPort: preferredPort,
                accessKey: accessKey,
                folderURL: replacementFolder
            )
            replacementFolder = nil
            editorError = nil
            lastSavedDraft = draft
            return true
        } catch {
            editorError = error.localizedDescription
            return false
        }
    }

    private func loadAccessKeyIfNeeded() {
        guard !didLoadAccessKey else { return }
        didLoadAccessKey = true
        do {
            accessKey = try library.accessKey(for: share.id)
            loadPublicKeyPin()
            lastSavedDraft = draft
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func loadPublicKeyPin() {
        publicKeyPin = try? library.publicKeyPin(for: share.id)
    }

    private func chooseReplacementFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a new folder for “\(share.name)”"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = displayedFolder
        guard panel.runModal() == .OK else { return }
        replacementFolder = panel.url
        scheduleAutosave(delay: .zero)
    }
}

private struct GhostFileExtensionAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager: GhostFileMountManager

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                statusSymbol
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 24)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                helperRow(
                    symbol: "shippingbox.fill",
                    title: "Embedded with GhostFile",
                    detail: "The file system module is installed and repaired as part of the app."
                )
                helperRow(
                    symbol: "checkmark.shield.fill",
                    title: "Approval stays with you",
                    detail: "macOS may require you to enable GhostFileFS in System Settings. GhostFile will never bypass that approval."
                )
            }
            .padding(24)

            Divider()

            HStack {
                if manager.extensionHealth.requiresAttention {
                    Button("Later") { dismiss() }
                }
                Spacer()
                Button("Scan Again") {
                    Task { await manager.refreshExtensionStatus() }
                }
                .disabled(manager.isWorking || manager.extensionHealth == .checking)

                primaryAction
            }
            .padding(18)
        }
        .frame(width: 540)
        .interactiveDismissDisabled(manager.isWorking)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        if manager.isWorking || manager.extensionHealth == .checking {
            ProgressView()
                .controlSize(.large)
                .frame(width: 52, height: 52)
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 52, height: 52)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch manager.extensionHealth {
        case .ready:
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        case .needsApplicationInstall, .missingEmbeddedExtension:
            Button("Open Applications") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
            .buttonStyle(.borderedProminent)
        case .notRegistered, .duplicateRegistrations, .disabled:
            if manager.extensionRepairAvailable {
                Button(manager.isWorking ? "Repairing…" : "Install / Repair Extension") {
                    Task { await manager.repairExtensionRegistration() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isWorking || !manager.mountedShares.isEmpty)
            } else {
                Button("Open File System Settings") { manager.openExtensionSettings() }
                    .buttonStyle(.borderedProminent)
            }
        case .scanFailed:
            Button("Open File System Settings") { manager.openExtensionSettings() }
                .buttonStyle(.borderedProminent)
        case .checking:
            EmptyView()
        }
    }

    private var title: String {
        if manager.isWorking { return "Repairing GhostFileFS…" }
        switch manager.extensionHealth {
        case .checking: return "Checking GhostFileFS…"
        case .ready: return "GhostFileFS Is Ready"
        case .needsApplicationInstall: return "Move GhostFile to Applications"
        case .missingEmbeddedExtension: return "GhostFileFS Is Missing"
        case .notRegistered: return "Install GhostFileFS"
        case .duplicateRegistrations: return "Repair GhostFileFS"
        case .disabled: return "Enable GhostFileFS"
        case .scanFailed: return "Unable to Check GhostFileFS"
        }
    }

    private var detail: String {
        if manager.isWorking {
            return "GhostFile is verifying the app and rebuilding the macOS extension registration."
        }
        if manager.extensionRepairAvailable, !manager.mountedShares.isEmpty {
            return "Unmount all GhostFile volumes before repairing the file system extension."
        }
        if let statusDetail = manager.extensionStatusDetail { return statusDetail }
        switch manager.extensionHealth {
        case .checking: return "Scanning macOS file system extension registration."
        case .ready: return "The embedded extension is registered, enabled, and ready to mount shares."
        case .needsApplicationInstall: return "Drag GhostFile into Applications, then open that installed copy."
        case .missingEmbeddedExtension: return "Reinstall GhostFile from the disk image to restore its embedded extension."
        case .notRegistered: return "macOS has not registered the extension bundled with this app."
        case .duplicateRegistrations: return "More than one copy is registered, so macOS may launch the wrong one."
        case .disabled: return "Repair registration, then approve GhostFileFS in System Settings if macOS asks."
        case .scanFailed(let message): return message
        }
    }

    private var symbolName: String {
        switch manager.extensionHealth {
        case .ready: "checkmark.circle.fill"
        case .needsApplicationInstall: "arrow.down.app.fill"
        case .missingEmbeddedExtension: "xmark.app.fill"
        case .notRegistered: "externaldrive.badge.plus"
        case .duplicateRegistrations: "wrench.and.screwdriver.fill"
        case .disabled: "externaldrive.fill.badge.exclamationmark"
        case .scanFailed: "exclamationmark.triangle.fill"
        case .checking: "externaldrive.fill"
        }
    }

    private var symbolColor: Color {
        manager.extensionHealth == .ready ? .green : .orange
    }

    private func helperRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GhostFileSettingsView: View {
    @AppStorage("ghostfile.discoverSelfShares") private var discoverSelfShares = false

    var body: some View {
        Form {
            Section("Discover") {
                Toggle("Discover Self-Shares", isOn: $discoverSelfShares)
                Text("Show shares hosted by this Mac alongside nearby shares in Discover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 170)
    }
}

private struct GhostFileAddMountView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var mountLibrary: GhostFileMountLibrary
    @ObservedObject var discovery: GhostFileDiscovery
    let localShareIDs: Set<UUID>
    let discoverSelfShares: Bool
    let fixedInitialShare: DiscoveredGhostFileShare?
    @State private var selectedShareID: UUID?
    @State private var name = "GhostFile Share"
    @State private var sourceURL = ""
    @State private var accessKey = ""
    @State private var mountPoint: URL?
    @State private var readOnly = true
    @State private var errorMessage: String?
    @State private var isSavingAndMounting = false
    @State private var confirmedDiscoveredIdentity = false

    init(
        discovery: GhostFileDiscovery,
        initialShareID: UUID? = nil,
        localShareIDs: Set<UUID> = [],
        discoverSelfShares: Bool = false
    ) {
        self.discovery = discovery
        self.localShareIDs = localShareIDs
        self.discoverSelfShares = discoverSelfShares
        self.fixedInitialShare = nil
        _selectedShareID = State(initialValue: initialShareID)
        let shares = GhostFileDiscoveryVisibility.visibleShares(
            from: discovery.shares,
            localShareIDs: localShareIDs,
            discoverSelfShares: discoverSelfShares
        )
        if let share = shares.first(where: { $0.id == initialShareID }) {
            _name = State(initialValue: share.name)
            _sourceURL = State(initialValue: share.url?.absoluteString ?? "")
            _readOnly = State(initialValue: share.readOnly)
        }
    }

    init(initialShare: DiscoveredGhostFileShare) {
        self.discovery = GhostFileDiscovery()
        self.localShareIDs = []
        self.discoverSelfShares = true
        self.fixedInitialShare = initialShare
        _selectedShareID = State(initialValue: initialShare.id)
        _name = State(initialValue: initialShare.name)
        _sourceURL = State(initialValue: initialShare.url?.absoluteString ?? "")
        _readOnly = State(initialValue: initialShare.readOnly)
    }

    private var nearbyShares: [DiscoveredGhostFileShare] {
        let discoveredShares = GhostFileDiscoveryVisibility.visibleShares(
            from: discovery.shares,
            localShareIDs: localShareIDs,
            discoverSelfShares: discoverSelfShares
        )
        guard let fixedInitialShare else { return discoveredShares }
        return [fixedInitialShare] + discoveredShares.filter { $0.id != fixedInitialShare.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Mount").font(.title2.weight(.semibold))
                    Text("Save a remote GhostFile share as a mountable volume.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !nearbyShares.isEmpty {
                        mountFormSection("Nearby Shares") {
                            mountFormRow("Share") {
                                Picker("Share", selection: $selectedShareID) {
                                    Text("Choose a nearby share…").tag(UUID?.none)
                                    ForEach(nearbyShares) { share in
                                        Text("\(share.name) — \(share.host)").tag(Optional(share.id))
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: selectedShareID) { _, id in
                                    guard let share = nearbyShares.first(where: { $0.id == id }) else { return }
                                    name = share.name
                                    sourceURL = share.url?.absoluteString ?? ""
                                    readOnly = share.readOnly
                                    confirmedDiscoveredIdentity = false
                                }
                            }
                        }
                    }

                    mountFormSection(
                        "Connection",
                        statusIsSatisfied: hasAccessKey,
                        missingLabel: "Access key required",
                        missingSymbol: "xmark.circle.fill",
                        missingColor: .red
                    ) {
                        mountFormRow("Volume name") {
                            TextField("Volume name", text: $name)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                        }
                        Divider()
                        mountFormRow("Share URL") {
                            TextField(
                                "Share URL",
                                text: $sourceURL,
                                prompt: Text("ghostfile://host/v1/shares/…")
                            )
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        }
                        Divider()
                        mountFormRow("Access key") {
                            SecureField("", text: $accessKey, prompt: Text("Enter access key"))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Access key")
                        }
                    }

                    if let discoveredShare = selectedDiscoveredShare {
                        mountFormSection(
                            "Verify Identity",
                            statusIsSatisfied: confirmedDiscoveredIdentity,
                            missingLabel: "Fingerprint verification required",
                            missingSymbol: "exclamationmark.triangle.fill",
                            missingColor: .orange
                        ) {
                            Label(
                                "Nearby discovery is not an authenticated source of identity.",
                                systemImage: "exclamationmark.shield"
                            )
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 11)
                            Divider()
                            mountFormRow("Fingerprint") {
                                Text(discoveredShare.publicKeyPin)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Divider()
                            mountFormRow("Verify fingerprint") {
                                Toggle(
                                    "I verified it with the person sharing the folder",
                                    isOn: $confirmedDiscoveredIdentity
                                )
                                .toggleStyle(.checkbox)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    mountFormSection("Mount Point") {
                        mountFormRow("Location") {
                            HStack {
                                Text(mountPoint?.path ?? "Automatic — ~/GhostFiles")
                                    .foregroundStyle(mountPoint == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if mountPoint != nil {
                                    Button("Use Automatic") { mountPoint = nil }
                                }
                                Button("Choose…") { chooseMountPoint() }
                            }
                        }
                    }

                    mountFormSection("Access") {
                        mountFormRow("Mode") {
                            Text(readOnly ? "Read only" : "Read & write")
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("The share controls this mode. Reconnect to pick up later changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }

                    if mountLibrary.manager.extensionEnabled == false {
                        mountFormSection("File System Extension") {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(
                                    mountLibrary.manager.extensionStatusDetail
                                        ?? "Enable GhostFileFS before mounting.",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(.orange)
                                if mountLibrary.manager.extensionRepairAvailable {
                                    Button(mountLibrary.manager.isWorking ? "Repairing…" : "Install / Repair Extension…") {
                                        Task { await mountLibrary.manager.repairExtensionRegistration() }
                                    }
                                    .disabled(
                                        mountLibrary.manager.isWorking
                                            || !mountLibrary.manager.mountedShares.isEmpty
                                    )
                                }
                                Button("Open File System Extensions…") {
                                    mountLibrary.manager.openExtensionSettings()
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        }
                    }

                    if let errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(mountFormCardBackground)
                            Color.clear.frame(width: 18, height: 18)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { save(mountAfterSaving: false) }
                    .disabled(!canSave || isSavingAndMounting)
                Button("Save & Mount") { save(mountAfterSaving: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSavingAndMounting)
            }
            .padding(18)
        }
        .frame(width: 620, height: selectedDiscoveredShare == nil ? 590 : 700)
    }

    private var selectedDiscoveredShare: DiscoveredGhostFileShare? {
        nearbyShares.first { $0.id == selectedShareID }
    }

    private var hasAccessKey: Bool {
        !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var mountFormCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.055))
    }

    private func mountFormRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 140, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
    }

    private func mountFormSection<Content: View>(
        _ title: String,
        statusIsSatisfied: Bool? = nil,
        missingLabel: String = "",
        missingSymbol: String = "xmark.circle.fill",
        missingColor: Color = .red,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(mountFormCardBackground)

                Group {
                    if let statusIsSatisfied {
                        requirementStatus(
                            isSatisfied: statusIsSatisfied,
                            missingLabel: missingLabel,
                            missingSymbol: missingSymbol,
                            missingColor: missingColor
                        )
                    } else {
                        Color.clear
                            .frame(width: 18, height: 18)
                    }
                }
                .frame(width: 18, height: 44, alignment: .center)
            }
        }
    }

    private func requirementStatus(
        isSatisfied: Bool,
        missingLabel: String,
        missingSymbol: String,
        missingColor: Color
    ) -> some View {
        Image(systemName: isSatisfied ? "checkmark.circle.fill" : missingSymbol)
        .font(.caption.weight(.semibold))
        .foregroundStyle(isSatisfied ? Color.green : missingColor)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .help(isSatisfied ? "Complete" : missingLabel)
        .accessibilityLabel(isSatisfied ? "Complete" : missingLabel)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasAccessKey
            && (selectedDiscoveredShare == nil || confirmedDiscoveredIdentity)
    }

    private func save(mountAfterSaving: Bool) {
        do {
            let mount = try mountLibrary.addMount(
                name: name,
                sourceURL: sourceURL,
                accessKey: accessKey,
                mountPoint: mountPoint,
                readOnly: readOnly
            )
            if mountAfterSaving {
                isSavingAndMounting = true
                Task {
                    await mountLibrary.mount(mount.id)
                    isSavingAndMounting = false
                    dismiss()
                }
            } else {
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func chooseMountPoint() {
        let panel = NSOpenPanel()
        panel.title = "Choose an empty folder to use as the mount point"
        panel.prompt = "Choose Mount Point"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = mountPoint
        guard panel.runModal() == .OK else { return }
        mountPoint = panel.url?.standardizedFileURL
    }
}

private struct GhostFileMountDetailEditor: View {
    @EnvironmentObject private var mountLibrary: GhostFileMountLibrary
    let mount: SavedGhostFileMount
    @State private var name: String
    @State private var sourceURL: String
    @State private var accessKey = ""
    @State private var mountPoint: URL?
    @State private var editorError: String?
    @State private var didLoad = false

    init(mount: SavedGhostFileMount) {
        self.mount = mount
        _name = State(initialValue: mount.name)
        _sourceURL = State(initialValue: mount.sourceURL)
    }

    var body: some View {
        let status = mountLibrary.status(for: mount.id)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.title2.weight(.semibold))
                    Text(statusLabel(status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save Changes") { save() }
                    .disabled(isActive(status))
                Button(isActive(status) ? "Unmount" : "Mount") {
                    Task {
                        if isActive(status) {
                            await mountLibrary.unmount(mount.id)
                        } else if save() {
                            await mountLibrary.mount(mount.id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive(status) ? .red : .green)
                .controlSize(.large)
                .disabled(status == .mounting)
            }
            .padding(18)
            Divider()

            Form {
                Section("Connection") {
                    TextField("Volume name", text: $name)
                        .onSubmit { _ = save() }
                    TextField("Share URL", text: $sourceURL)
                        .onSubmit { _ = save() }
                    SecureField("Access key", text: $accessKey)
                        .onSubmit { _ = save() }
                    Text("Connection settings can be edited while unmounted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Mount Point") {
                    LabeledContent("Location") {
                        HStack {
                            Text(mountPoint?.path ?? "Automatic — ~/GhostFiles")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !isActive(status) {
                                if mountPoint != nil {
                                    Button("Use Automatic") { mountPoint = nil }
                                }
                                Button("Choose…") { chooseMountPoint() }
                            }
                            if status.isMounted {
                                Button("Reveal") { mountLibrary.reveal(mount.id) }
                            }
                        }
                    }
                }
                Section("Access") {
                    LabeledContent("Mode", value: "Read only")
                }
                if case .failed(let message) = status {
                    Section("Error") {
                        Text(message).foregroundStyle(.red)
                    }
                }
                if case .error(_, let message) = status {
                    Section("Error") {
                        Text(message).foregroundStyle(.red)
                    }
                }
                if let editorError {
                    Section {
                        Text(editorError).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isActive(status))
        }
        .task { loadIfNeeded() }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try mountLibrary.updateMount(
                mount.id,
                name: name,
                sourceURL: sourceURL,
                accessKey: accessKey,
                mountPoint: mountPoint
            )
            editorError = nil
            return true
        } catch {
            editorError = error.localizedDescription
            return false
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        mountPoint = mountLibrary.requestedMountPoint(for: mount.id)
        do {
            accessKey = try mountLibrary.accessKey(for: mount.id)
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func chooseMountPoint() {
        let panel = NSOpenPanel()
        panel.title = "Choose an empty folder to use as the mount point"
        panel.prompt = "Choose Mount Point"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = mountPoint
        guard panel.runModal() == .OK else { return }
        mountPoint = panel.url?.standardizedFileURL
    }

    private func isActive(_ status: GhostFileSavedMountStatus) -> Bool {
        status == .mounting || status.isMounted
    }

    private func statusLabel(_ status: GhostFileSavedMountStatus) -> String {
        switch status {
        case .stopped: "Stopped"
        case .mounting: "Mounting"
        case .mounted(let url): "Mounted at \(url.path)"
        case .online(let url): "Online — \(url.path)"
        case .degraded(let url): "Degraded — \(url.path)"
        case .error(let url, _): "Error — \(url.path)"
        case .offline(let url): "Offline — \(url.path)"
        case .failed: "Error"
        }
    }
}
