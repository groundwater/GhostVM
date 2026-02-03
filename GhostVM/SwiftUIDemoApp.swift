import SwiftUI
import UniformTypeIdentifiers
import GhostVMKit

@main
@available(macOS 13.0, *)
struct GhostVMSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(App2AppDelegate.self) private var appDelegate
    @StateObject private var store = App2VMStore()
    @StateObject private var restoreStore = App2RestoreImageStore()

    var body: some Scene {
        Window("GhostVM", id: "main") {
            VMListDemoView()
                .environmentObject(store)
                .environmentObject(restoreStore)
        }
        .commands {
            DemoAppCommands(store: store, restoreStore: restoreStore)
        }

        // Separate settings window (not a sheet or panel).
        WindowGroup("Settings", id: "settings") {
            SettingsDemoView()
        }

        WindowGroup("Restore Images", id: "restoreImages") {
            RestoreImagesDemoView()
                .environmentObject(restoreStore)
        }

        WindowGroup("Market", id: "store") {
            MarketplaceDemoView()
        }

        // Real VM window shown when pressing Play.
        WindowGroup(id: "vm", for: App2VM.self) { vmBinding in
            if let vm = vmBinding.wrappedValue {
                VMWindowView(vm: vm)
                    .environmentObject(store)
            } else {
                // Empty view - window should not open without a VM
                EmptyView()
            }
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1280, height: 800)
    }
}

// FocusedValue for passing active VM session to menu commands
struct FocusedVMSessionKey: FocusedValueKey {
    typealias Value = App2VMRunSession
}

extension FocusedValues {
    var vmSession: App2VMRunSession? {
        get { self[FocusedVMSessionKey.self] }
        set { self[FocusedVMSessionKey.self] = newValue }
    }
}

@available(macOS 13.0, *)
struct DemoAppCommands: Commands {
    @ObservedObject var store: App2VMStore
    @ObservedObject var restoreStore: App2RestoreImageStore
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.vmSession) private var activeSession

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu("VM") {
            Button("Start") {
                activeSession?.startIfNeeded()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!canStart)

            Divider()

            Menu("Clipboard Sync") {
                ForEach(ClipboardSyncMode.allCases) { mode in
                    Button {
                        activeSession?.setClipboardSyncMode(mode)
                    } label: {
                        HStack {
                            Text(mode.displayName)
                            if activeSession?.clipboardSyncMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            .disabled(activeSession == nil)

            Divider()

            Button("Suspend") {
                activeSession?.suspend()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!canSuspend)

            Button("Shut Down") {
                activeSession?.stop()
            }
            .keyboardShortcut("q", modifiers: [.command, .option])
            .disabled(!canShutDown)

            Divider()

            Button("Terminate") {
                activeSession?.terminate()
            }
            .disabled(!canTerminate)
        }

        CommandGroup(after: .windowList) {
            Button("Virtual Machines") {
                openWindow(id: "main")
            }
            Button("Restore Images") {
                openWindow(id: "restoreImages")
            }
            Button("Market") {
                openWindow(id: "store")
            }
        }
    }

    private var canStart: Bool {
        guard let session = activeSession else { return false }
        switch session.state {
        case .idle, .stopped, .failed:
            return true
        default:
            return false
        }
    }

    private var canSuspend: Bool {
        guard let session = activeSession else { return false }
        if case .running = session.state { return true }
        return false
    }

    private var canShutDown: Bool {
        guard let session = activeSession else { return false }
        if case .running = session.state { return true }
        return false
    }

    private var canTerminate: Bool {
        guard let session = activeSession else { return false }
        switch session.state {
        case .running, .stopping:
            return true
        default:
            return false
        }
    }
}

@available(macOS 13.0, *)
struct VMListDemoView: View {
    @EnvironmentObject private var store: App2VMStore
    @EnvironmentObject private var restoreStore: App2RestoreImageStore
    @Environment(\.openWindow) private var openWindow

    @State private var selectedVMID: App2VM.ID?
    @State private var isShowingCreateSheet: Bool = false
    @State private var vmPendingDelete: App2VM?
    @State private var isDropTarget: Bool = false
    // Snapshot state
    @State private var vmForSnapshot: App2VM?
    @State private var snapshotToRevert: (vm: App2VM, name: String)?
    @State private var snapshotToDelete: (vm: App2VM, name: String)?
    // Edit VM state
    @State private var vmToEdit: App2VM?
    // Install VM state
    @State private var vmToInstall: App2VM?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    openWindow(id: "store")
                } label: {
                    Label("Market", systemImage: "cart")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 12)

            List(selection: $selectedVMID) {
                if isDropTarget && store.vms.isEmpty {
                    HStack {
                        Image(systemName: "square.and.arrow.down.on.square")
                        Text("Drop .GhostVM bundles here")
                        Spacer()
                    }
                    .foregroundStyle(Color.accentColor)
                }

                ForEach(store.vms) { vm in
                    VMRowView(
                        vm: vm,
                        isSelected: selectedVMID == vm.id,
                        play: {
                            openWindow(id: "vm", value: vm)
                        },
                        requestDelete: {
                            vmPendingDelete = vm
                        },
                        requestCreateSnapshot: {
                            vmForSnapshot = vm
                        },
                        requestRevertSnapshot: { name in
                            snapshotToRevert = (vm, name)
                        },
                        requestDeleteSnapshot: { name in
                            snapshotToDelete = (vm, name)
                        },
                        requestEdit: {
                            vmToEdit = vm
                        },
                        requestTerminate: {
                            App2VMSessionRegistry.shared.terminateSession(for: vm.bundlePath)
                        },
                        requestInstall: {
                            vmToInstall = vm
                        }
                    )
                    .tag(vm.id)
                    .contextMenu {
                        VMContextMenu(
                            vm: vm,
                            play: {
                                openWindow(id: "vm", value: vm)
                            },
                            requestDelete: {
                                vmPendingDelete = vm
                            },
                            requestCreateSnapshot: {
                                vmForSnapshot = vm
                            },
                            requestRevertSnapshot: { name in
                                snapshotToRevert = (vm, name)
                            },
                            requestDeleteSnapshot: { name in
                                snapshotToDelete = (vm, name)
                            },
                            requestEdit: {
                                vmToEdit = vm
                            },
                            requestTerminate: {
                                App2VMSessionRegistry.shared.terminateSession(for: vm.bundlePath)
                            },
                            requestInstall: {
                                vmToInstall = vm
                            }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 8))
                    .padding(.vertical, 2)
                }

                if isDropTarget && !store.vms.isEmpty {
                    HStack {
                        Image(systemName: "square.and.arrow.down.on.square")
                        Text("Release to add .GhostVM bundles")
                        Spacer()
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .listStyle(.inset)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
        }
        .frame(minWidth: 520, minHeight: 360)
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateVMDemoView(isPresented: $isShowingCreateSheet)
                .environmentObject(store)
                .environmentObject(restoreStore)
        }
        .onAppear {
            App2AppDelegate.sharedStore = store
        }
        .alert("Delete this virtual machine?", isPresented: Binding(
            get: { vmPendingDelete != nil },
            set: { if !$0 { vmPendingDelete = nil } }
        ), presenting: vmPendingDelete) { vm in
            Button("Move to Trash", role: .destructive) {
                store.deleteVM(vm)
                vmPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                vmPendingDelete = nil
            }
        } message: { vm in
            Text("\"\(vm.name)\" will be moved to the Trash. You can restore it from the Trash later if you change your mind.")
        }
        // Create Snapshot sheet
        .sheet(item: $vmForSnapshot) { vm in
            CreateSnapshotView(vm: vm, isPresented: Binding(
                get: { vmForSnapshot != nil },
                set: { if !$0 { vmForSnapshot = nil } }
            ))
        }
        // Edit VM sheet
        .sheet(item: $vmToEdit) { vm in
            EditVMView(vm: vm, isPresented: Binding(
                get: { vmToEdit != nil },
                set: { if !$0 { vmToEdit = nil } }
            ))
        }
        // Install VM sheet
        .sheet(item: $vmToInstall) { vm in
            InstallVMView(vm: vm, isPresented: Binding(
                get: { vmToInstall != nil },
                set: { if !$0 { vmToInstall = nil } }
            ))
            .environmentObject(store)
        }
        // Revert Snapshot confirmation
        .alert("Revert to snapshot?", isPresented: Binding(
            get: { snapshotToRevert != nil },
            set: { if !$0 { snapshotToRevert = nil } }
        )) {
            Button("Revert", role: .destructive) {
                if let (vm, name) = snapshotToRevert {
                    performSnapshotCommand(bundleURL: vm.bundleURL, subcommand: "revert", snapshotName: name)
                }
                snapshotToRevert = nil
            }
            Button("Cancel", role: .cancel) {
                snapshotToRevert = nil
            }
        } message: {
            if let (vm, name) = snapshotToRevert {
                Text("This will revert \"\(vm.name)\" to snapshot \"\(name)\". Current state will be lost.")
            }
        }
        // Delete Snapshot confirmation
        .alert("Delete snapshot?", isPresented: Binding(
            get: { snapshotToDelete != nil },
            set: { if !$0 { snapshotToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let (vm, name) = snapshotToDelete {
                    performSnapshotCommand(bundleURL: vm.bundleURL, subcommand: "delete", snapshotName: name)
                }
                snapshotToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                snapshotToDelete = nil
            }
        } message: {
            if let (vm, name) = snapshotToDelete {
                Text("Snapshot \"\(name)\" will be permanently deleted from \"\(vm.name)\".")
            }
        }
    }

    private func performSnapshotCommand(bundleURL: URL, subcommand: String, snapshotName: String) {
        let controller = VMController()
        do {
            try controller.snapshot(bundleURL: bundleURL, subcommand: subcommand, snapshotName: snapshotName)
        } catch {
            print("Snapshot command failed: \(error)")
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let identifier = UTType.fileURL.identifier
        var accepted = false
        var collected: [URL] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(identifier) {
            accepted = true
            group.enter()
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                defer { group.leave() }
                var resolvedURL: URL?
                if let url = item as? URL {
                    resolvedURL = url
                } else if let nsurl = item as? NSURL {
                    resolvedURL = nsurl as URL
                } else if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                }

                if let url = resolvedURL {
                    lock.lock()
                    collected.append(url)
                    lock.unlock()
                }
            }
        }

        guard accepted else { return false }

        group.notify(queue: .main) {
            self.store.addBundles(from: collected)
        }

        return true
    }
}

@available(macOS 13.0, *)
struct CreateVMDemoView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: App2VMStore
    @EnvironmentObject private var restoreStore: App2RestoreImageStore
    @Environment(\.openWindow) private var openWindow

    @State private var osType: String = "macOS"
    @State private var cpuCount: String = "4"
    @State private var memoryGiB: String = "8"
    @State private var diskGiB: String = "64"
    @State private var sharedFolders: [SharedFolderConfig] = []
    @State private var restoreItems: [RestoreItem] = []
    @State private var selectedRestorePath: String?
    @State private var selectedISOPath: String?
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @State private var isShowingError: Bool = false

    private let labelWidth: CGFloat = 120

    private struct RestoreItem: Identifiable {
        let path: String
        let title: String
        var id: String { path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(osType == "macOS"
                ? "Provide the required .ipsw restore image. Adjust CPU, memory, and disk as needed."
                : "Provide an ARM64 Linux installer ISO. Adjust CPU, memory, and disk as needed.")
                .fixedSize(horizontal: false, vertical: true)

            labeledRow("Guest OS") {
                Picker("", selection: $osType) {
                    Text("macOS").tag("macOS")
                    Text("Linux").tag("Linux")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            labeledRow("CPUs") {
                HStack(spacing: 8) {
                    TextField("Number of vCPUs", text: $cpuCount)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Text("cores")
                        .foregroundStyle(.secondary)
                }
            }

            labeledRow("Memory") {
                HStack(spacing: 8) {
                    TextField("GiB", text: $memoryGiB)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Text("GiB")
                        .foregroundStyle(.secondary)
                }
            }

            labeledRow("Disk") {
                HStack(spacing: 8) {
                    TextField("GiB (minimum 20)", text: $diskGiB)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Text("GiB")
                        .foregroundStyle(.secondary)
                }
            }

            if osType == "macOS" {
                labeledRow("Restore Image*") {
                    restorePicker
                }
            } else {
                labeledRow("Installer ISO") {
                    isoPicker
                }
            }

            labeledRow("Shared Folders") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sharedFolders.indices, id: \.self) { index in
                        SharedFolderRowView(
                            folder: $sharedFolders[index],
                            onDelete: {
                                sharedFolders.remove(at: index)
                            }
                        )
                    }

                    Button {
                        sharedFolders.append(SharedFolderConfig(path: "", readOnly: true))
                    } label: {
                        Label("Add Shared Folder", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isCreating)
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        .frame(minWidth: 520)
        .onAppear(perform: reloadRestoreItems)
        .onChange(of: restoreStore.images) {
            reloadRestoreItems()
        }
        .alert("Unable to Create VM", isPresented: $isShowingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred while creating the virtual machine.")
        }
    }

    private var canCreate: Bool {
        if osType == "macOS" {
            return hasRestoreOptions && selectedRestorePath != nil
        } else {
            // Linux can be created without an ISO (user can attach later)
            return true
        }
    }

    @ViewBuilder
    private var restorePicker: some View {
        if hasRestoreOptions {
            Picker("Restore Image", selection: restoreSelectionBinding) {
                ForEach(restoreItems) { item in
                    Text(item.title).tag(item.path)
                }
                if !restoreItems.isEmpty {
                    Divider()
                }
                Text("Manage Restore Images…")
                    .tag("__manage_restore__")
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: restoreSelectionBinding.wrappedValue) { oldValue, newValue in
                if newValue == "__manage_restore__" {
                    DispatchQueue.main.async {
                        openWindow(id: "restoreImages")
                        selectedRestorePath = oldValue.isEmpty ? nil : oldValue
                    }
                }
            }
        } else {
            Text("No downloaded restore images detected.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var restoreSelectionBinding: Binding<String> {
        Binding<String>(
            get: {
                selectedRestorePath ?? ""
            },
            set: { newValue in
                selectedRestorePath = newValue.isEmpty ? nil : newValue
            }
        )
    }

    @ViewBuilder
    private var isoPicker: some View {
        HStack(spacing: 8) {
            if let isoPath = selectedISOPath {
                Text(URL(fileURLWithPath: isoPath).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Clear") {
                    selectedISOPath = nil
                }
                .buttonStyle(.borderless)
            } else {
                Text("No ISO selected (optional)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose ISO…") {
                chooseISOFile()
            }
        }
    }

    private func chooseISOFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.init(filenameExtension: "iso")!]
        panel.message = "Select an ARM64 Linux installer ISO"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                DispatchQueue.main.async {
                    self.selectedISOPath = url.path
                }
            }
        }
    }

    @ViewBuilder
    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    private var hasRestoreOptions: Bool {
        !restoreItems.isEmpty
    }

    private func reloadRestoreItems() {
        let service = App2IPSWService.shared
        let cached = service.listCachedImages()

        var items: [RestoreItem] = []
        for image in cached {
            if let restore = restoreStore.images.first(where: { $0.filename == image.filename }) {
                items.append(RestoreItem(path: image.fileURL.path, title: restore.name))
            } else {
                items.append(RestoreItem(path: image.fileURL.path, title: image.filename))
            }
        }

        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        restoreItems = items

        if let selected = selectedRestorePath,
           items.contains(where: { $0.path == selected }) {
            // keep selection
        } else {
            selectedRestorePath = items.first?.path
        }
    }

    private func create() {
        guard canCreate, !isCreating else { return }

        let suggestedName: String
        if osType == "macOS" {
            guard let restorePath = selectedRestorePath else { return }
            let filename = URL(fileURLWithPath: restorePath)
                .deletingPathExtension()
                .lastPathComponent
            let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            suggestedName = trimmed.isEmpty ? "Virtual Machine" : trimmed
        } else {
            if let isoPath = selectedISOPath {
                let filename = URL(fileURLWithPath: isoPath)
                    .deletingPathExtension()
                    .lastPathComponent
                let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                suggestedName = trimmed.isEmpty ? "Linux VM" : trimmed
            } else {
                suggestedName = "Linux VM"
            }
        }

        SavePanelAdapter.chooseVMBundleURL(suggestedName: suggestedName) { url in
            guard let url else { return }
            DispatchQueue.main.async {
                if self.osType == "macOS" {
                    self.performCreate(at: url)
                } else {
                    self.performCreateLinux(at: url)
                }
            }
        }
    }

    private func performCreate(at initialURL: URL) {
        guard let restorePath = selectedRestorePath else { return }

        var bundleURL = initialURL.standardizedFileURL
        let ext = bundleURL.pathExtension.lowercased()
        if ext != "ghostvm" {
            bundleURL.deletePathExtension()
            bundleURL.appendPathExtension("GhostVM")
        }

        // Filter out empty shared folders
        let validFolders = sharedFolders.filter { !$0.path.trimmingCharacters(in: .whitespaces).isEmpty }

        var opts = InitOptions()
        opts.cpus = Int(cpuCount) ?? 4
        opts.memoryGiB = UInt64(memoryGiB) ?? 8
        opts.diskGiB = UInt64(diskGiB) ?? 64
        opts.restoreImagePath = restorePath
        opts.sharedFolders = validFolders

        isCreating = true

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = VMController()
            do {
                try controller.initVM(at: bundleURL, preferredName: nil, options: opts)
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.store.addBundles(from: [bundleURL])
                    self.isPresented = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.errorMessage = error.localizedDescription
                    self.isShowingError = true
                }
            }
        }
    }

    private func performCreateLinux(at initialURL: URL) {
        var bundleURL = initialURL.standardizedFileURL
        let ext = bundleURL.pathExtension.lowercased()
        if ext != "ghostvm" {
            bundleURL.deletePathExtension()
            bundleURL.appendPathExtension("GhostVM")
        }

        // Filter out empty shared folders
        let validFolders = sharedFolders.filter { !$0.path.trimmingCharacters(in: .whitespaces).isEmpty }

        var opts = LinuxInitOptions()
        opts.cpus = Int(cpuCount) ?? 4
        opts.memoryGiB = UInt64(memoryGiB) ?? 8
        opts.diskGiB = UInt64(diskGiB) ?? 64
        opts.isoPath = selectedISOPath
        opts.sharedFolders = validFolders

        isCreating = true

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = VMController()
            do {
                try controller.initLinuxVM(at: bundleURL, preferredName: nil, options: opts)
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.store.addBundles(from: [bundleURL])
                    self.isPresented = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.errorMessage = error.localizedDescription
                    self.isShowingError = true
                }
            }
        }
    }
}

@available(macOS 13.0, *)
struct VMRowView: View {
    let vm: App2VM
    let isSelected: Bool
    let play: () -> Void
    let requestDelete: () -> Void
    let requestCreateSnapshot: () -> Void
    let requestRevertSnapshot: (String) -> Void
    let requestDeleteSnapshot: (String) -> Void
    let requestEdit: () -> Void
    let requestTerminate: () -> Void
    let requestInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.name)
                    .font(.headline)
                Text(vm.osVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack {
                Spacer(minLength: 0)
                Text(vm.status)
                    .font(.subheadline)
                    .foregroundStyle(statusColor(for: vm))
                    .frame(width: 80, alignment: .trailing)
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if vm.needsInstall {
                    Button("Install") {
                        requestInstall()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Button {
                        play()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                }

                Menu {
                    VMContextMenu(
                        vm: vm,
                        play: play,
                        requestDelete: requestDelete,
                        requestCreateSnapshot: requestCreateSnapshot,
                        requestRevertSnapshot: requestRevertSnapshot,
                        requestDeleteSnapshot: requestDeleteSnapshot,
                        requestEdit: requestEdit,
                        requestTerminate: requestTerminate,
                        requestInstall: requestInstall
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 20, height: 20, alignment: .center)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .fixedSize()
        }
    }

    private func statusColor(for vm: App2VM) -> Color {
        switch vm.status.lowercased() {
        case "running":
            return .green
        case "paused":
            return .orange
        default:
            return .secondary
        }
    }
}

// MARK: - Create Snapshot View

@available(macOS 13.0, *)
struct CreateSnapshotView: View {
    let vm: App2VM
    @Binding var isPresented: Bool

    @State private var snapshotName: String = ""
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @State private var isShowingError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create a snapshot of \"\(vm.name)\"")
                .font(.headline)

            TextField("Snapshot name", text: $snapshotName)
                .textFieldStyle(.roundedBorder)

            Text("Snapshots capture the full VM state including disk. This may take a while for large disks.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Button("Create") {
                    createSnapshot()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(snapshotName.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .alert("Unable to Create Snapshot", isPresented: $isShowingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func createSnapshot() {
        let trimmedName = snapshotName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isCreating = true

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = VMController()
            do {
                try controller.snapshot(bundleURL: vm.bundleURL, subcommand: "create", snapshotName: trimmedName)
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.isPresented = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.errorMessage = error.localizedDescription
                    self.isShowingError = true
                }
            }
        }
    }
}

// MARK: - Edit VM View

@available(macOS 13.0, *)
struct EditVMView: View {
    let vm: App2VM
    @Binding var isPresented: Bool

    @State private var cpuCount: String = "4"
    @State private var memoryGiB: String = "8"
    @State private var sharedFolders: [SharedFolderConfig] = []
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var isShowingError: Bool = false
    @State private var isLoading: Bool = true

    private let labelWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \"\(vm.name)\"")
                .font(.headline)

            if isLoading {
                ProgressView("Loading settings…")
                    .padding(.vertical, 8)
            } else {
                labeledRow("CPUs") {
                    HStack(spacing: 8) {
                        TextField("Number of vCPUs", text: $cpuCount)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                        Text("cores")
                            .foregroundStyle(.secondary)
                    }
                }

                labeledRow("Memory") {
                    HStack(spacing: 8) {
                        TextField("GiB", text: $memoryGiB)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                        Text("GiB")
                            .foregroundStyle(.secondary)
                    }
                }

                labeledRow("Shared Folders") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(sharedFolders.indices, id: \.self) { index in
                            SharedFolderRowView(
                                folder: $sharedFolders[index],
                                onDelete: {
                                    sharedFolders.remove(at: index)
                                }
                            )
                        }

                        Button {
                            sharedFolders.append(SharedFolderConfig(path: "", readOnly: true))
                        } label: {
                            Label("Add Shared Folder", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Text("Changes will take effect the next time you start the VM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || isLoading)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        .frame(minWidth: 520)
        .onAppear {
            loadCurrentSettings()
        }
        .alert("Unable to Save Settings", isPresented: $isShowingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    @ViewBuilder
    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    private func loadCurrentSettings() {
        DispatchQueue.global(qos: .userInitiated).async {
            let controller = VMController()
            do {
                let config = try controller.storedConfig(at: vm.bundleURL)
                DispatchQueue.main.async {
                    self.cpuCount = "\(config.cpus)"
                    self.memoryGiB = "\(config.memoryBytes / (1 << 30))"

                    // Load shared folders: prefer new array, fall back to legacy single folder
                    if !config.sharedFolders.isEmpty {
                        self.sharedFolders = config.sharedFolders
                    } else if let legacyPath = config.sharedFolderPath {
                        self.sharedFolders = [SharedFolderConfig(path: legacyPath, readOnly: config.sharedFolderReadOnly)]
                    } else {
                        self.sharedFolders = []
                    }

                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isShowingError = true
                    self.isLoading = false
                }
            }
        }
    }

    private func save() {
        isSaving = true

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = VMController()
            do {
                let cpus = Int(cpuCount) ?? 4
                let memory = UInt64(memoryGiB) ?? 8

                // Filter out empty paths
                let validFolders = sharedFolders.filter { !$0.path.trimmingCharacters(in: .whitespaces).isEmpty }

                try controller.updateVMSettings(
                    bundleURL: vm.bundleURL,
                    cpus: cpus,
                    memoryGiB: memory,
                    sharedFolders: validFolders
                )

                DispatchQueue.main.async {
                    self.isSaving = false
                    self.isPresented = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.errorMessage = error.localizedDescription
                    self.isShowingError = true
                }
            }
        }
    }
}

@available(macOS 13.0, *)
struct SharedFolderRowView: View {
    @Binding var folder: SharedFolderConfig
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Folder path", text: $folder.path)
                .textFieldStyle(.roundedBorder)

            Button {
                selectFolder()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)

            Toggle("Read-only", isOn: $folder.readOnly)
                .toggleStyle(.checkbox)
                .fixedSize()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.message = "Choose a folder to share with the VM"

        if panel.runModal() == .OK, let url = panel.url {
            folder.path = url.path
        }
    }
}

// MARK: - Snapshot Helpers

@available(macOS 13.0, *)
func listSnapshots(for bundleURL: URL) -> [String] {
    let snapshotsDir = bundleURL.appendingPathComponent("Snapshots")
    guard FileManager.default.fileExists(atPath: snapshotsDir.path) else {
        return []
    }
    do {
        let contents = try FileManager.default.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.map { $0.lastPathComponent }.sorted()
    } catch {
        return []
    }
}

@available(macOS 13.0, *)
struct VMContextMenu: View {
    let vm: App2VM
    let play: () -> Void
    let requestDelete: () -> Void
    let requestCreateSnapshot: () -> Void
    let requestRevertSnapshot: (String) -> Void
    let requestDeleteSnapshot: (String) -> Void
    let requestEdit: () -> Void
    let requestTerminate: () -> Void
    let requestInstall: () -> Void
    @EnvironmentObject private var store: App2VMStore

    init(
        vm: App2VM,
        play: @escaping () -> Void,
        requestDelete: @escaping () -> Void,
        requestCreateSnapshot: @escaping () -> Void,
        requestRevertSnapshot: @escaping (String) -> Void,
        requestDeleteSnapshot: @escaping (String) -> Void,
        requestEdit: @escaping () -> Void = {},
        requestTerminate: @escaping () -> Void = {},
        requestInstall: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.play = play
        self.requestDelete = requestDelete
        self.requestCreateSnapshot = requestCreateSnapshot
        self.requestRevertSnapshot = requestRevertSnapshot
        self.requestDeleteSnapshot = requestDeleteSnapshot
        self.requestEdit = requestEdit
        self.requestTerminate = requestTerminate
        self.requestInstall = requestInstall
    }

    var body: some View {
        let lowerStatus = vm.status.lowercased()
        let isRunning = lowerStatus.contains("running") || lowerStatus.contains("starting") || lowerStatus.contains("stopping")

        // Show Install for macOS VMs that need installation
        if vm.needsInstall {
            Button("Install macOS…") {
                requestInstall()
            }
            .disabled(isRunning)
        }

        Button("Start") {
            play()
        }
        .disabled(vm.needsInstall || isRunning)

        Button("Stop") {
            // VM stop is coordinated by closing the VM window; for now this
            // entry is present but handled via the window close behavior.
        }
        .disabled(!isRunning)

        Button("Terminate") {
            requestTerminate()
        }
        .disabled(!isRunning)

        Button("Edit Settings…") {
            requestEdit()
        }
        .disabled(isRunning)

        Divider()

        let snapshots = listSnapshots(for: vm.bundleURL)
        Menu("Snapshots") {
            Button("Create Snapshot…") {
                requestCreateSnapshot()
            }
            .disabled(isRunning)

            if !snapshots.isEmpty {
                Divider()
                ForEach(snapshots, id: \.self) { name in
                    Menu(name) {
                        Button("Revert to \"\(name)\"") {
                            requestRevertSnapshot(name)
                        }
                        .disabled(isRunning)
                        Button("Delete \"\(name)\"", role: .destructive) {
                            requestDeleteSnapshot(name)
                        }
                    }
                }
            }
        }

        // Show "Detach Installer ISO" for Linux VMs with an attached ISO
        if vm.isLinux && vm.installerISOPath != nil {
            Button("Detach Installer ISO") {
                detachISO()
            }
            .disabled(isRunning)
        }

        Divider()
        Button("Show in Finder") {
            FinderAdapter.revealItem(at: vm.bundleURL)
        }
        Button("Remove from List") {
            store.removeFromList(vm)
        }
        Button("Delete", role: .destructive) {
            requestDelete()
        }
        .disabled(isRunning)
    }

    private func detachISO() {
        DispatchQueue.global(qos: .userInitiated).async {
            let controller = VMController()
            do {
                try controller.detachISO(bundleURL: vm.bundleURL)
                // Refresh the VM in store by reloading it
                DispatchQueue.main.async {
                    store.reloadVM(at: vm.bundleURL)
                }
            } catch {
                print("Failed to detach ISO: \(error)")
            }
        }
    }
}

// MARK: - Install VM View

@available(macOS 13.0, *)
struct InstallVMView: View {
    let vm: App2VM
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: App2VMStore

    @State private var progress: Double = 0
    @State private var statusMessage: String = "Starting installation..."
    @State private var errorMessage: String?
    @State private var isComplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installing macOS")
                .font(.headline)

            Text("Installing macOS onto \"\(vm.name)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if isComplete {
                    Button("Done") {
                        isPresented = false
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            startInstall()
        }
    }

    private func startInstall() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try performInstall()
                DispatchQueue.main.async {
                    statusMessage = "Installation complete!"
                    progress = 1.0
                    isComplete = true
                    store.reloadVM(at: vm.bundleURL)
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                    statusMessage = "Installation failed"
                }
            }
        }
    }

    private func performInstall() throws {
        let bundleURL = vm.bundleURL
        let controller = VMController()

        try controller.installVMWithProgress(bundleURL: bundleURL) { fraction, description in
            DispatchQueue.main.async {
                self.progress = fraction
                if let desc = description {
                    self.statusMessage = desc
                }
            }
        }
    }
}

@available(macOS 13.0, *)
struct VMWindowView: View {
    let vm: App2VM
    @EnvironmentObject private var store: App2VMStore
    @StateObject private var session: App2VMRunSession
    @AppStorage("captureSystemKeys") private var captureSystemKeys: Bool = true

    init(vm: App2VM) {
        self.vm = vm
        _session = StateObject(wrappedValue: App2VMRunSession(bundleURL: vm.bundleURL))
    }

    private var isSuspending: Bool {
        if case .suspending = session.state { return true }
        return false
    }

    private var isRunning: Bool {
        if case .running = session.state { return true }
        return false
    }

    private var isRunningOrStopping: Bool {
        switch session.state {
        case .running, .stopping:
            return true
        default:
            return false
        }
    }

    private var isStarting: Bool {
        if case .starting = session.state { return true }
        return false
    }

    private var errorMessage: String? {
        if case .failed(let message) = session.state { return message }
        return nil
    }

    private var clipboardSyncIcon: String {
        switch session.clipboardSyncMode {
        case .bidirectional:
            return "arrow.left.arrow.right.circle.fill"
        case .hostToGuest:
            return "arrow.right.circle.fill"
        case .guestToHost:
            return "arrow.left.circle.fill"
        case .disabled:
            return "clipboard"
        }
    }

    private var clipboardSyncHelp: String {
        "Clipboard Sync: \(session.clipboardSyncMode.displayName)"
    }

    var body: some View {
        ZStack {
            App2VMDisplayHost(virtualMachine: session.virtualMachine, isLinux: vm.isLinux, captureSystemKeys: captureSystemKeys)
                .frame(minWidth: 1024, minHeight: 640)
            // Invisible view that coordinates window close behavior with the VM.
            App2VMWindowCoordinatorHost(session: session)
                .frame(width: 0, height: 0)

            // Dark overlay when starting to show progress
            if isStarting {
                Color.black.opacity(0.7)
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Starting…")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }

            // Dark overlay when suspending to indicate the VM is not interactive
            if isSuspending {
                Color.black.opacity(0.5)
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Suspending…")
                        .font(.title2)
                        .foregroundColor(.white)
                }
            }

            // Error overlay when VM fails to start
            if let error = errorMessage {
                Color.black.opacity(0.8)
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.yellow)
                    Text("Failed to Start VM")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    ForEach(ClipboardSyncMode.allCases) { mode in
                        Button {
                            session.setClipboardSyncMode(mode)
                        } label: {
                            HStack {
                                Text(mode.displayName)
                                if session.clipboardSyncMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Clipboard Sync", systemImage: clipboardSyncIcon)
                }
                .help(clipboardSyncHelp)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.stop()
                } label: {
                    Label("Shut Down", systemImage: "stop.fill")
                }
                .disabled(!isRunning)
                .help("Shut down the guest OS gracefully")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.terminate()
                } label: {
                    Label("Terminate", systemImage: "xmark.circle")
                }
                .disabled(!isRunningOrStopping)
                .help("Force terminate VM immediately")
            }
        }
        .onAppear {
            session.onStateChange = { [vmID = vm.id, bundleURL = vm.bundleURL, store] state in
                switch state {
                case .running:
                    store.updateStatus(for: vmID, status: "Running")
                case .starting:
                    store.updateStatus(for: vmID, status: "Starting…")
                case .suspending:
                    store.updateStatus(for: vmID, status: "Suspending…")
                case .stopping:
                    store.updateStatus(for: vmID, status: "Stopping…")
                case .stopped, .idle:
                    // Reload from disk to get actual suspended state
                    store.reloadVM(at: bundleURL)
                case .failed:
                    store.updateStatus(for: vmID, status: "Error")
                }
            }
            session.startIfNeeded()
        }
        .onDisappear {
            session.stopIfNeeded()
        }
        .focusedSceneValue(\.vmSession, session)
    }
}

@available(macOS 13.0, *)
struct SettingsDemoView: View {
    @State private var vmPath: String
    @State private var ipswPath: String
    @State private var feedURLString: String
    @State private var verificationMessage: String? = nil
    @State private var verificationWasSuccessful: Bool? = nil
    @State private var isVerifying: Bool = false
    @State private var showRacecarBackground: Bool = true
    @State private var iconMode: DemoIconMode = .system
    @AppStorage("captureSystemKeys") private var captureSystemKeys: Bool = true

    private let labelWidth: CGFloat = 130

    init() {
        let ipswService = App2IPSWService.shared
        _vmPath = State(initialValue: "~/VMs")
        _ipswPath = State(initialValue: ipswService.cacheDirectory.path)
        _feedURLString = State(initialValue: ipswService.feedURL.absoluteString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose where GhostVM stores virtual machines and IPSW downloads, and configure the IPSW feed. Changes in this demo view are not persisted.")
                .fixedSize(horizontal: false, vertical: true)

            labeledRow("VMs Folder") {
                HStack(spacing: 8) {
                    TextField("Path to virtual machines", text: $vmPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        // Intentionally no-op in demo app.
                    }
                }
            }

            labeledRow("IPSW Cache") {
                HStack(spacing: 8) {
                    TextField("Path to IPSW cache", text: $ipswPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        // Intentionally no-op in demo app.
                    }
                }
            }

            labeledRow("IPSW Feed URL") {
                HStack(spacing: 8) {
                    TextField("https://mesu.apple.com/…", text: $feedURLString)
                        .textFieldStyle(.roundedBorder)
                    Button("Verify") {
                        verifyFeedURL()
                    }
                    .disabled(isVerifying)
                }
            }

            if let message = verificationMessage {
                HStack(spacing: 6) {
                    Image(systemName: verificationWasSuccessful == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(verificationWasSuccessful == true ? Color.green : Color.orange)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, labelWidth + 4)
            }

            labeledRow("VM List Artwork") {
                Toggle("Show racecar background", isOn: $showRacecarBackground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            labeledRow("Keyboard") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Capture system keys (Cmd+Tab, etc.)", isOn: $captureSystemKeys)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("When enabled, system shortcuts are sent to the VM instead of macOS. Requires restarting the VM window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            labeledRow("App Icon") {
                Picker("", selection: $iconMode) {
                    ForEach(DemoIconMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
            }

            Spacer()
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        .frame(minWidth: 520, minHeight: 320)
        .onAppear {
            AppIconAdapter.updateIcon(for: iconMode)
        }
        .onChange(of: iconMode) { _, newValue in
            AppIconAdapter.updateIcon(for: newValue)
        }
    }

    @ViewBuilder
    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: labelWidth, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verifyFeedURL() {
        verificationMessage = nil
        verificationWasSuccessful = nil
        isVerifying = true

        Task { @MainActor in
            defer { isVerifying = false }
            do {
                let service = App2IPSWService.shared
                let url = try service.validateFeedURL(string: feedURLString)
                _ = try await service.fetchFeed(from: url)
                service.setFeedURL(url)
                verificationMessage = "Feed verified successfully."
                verificationWasSuccessful = true
            } catch {
                verificationMessage = error.localizedDescription
                verificationWasSuccessful = false
            }
        }
    }
}

enum DemoIconMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

@available(macOS 13.0, *)
struct RestoreImagesDemoView: View {
    @EnvironmentObject private var store: App2RestoreImageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore Images")
                .font(.title2.bold())

            Text("Review macOS restore images from the configured IPSW feed and download or delete local copies. These images are stored in the IPSW cache folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.isLoading {
                ProgressView("Loading restore images…")
                    .padding(.vertical, 8)
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            List {
                ForEach(store.images) { image in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("macOS \(image.version) (\(image.build))")
                                .font(.headline)
                            Text(image.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            if let status = store.downloadStatuses[image.id] {
                                if status.totalBytes > 0 {
                                    ProgressView(
                                        value: Double(status.bytesWritten),
                                        total: Double(status.totalBytes)
                                    )
                                    .frame(width: 160)
                                } else {
                                    ProgressView()
                                        .frame(width: 160)
                                }
                                Text("\(Self.byteFormatter.string(fromByteCount: status.bytesWritten)) / \(status.totalBytes > 0 ? Self.byteFormatter.string(fromByteCount: status.totalBytes) : "Unknown") · \(Self.speedFormatter(status.speedBytesPerSecond))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            } else {
                                Text(image.sizeDescription)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button(
                            image.isDownloaded
                                ? (image.isDownloading ? "Delete" : "Delete")
                                : (image.isDownloading ? "Cancel" : "Download")
                        ) {
                            store.toggleDownload(for: image)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Show in Finder") {
                            let service = App2IPSWService.shared
                            FinderAdapter.revealRestoreImage(
                                filename: image.filename,
                                cacheDirectory: service.cacheDirectory
                            )
                        }
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        .frame(minWidth: 520, minHeight: 360)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    private static func speedFormatter(_ speed: Double) -> String {
        guard speed > 0 else { return "0 B/s" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: Int64(speed)) + "/s"
    }
}

@available(macOS 13.0, *)
struct MarketplaceDemoView: View {
    private struct StoreItem: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let detail: String
        let price: String
    }

    @State private var items: [StoreItem] = [
        StoreItem(name: "Race Car Pack", detail: "High-speed virtual machines with bright racecar artwork.", price: "$4.99"),
        StoreItem(name: "Unicorn Lab", detail: "Whimsical macOS guests with experimental settings.", price: "$3.99"),
        StoreItem(name: "Galaxy Bundle", detail: "Starfield-themed VMs for space explorers.", price: "$5.99"),
        StoreItem(name: "Retro Arcade", detail: "Pixel art desktops and chunky fonts for nostalgia.", price: "$2.99")
    ]
    @State private var selectionID: StoreItem.ID?
    @State private var searchText: String = ""

    private var selection: StoreItem? {
        guard let selectionID else { return nil }
        return items.first(where: { $0.id == selectionID })
    }

    private var filteredItems: [StoreItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.name.localizedCaseInsensitiveContains(query) ||
            item.detail.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 8) {
                TextField("Search market", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding([.top, .horizontal], 8)

                List(filteredItems, selection: $selectionID) { item in
                    Text(item.name)
                        .tag(item.id)
                }
            }
            .navigationTitle("Market")
        } detail: {
            if let item = selection {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.name)
                        .font(.largeTitle.bold())

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.15))
                        Image(systemName: "shippingbox.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 160)

                    Text(item.detail)
                        .font(.body)
                        .foregroundStyle(.secondary)

                    Spacer()

                    HStack {
                        Spacer()
                        Button {
                            // Placeholder purchase action.
                        } label: {
                            Text(item.price)
                                .font(.headline)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cart")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .foregroundStyle(.secondary)
                    Text("Browse whimsical VM packs in the store.")
                        .font(.title3)
                    Text("Race cars, unicorns, galaxies, and more — all placeholder content for now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 380)
    }
}
