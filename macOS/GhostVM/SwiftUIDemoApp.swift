import SwiftUI
import UniformTypeIdentifiers
import Combine
import GhostVMKit
import Sparkle

/// Parse a dev build timestamp (YYYYMMDDHHMMSS) from the patch component of a version string.
/// Returns a formatted date string like "Feb 20, 2026 11:59 PM", or nil if not parseable.
private func formattedBuildDate(from version: String) -> String? {
    let parts = version.split(separator: ".")
    guard parts.count >= 3 else { return nil }
    let patch = String(parts[2])
    guard patch.count == 14, patch.allSatisfy(\.isNumber) else { return nil }
    let df = DateFormatter()
    df.dateFormat = "yyyyMMddHHmmss"
    df.timeZone = TimeZone.current
    guard let date = df.date(from: patch) else { return nil }
    let out = DateFormatter()
    out.dateStyle = .medium
    out.timeStyle = .short
    return out.string(from: date)
}

@main
@available(macOS 13.0, *)
struct GhostVMSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(App2AppDelegate.self) private var appDelegate
    @StateObject private var store = App2VMStore()
    @StateObject private var restoreStore = App2RestoreImageStore()

    init() {
        // IMPORTANT: Ignore SIGPIPE signal
        //
        // When writing to a socket/pipe after the remote end has closed,
        // the OS sends SIGPIPE which terminates the process by default.
        // This happens during normal operation when:
        // - Browser closes connection during page reload
        // - Guest VM closes vsock connection
        // - Any network peer disconnects mid-transfer
        //
        // By ignoring SIGPIPE, write() returns -1 with errno=EPIPE instead,
        // which our code handles gracefully. This is standard practice for
        // any application doing network I/O.
        //
        // Without this, rapid browser reloads kill the entire app.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("GhostVM", id: "main") {
            VMListDemoView()
                .environmentObject(store)
                .environmentObject(restoreStore)
                .onOpenURL { url in
                    NSLog("[GhostVM] onOpenURL: \(url.path)")
                    store.addBundles(from: [url])
                    App2AppDelegate.handleOpenURLs([url], store: store)
                }
        }
        .commands {
            DemoAppCommands(
                store: store,
                restoreStore: restoreStore,
                updater: appDelegate.updaterController.updater
            )
        }

        // Separate settings window (not a sheet or panel).
        WindowGroup("Settings", id: "settings") {
            SettingsDemoView()
                .environment(\.sparkleUpdater, appDelegate.updaterController.updater)
        }

        WindowGroup("Restore Images", id: "restoreImages") {
            RestoreImagesDemoView()
                .environmentObject(restoreStore)
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
        .windowToolbarStyle(.unifiedCompact)
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

// MARK: - Sparkle Updater

private struct UpdaterKey: EnvironmentKey {
    static let defaultValue: SPUUpdater? = nil
}

extension EnvironmentValues {
    var sparkleUpdater: SPUUpdater? {
        get { self[UpdaterKey.self] }
        set { self[UpdaterKey.self] = newValue }
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

@available(macOS 13.0, *)
struct DemoAppCommands: Commands {
    @ObservedObject var store: App2VMStore
    @ObservedObject var restoreStore: App2RestoreImageStore
    @ObservedObject private var checkForUpdatesVM: CheckForUpdatesViewModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.vmSession) private var activeSession

    init(store: App2VMStore, restoreStore: App2RestoreImageStore, updater: SPUUpdater) {
        self.store = store
        self.restoreStore = restoreStore
        self.checkForUpdatesVM = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About GhostVM") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                if let formatted = formattedBuildDate(from: version) {
                    let credits = NSAttributedString(
                        string: "Built \(formatted)",
                        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
                    )
                    options[.credits] = credits
                }
                NSApplication.shared.orderFrontStandardAboutPanel(options: options)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings\u{2026}") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: [.command])
            Divider()
            Button("Check for Updates\u{2026}") {
                checkForUpdatesVM.checkForUpdates()
            }
            .disabled(!checkForUpdatesVM.canCheckForUpdates)
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
    // Rename state
    @State private var renamingVMID: App2VM.ID?
    @State private var renameErrorMessage: String?
    // Clone state
    @State private var vmToClone: App2VM?
    @State private var cloneErrorMessage: String?

    // Watermark
    @AppStorage("showListWatermark") private var showListWatermark: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    private var ghostWatermarkImage: NSImage? {
        NSImage(named: colorScheme == .dark ? "ghost-watermark-dark" : "ghost-watermark")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    isShowingCreateSheet = true
                } label: {
                    Label("Create", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("vmList.createButton")

                Spacer()

                Button {
                    openWindow(id: "restoreImages")
                } label: {
                    Label("Images", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("vmList.imagesButton")
            }
            .padding(.top, 8)
            .padding(.horizontal, 12)

            Divider()

            ZStack(alignment: .bottomTrailing) {
                if showListWatermark, let img = ghostWatermarkImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 180, height: 180)
                        .opacity(0.07)
                        .allowsHitTesting(false)
                        .padding(24)
                        .accessibilityIdentifier("vmList.watermark")
                }

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
                            // Launch helper app (no window in main app - helper provides window)
                            App2VMSessionRegistry.shared.startVM(bundleURL: vm.bundleURL, store: store, vmID: vm.id)
                        },
                        playRecovery: {
                            App2VMSessionRegistry.shared.startVM(bundleURL: vm.bundleURL, store: store, vmID: vm.id, recovery: true)
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
                            let lowerStatus = vm.status.lowercased()
                            if lowerStatus.contains("suspended") {
                                let controller = VMController()
                                try? controller.discardSuspend(bundleURL: vm.bundleURL)
                                store.reloadVM(at: vm.bundleURL)
                            } else {
                                App2VMSessionRegistry.shared.terminateSession(for: vm.bundlePath)
                            }
                        },
                        requestInstall: {
                            vmToInstall = vm
                        },
                        isRenaming: renamingVMID == vm.id,
                        requestRename: {
                            renamingVMID = vm.id
                        },
                        commitRename: { newName in
                            if let error = store.renameVM(vm, to: newName) {
                                renameErrorMessage = error
                            }
                            renamingVMID = nil
                        },
                        cancelRename: {
                            renamingVMID = nil
                        },
                        requestClone: {
                            vmToClone = vm
                        }
                    )
                    .tag(vm.id)
                    .contextMenu {
                        VMContextMenu(
                            vm: vm,
                            play: {
                                // Launch helper app (no window in main app - helper provides window)
                                App2VMSessionRegistry.shared.startVM(bundleURL: vm.bundleURL, store: store, vmID: vm.id)
                            },
                            playRecovery: {
                                App2VMSessionRegistry.shared.startVM(bundleURL: vm.bundleURL, store: store, vmID: vm.id, recovery: true)
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
                                let lowerStatus = vm.status.lowercased()
                                if lowerStatus.contains("suspended") {
                                    let controller = VMController()
                                    try? controller.discardSuspend(bundleURL: vm.bundleURL)
                                    store.reloadVM(at: vm.bundleURL)
                                } else {
                                    App2VMSessionRegistry.shared.terminateSession(for: vm.bundlePath)
                                }
                            },
                            requestInstall: {
                                vmToInstall = vm
                            },
                            requestRename: {
                                renamingVMID = vm.id
                            },
                            requestClone: {
                                vmToClone = vm
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
            .scrollContentBackground(.hidden)
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: handleDrop)
            } // ZStack
        }
        .frame(minWidth: 520, minHeight: 360)
        .sheet(isPresented: $isShowingCreateSheet) {
            CreateVMDemoView(isPresented: $isShowingCreateSheet)
                .environmentObject(store)
                .environmentObject(restoreStore)
        }
        .onAppear {
            App2AppDelegate.sharedStore = store
            // Force a deterministic window size for UI testing screenshots
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                DispatchQueue.main.async {
                    if let window = NSApplication.shared.windows.first(where: { $0.title == "GhostVM" }) {
                        let isTall = ProcessInfo.processInfo.arguments.contains("--ui-testing-tall")
                        let size = isTall ? NSSize(width: 660, height: 740) : NSSize(width: 540, height: 480)
                        window.setContentSize(size)
                        window.center()
                    }
                }
            }
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
        // Rename error
        .alert("Unable to Rename", isPresented: Binding(
            get: { renameErrorMessage != nil },
            set: { if !$0 { renameErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                renameErrorMessage = nil
            }
        } message: {
            if let msg = renameErrorMessage {
                Text(msg)
            }
        }
        // Clone VM sheet
        .sheet(item: $vmToClone) { vm in
            CloneVMView(vm: vm, isPresented: Binding(
                get: { vmToClone != nil },
                set: { if !$0 { vmToClone = nil } }
            ))
            .environmentObject(store)
        }
        // Clone error
        .alert("Unable to Clone", isPresented: Binding(
            get: { cloneErrorMessage != nil },
            set: { if !$0 { cloneErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                cloneErrorMessage = nil
            }
        } message: {
            if let msg = cloneErrorMessage {
                Text(msg)
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

    @State private var cpuCount: String = "4"
    @State private var memoryGiB: String = "8"
    @State private var diskGiB: String = "256"
    @State private var sharedFolders: [SharedFolderConfig] = []
    @State private var networkConfig: NetworkConfig = NetworkConfig.defaultConfig
    @State private var restoreItems: [RestoreItem] = []
    @State private var selectedRestorePath: String?
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?
    @State private var isShowingError: Bool = false

    private let labelWidth: CGFloat = 120

    private struct RestoreItem: Identifiable {
        let path: String
        let title: String
        let version: String?
        var id: String { path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Provide the required .ipsw restore image. Adjust CPU, memory, and disk as needed.")
                .fixedSize(horizontal: false, vertical: true)

            labeledRow("CPUs") {
                HStack(spacing: 8) {
                    TextField("Number of vCPUs", text: $cpuCount)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .accessibilityIdentifier("createVM.cpuField")
                    Text("cores")
                        .foregroundStyle(.secondary)
                }
            }

            labeledRow("Memory") {
                HStack(spacing: 8) {
                    TextField("GiB", text: $memoryGiB)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .accessibilityIdentifier("createVM.memoryField")
                    Text("GiB")
                        .foregroundStyle(.secondary)
                }
            }

            labeledRow("Disk") {
                HStack(spacing: 8) {
                    TextField("GiB (minimum 20)", text: $diskGiB)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .accessibilityIdentifier("createVM.diskField")
                    Text("GiB")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Color.clear.frame(width: labelWidth)
                Label(
                    "APFS sparse file: Finder may show the full 256 GiB logical size, but physical usage only grows as blocks are written. Resize after install is not supported.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            labeledRow("Restore Image*") {
                restorePicker
            }

            labeledRow("Shared Folders") {
                SharedFolderListView(folders: $sharedFolders)
            }

            labeledRow("Network") {
                NetworkSettingsView(networkConfig: $networkConfig)
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .disabled(isCreating)
                .accessibilityIdentifier("createVM.cancelButton")
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .accessibilityIdentifier("createVM.createButton")
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
        return selectedRestorePath != nil
    }

    @ViewBuilder
    private var restorePicker: some View {
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
    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    private func reloadRestoreItems() {
        let service = App2IPSWService.shared
        let cached = service.listCachedImages()

        var items: [RestoreItem] = []
        for image in cached {
            if let restore = restoreStore.images.first(where: { $0.filename == image.filename }) {
                let normalizedVersion: String?
                let trimmedVersion = restore.version.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedVersion.isEmpty || trimmedVersion.caseInsensitiveCompare("unknown") == .orderedSame {
                    normalizedVersion = nil
                } else {
                    normalizedVersion = trimmedVersion
                }
                items.append(RestoreItem(path: image.fileURL.path, title: restore.name, version: normalizedVersion))
            } else {
                items.append(RestoreItem(path: image.fileURL.path, title: image.filename, version: nil))
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

        guard let restorePath = selectedRestorePath else { return }
        let suggestedName: String
        if let selectedItem = restoreItems.first(where: { $0.path == restorePath }),
           let version = selectedItem.version {
            suggestedName = "macOS \(version)"
        } else {
            let filename = URL(fileURLWithPath: restorePath)
                .deletingPathExtension()
                .lastPathComponent
            let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
            suggestedName = trimmed.isEmpty ? "Virtual Machine" : trimmed
        }

        let vmRootDirectory = VMController().currentRootDirectory
        SavePanelAdapter.chooseVMBundleURL(
            suggestedName: suggestedName,
            initialDirectoryURL: vmRootDirectory
        ) { url in
            guard let url else { return }
            DispatchQueue.main.async {
                self.performCreate(at: url)
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
        opts.diskGiB = UInt64(diskGiB) ?? 256
        opts.restoreImagePath = restorePath
        opts.sharedFolders = validFolders
        opts.networkConfig = networkConfig

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

}

@available(macOS 13.0, *)
struct VMRowView: View {
    let vm: App2VM
    let isSelected: Bool
    let play: () -> Void
    let playRecovery: () -> Void
    let requestDelete: () -> Void
    let requestCreateSnapshot: () -> Void
    let requestRevertSnapshot: (String) -> Void
    let requestDeleteSnapshot: (String) -> Void
    let requestEdit: () -> Void
    let requestTerminate: () -> Void
    let requestInstall: () -> Void
    let isRenaming: Bool
    let requestRename: () -> Void
    let commitRename: (String) -> Void
    let cancelRename: () -> Void
    let requestClone: () -> Void

    @State private var editingName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    private var vmIcon: NSImage? {
        let iconURL = vm.bundleURL.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: iconURL.path) {
            return NSImage(contentsOf: iconURL)
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = vmIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 64 * 185.4 / 1024, style: .continuous))
                } else {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)
            .accessibilityIdentifier("vmRow.icon")

            VStack(alignment: .leading, spacing: 4) {
                if isRenaming {
                    TextField("VM Name", text: $editingName)
                        .font(.headline)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNameFieldFocused)
                        .onAppear {
                            editingName = vm.name
                            isNameFieldFocused = true
                        }
                        .onSubmit {
                            let trimmed = editingName.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty && trimmed != vm.name {
                                commitRename(trimmed)
                            } else {
                                cancelRename()
                            }
                        }
                        .onExitCommand {
                            cancelRename()
                        }
                        .onChange(of: isNameFieldFocused) { focused in
                            if !focused {
                                cancelRename()
                            }
                        }
                } else {
                    Text(vm.name)
                        .font(.headline)
                        .accessibilityIdentifier("vmRow.name")
                }
                Text(vm.osVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vmRow.osVersion")
            }

            Spacer(minLength: 8)

            VStack {
                Spacer(minLength: 0)
                Text(vm.status)
                    .font(.subheadline)
                    .foregroundStyle(statusColor(for: vm))
                    .frame(width: 80, alignment: .trailing)
                    .accessibilityIdentifier("vmRow.status")
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
                    .accessibilityIdentifier("vmRow.installButton")
                } else {
                    Button {
                        play()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("vmRow.playButton")
                }

                Menu {
                    VMContextMenu(
                        vm: vm,
                        play: play,
                        playRecovery: playRecovery,
                        requestDelete: requestDelete,
                        requestCreateSnapshot: requestCreateSnapshot,
                        requestRevertSnapshot: requestRevertSnapshot,
                        requestDeleteSnapshot: requestDeleteSnapshot,
                        requestEdit: requestEdit,
                        requestTerminate: requestTerminate,
                        requestInstall: requestInstall,
                        requestRename: requestRename,
                        requestClone: requestClone
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 20, height: 20, alignment: .center)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityIdentifier("vmRow.ellipsisMenu")
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

// MARK: - Clone VM View

@available(macOS 13.0, *)
struct CloneVMView: View {
    let vm: App2VM
    @Binding var isPresented: Bool
    @EnvironmentObject private var store: App2VMStore

    @State private var cloneName: String = ""
    @State private var isCloning: Bool = false
    @State private var errorMessage: String?
    @State private var isShowingError: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone \"\(vm.name)\"")
                .font(.headline)

            TextField("Clone name", text: $cloneName)
                .textFieldStyle(.roundedBorder)

            Text("Uses APFS copy-on-write — the clone is created near-instantly and shares disk blocks with the original until they diverge.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCloning)

                Button("Clone") {
                    performClone()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cloneName.trimmingCharacters(in: .whitespaces).isEmpty || isCloning)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .onAppear {
            cloneName = "\(vm.name) Clone"
        }
        .alert("Unable to Clone", isPresented: $isShowingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private func performClone() {
        let trimmedName = cloneName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isCloning = true

        DispatchQueue.global(qos: .userInitiated).async {
            let result = store.cloneVM(vm, newName: trimmedName)
            DispatchQueue.main.async {
                self.isCloning = false
                if let error = result {
                    self.errorMessage = error
                    self.isShowingError = true
                } else {
                    self.isPresented = false
                }
            }
        }
    }
}

// MARK: - Edit VM View

private struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SheetSizeConfigurator: NSViewRepresentable {
    let contentHeight: CGFloat

    final class Coordinator {
        var lastAppliedHeight: CGFloat = 0
        var isConfigured = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        guard contentHeight > 0,
              abs(contentHeight - coord.lastAppliedHeight) > 1 else { return }
        coord.lastAppliedHeight = contentHeight

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }

            if !coord.isConfigured {
                window.styleMask.insert(.resizable)
                window.contentMinSize = NSSize(width: 620, height: 300)
                coord.isConfigured = true
            }

            let screenHeight = window.screen?.visibleFrame.height ?? 800
            let targetHeight = min(contentHeight, screenHeight * 0.9)
            window.setContentSize(NSSize(width: window.frame.width, height: targetHeight))
        }
    }
}

@available(macOS 13.0, *)
struct EditVMView: View {
    let vm: App2VM
    @Binding var isPresented: Bool

    @State private var cpuCount: String = "4"
    @State private var memoryGiB: String = "8"
    @State private var sharedFolders: [SharedFolderConfig] = []
    @State private var portForwards: [PortForwardConfig] = []
    @State private var networkConfig: NetworkConfig = NetworkConfig.defaultConfig
    @State private var diskGiB: String = ""
    @State private var customIcon: NSImage?
    @State private var customIconChanged: Bool = false
    @State private var iconRemoved: Bool = false
    @State private var selectedPresetIcon: String?
    @State private var isDynamicIconMode: Bool = false   // "stack" mode
    @State private var isAppIconMode: Bool = false       // "app" mode
    @State private var isGlassIconMode: Bool = false     // "glass" mode
    @State private var showIconPopover: Bool = false

    private static let allPresetIcons: [(name: String, resource: String)] = [
        // Row 1: People
        ("Hipster", "icon-hipster"),
        ("Nerd", "icon-nerd"),
        ("80s Bro", "icon-80s-bro"),
        // Row 2: Tech/Writing
        ("Terminal", "icon-terminal"),
        ("Quill", "icon-quill"),
        ("Typewriter", "icon-typewriter"),
        ("Kernel", "icon-kernel"),
        // Row 3: Organic
        ("Banana", "icon-banana"),
        ("Papaya", "icon-papaya"),
        ("Daemon", "icon-daemon"),
    ]

    private var presetIcons: [(name: String, resource: String)] {
        Self.allPresetIcons
    }
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var isShowingError: Bool = false
    @State private var isLoading: Bool = true
    @State private var scrollContentHeight: CGFloat = 0

    private let labelWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Edit \"\(vm.name)\"")
                        .font(.headline)

                    if isLoading {
                        ProgressView("Loading settings…")
                            .padding(.vertical, 8)
                    } else {
                        if !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                            iconRow
                        }

                        labeledRow("CPUs") {
                            HStack(spacing: 8) {
                                TextField("Number of vCPUs", text: $cpuCount)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                                    .accessibilityIdentifier("editVM.cpuField")
                                Text("cores")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        labeledRow("Memory") {
                            HStack(spacing: 8) {
                                TextField("GiB", text: $memoryGiB)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                                    .accessibilityIdentifier("editVM.memoryField")
                                Text("GiB")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        labeledRow("Disk") {
                            HStack(spacing: 8) {
                                TextField("GiB", text: $diskGiB)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 120)
                                    .disabled(true)
                                    .accessibilityIdentifier("editVM.diskField")
                                Text("GiB")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        labeledRow("Shared Folders") {
                            SharedFolderListView(folders: $sharedFolders)
                        }

                        labeledRow("Network") {
                            NetworkSettingsView(networkConfig: $networkConfig)
                        }

                        if networkConfig.mode == .nat {
                            labeledRow("Port Forwards") {
                                PortForwardListView(forwards: $portForwards)
                            }
                        } else {
                            labeledRow("Port Forwards") {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Port forwarding is only available in NAT mode")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if !portForwards.isEmpty {
                                        Text("\(portForwards.count) port forward(s) will be disabled in bridged mode")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }

                        Text("Changes will take effect the next time you start the VM.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("editVM.infoBanner")
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 24, bottom: 8, trailing: 24))
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SheetContentHeightKey.self, value: geo.size.height)
                    }
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                .accessibilityIdentifier("editVM.cancelButton")

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || isLoading)
                .accessibilityIdentifier("editVM.saveButton")
            }
            .padding(EdgeInsets(top: 8, leading: 24, bottom: 18, trailing: 24))
        }
        .frame(minWidth: 620)
        .background(SheetSizeConfigurator(contentHeight: scrollContentHeight + 52))
        .onPreferenceChange(SheetContentHeightKey.self) { height in
            if !isLoading {
                scrollContentHeight = height
            }
        }
        .onAppear {
            loadCurrentSettings()
        }
        .alert("Unable to Save Settings", isPresented: $isShowingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    private var iconRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Icon")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: labelWidth, alignment: .leading)
                .padding(.top, 4)

            HStack(spacing: 8) {
                // "Generic" tile
                iconTile(selected: customIcon == nil && selectedPresetIcon == nil && !isDynamicIconMode && !isAppIconMode && !isGlassIconMode) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                } action: {
                    customIcon = nil
                    selectedPresetIcon = nil
                    isDynamicIconMode = false
                    isAppIconMode = false
                    isGlassIconMode = false
                    customIconChanged = true
                    iconRemoved = true
                }

                // "Glass" tile — app icon behind glass overlay
                iconTile(selected: isGlassIconMode) {
                    Image(systemName: "rectangle.on.rectangle.square")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                } action: {
                    isGlassIconMode = true
                    isAppIconMode = false
                    isDynamicIconMode = false
                    customIcon = nil
                    selectedPresetIcon = nil
                    customIconChanged = false
                    iconRemoved = false
                }

                // "Application" tile — shows exact foreground app icon
                iconTile(selected: isAppIconMode) {
                    Image(systemName: "app")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                } action: {
                    isAppIconMode = true
                    isDynamicIconMode = false
                    isGlassIconMode = false
                    customIcon = nil
                    selectedPresetIcon = nil
                    customIconChanged = false
                    iconRemoved = false
                }

                // "Stack" tile — stacked icons of recent apps
                iconTile(selected: isDynamicIconMode) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                } action: {
                    isDynamicIconMode = true
                    isAppIconMode = false
                    isGlassIconMode = false
                    customIcon = nil
                    selectedPresetIcon = nil
                    customIconChanged = false
                    iconRemoved = false
                }

                // "Custom" tile — shows chosen icon or plus symbol
                let isCustomSelected = customIcon != nil && !isDynamicIconMode && !isAppIconMode && !isGlassIconMode
                iconTile(selected: isCustomSelected, showBackground: customIcon == nil) {
                    if let icon = customIcon, selectedPresetIcon == nil {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 80 * 185.4 / 1024, style: .continuous))
                    } else if let presetResource = selectedPresetIcon, let img = NSImage(named: presetResource) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 80 * 185.4 / 1024, style: .continuous))
                    } else {
                        Image(systemName: "plus.square")
                            .font(.system(size: 32))
                            .foregroundStyle(.secondary)
                    }
                } action: {
                    showIconPopover = true
                }
                .popover(isPresented: $showIconPopover) {
                    iconPopoverContent
                }
            }
        }
        .onDrop(of: [UTType.image], isTargeted: nil) { providers in
            handleIconDrop(providers)
        }
    }

    @ViewBuilder
    private var iconPopoverContent: some View {
        let columns = Array(repeating: GridItem(.fixed(80), spacing: 8), count: 4)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(presetIcons, id: \.resource) { preset in
                let isSelected = selectedPresetIcon == preset.resource
                iconTile(selected: isSelected, showBackground: false) {
                    if let img = NSImage(named: preset.resource) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 80 * 185.4 / 1024, style: .continuous))
                    }
                } action: {
                    if let img = NSImage(named: preset.resource) {
                        customIcon = img
                        selectedPresetIcon = preset.resource
                        isDynamicIconMode = false
                        isAppIconMode = false
                        isGlassIconMode = false
                        customIconChanged = true
                        iconRemoved = false
                        showIconPopover = false
                    }
                }
            }

            iconTile(selected: false) {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("Upload")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } action: {
                showIconPopover = false
                selectIconFile()
            }
        }
        .padding(16)
        .frame(maxWidth: 360)
        .onDrop(of: [UTType.image], isTargeted: nil) { providers in
            handleIconDrop(providers)
        }
    }

    private func iconTile<Icon: View>(
        selected: Bool,
        showBackground: Bool = true,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        let cornerRadius = 80 * 185.4 / 1024
        return Button(action: action) {
            ZStack {
                if showBackground {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 80, height: 80)
                }
                icon()
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
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
        // In UI testing mode, inject mock settings instead of reading from disk
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            self.cpuCount = "6"
            self.memoryGiB = "16"
            self.diskGiB = "128"
            self.portForwards = [
                PortForwardConfig(hostPort: 8080, guestPort: 80),
                PortForwardConfig(hostPort: 3000, guestPort: 3000),
                PortForwardConfig(hostPort: 5432, guestPort: 5432),
            ]
            self.sharedFolders = [
                SharedFolderConfig(path: "/Users/jake/Projects", readOnly: true),
                SharedFolderConfig(path: "/Users/jake/shared-data", readOnly: false),
            ]
            self.isLoading = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let controller = VMController()
            do {
                let config = try controller.storedConfig(at: vm.bundleURL)
                DispatchQueue.main.async {
                    self.cpuCount = "\(config.cpus)"
                    self.memoryGiB = "\(config.memoryBytes / (1 << 30))"
                    self.diskGiB = "\(config.diskBytes / (1 << 30))"

                    // Load shared folders: prefer new array, fall back to legacy single folder
                    if !config.sharedFolders.isEmpty {
                        self.sharedFolders = config.sharedFolders
                    } else if let legacyPath = config.sharedFolderPath {
                        self.sharedFolders = [SharedFolderConfig(path: legacyPath, readOnly: config.sharedFolderReadOnly)]
                    } else {
                        self.sharedFolders = []
                    }

                    // Load port forwards
                    self.portForwards = config.portForwards

                    // Load network config
                    self.networkConfig = config.networkConfig ?? NetworkConfig.defaultConfig

                    // Load icon mode
                    self.isDynamicIconMode = config.iconMode == "stack"
                    self.isAppIconMode = config.iconMode == "app"
                    self.isGlassIconMode = config.iconMode == "glass"

                    // Load custom icon
                    let layout = VMFileLayout(bundleURL: vm.bundleURL)
                    if FileManager.default.fileExists(atPath: layout.customIconURL.path) {
                        self.customIcon = NSImage(contentsOf: layout.customIconURL)
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

                // Filter out invalid port forwards (both ports must be > 0)
                let validForwards = portForwards.filter { $0.hostPort > 0 && $0.guestPort > 0 }

                try controller.updateVMSettings(
                    bundleURL: vm.bundleURL,
                    cpus: cpus,
                    memoryGiB: memory,
                    sharedFolders: validFolders,
                    portForwards: validForwards
                )

                // Save icon mode and network config
                let layout = VMFileLayout(bundleURL: vm.bundleURL)
                let store = VMConfigStore(layout: layout)
                var storedConfig = try store.load()
                if isDynamicIconMode {
                    storedConfig.iconMode = "stack"
                } else if isAppIconMode {
                    storedConfig.iconMode = "app"
                } else if isGlassIconMode {
                    storedConfig.iconMode = "glass"
                } else {
                    storedConfig.iconMode = nil
                }
                storedConfig.networkConfig = networkConfig
                try store.save(storedConfig)

                // Save or remove custom icon
                if isDynamicIconMode || isAppIconMode || isGlassIconMode {
                    // Dynamic modes — don't touch icon.png
                } else if customIconChanged {
                    if iconRemoved {
                        try? FileManager.default.removeItem(at: layout.customIconURL)
                        NSWorkspace.shared.setIcon(nil, forFile: vm.bundleURL.path, options: [])
                    } else if let icon = customIcon,
                              let tiff = icon.tiffRepresentation,
                              let bitmap = NSBitmapImageRep(data: tiff),
                              let pngData = bitmap.representation(using: .png, properties: [:]) {
                        try pngData.write(to: layout.customIconURL)
                        NSWorkspace.shared.setIcon(icon, forFile: vm.bundleURL.path, options: [])
                    }
                }

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

    private func selectIconFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.png, UTType.jpeg, UTType.tiff, UTType.heic]
        panel.message = "Choose an icon image for this VM"

        if panel.runModal() == .OK, let url = panel.url,
           let image = NSImage(contentsOf: url) {
            customIcon = image
            selectedPresetIcon = nil
            isDynamicIconMode = false
            isAppIconMode = false
            isGlassIconMode = false
            customIconChanged = true
            iconRemoved = false
        }
    }

    private func handleIconDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                DispatchQueue.main.async {
                    if let url = item as? URL, let image = NSImage(contentsOf: url) {
                        self.customIcon = image
                        self.selectedPresetIcon = nil
                        self.isDynamicIconMode = false
                        self.isAppIconMode = false
                        self.isGlassIconMode = false
                        self.customIconChanged = true
                        self.iconRemoved = false
                    } else if let data = item as? Data, let image = NSImage(data: data) {
                        self.customIcon = image
                        self.selectedPresetIcon = nil
                        self.isDynamicIconMode = false
                        self.isAppIconMode = false
                        self.isGlassIconMode = false
                        self.customIconChanged = true
                        self.iconRemoved = false
                    }
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Port Forward Editor (Runtime)

@available(macOS 13.0, *)
struct PortForwardEditorView: View {
    @ObservedObject var session: App2VMRunSession
    @ObservedObject var portForwardService: PortForwardService
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Port Forwards")
                .font(.headline)

            PortForwardCallbackListView(
                forwards: portForwardService.activeForwards,
                onAdd: { host, guest in
                    do {
                        try session.addPortForward(hostPort: host, guestPort: guest)
                        return nil
                    } catch {
                        return "Port \(host) already in use"
                    }
                },
                onRemove: { hostPort in
                    session.removePortForward(hostPort: hostPort)
                }
            )

            if let runtimeError = portForwardService.lastRuntimeError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Forward localhost:\(runtimeError.hostPort) -> guest:\(runtimeError.guestPort) failed (\(runtimeError.phase.rawValue)): \(runtimeError.message)"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)

                    Button("Dismiss") {
                        portForwardService.clearRuntimeError()
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
        .frame(width: 300)
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
    let playRecovery: () -> Void
    let requestDelete: () -> Void
    let requestCreateSnapshot: () -> Void
    let requestRevertSnapshot: (String) -> Void
    let requestDeleteSnapshot: (String) -> Void
    let requestEdit: () -> Void
    let requestTerminate: () -> Void
    let requestInstall: () -> Void
    let requestRename: () -> Void
    let requestClone: () -> Void
    @EnvironmentObject private var store: App2VMStore

    init(
        vm: App2VM,
        play: @escaping () -> Void,
        playRecovery: @escaping () -> Void = {},
        requestDelete: @escaping () -> Void,
        requestCreateSnapshot: @escaping () -> Void,
        requestRevertSnapshot: @escaping (String) -> Void,
        requestDeleteSnapshot: @escaping (String) -> Void,
        requestEdit: @escaping () -> Void = {},
        requestTerminate: @escaping () -> Void = {},
        requestInstall: @escaping () -> Void = {},
        requestRename: @escaping () -> Void = {},
        requestClone: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.play = play
        self.playRecovery = playRecovery
        self.requestDelete = requestDelete
        self.requestCreateSnapshot = requestCreateSnapshot
        self.requestRevertSnapshot = requestRevertSnapshot
        self.requestDeleteSnapshot = requestDeleteSnapshot
        self.requestEdit = requestEdit
        self.requestTerminate = requestTerminate
        self.requestInstall = requestInstall
        self.requestRename = requestRename
        self.requestClone = requestClone
    }

    var body: some View {
        let lowerStatus = vm.status.lowercased()
        let isRunning = lowerStatus.contains("running") || lowerStatus.contains("starting") || lowerStatus.contains("stopping")
        let isSuspended = lowerStatus.contains("suspended")
        let canSuspend = lowerStatus.contains("running")
        let canShutDown = lowerStatus.contains("running")

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

        Button("Boot to Recovery") {
            playRecovery()
        }
        .disabled(vm.needsInstall || isRunning)

        Button("Suspend") {
            App2VMSessionRegistry.shared.session(for: vm.bundlePath)?.suspend()
        }
        .disabled(!canSuspend)

        Button("Shut Down") {
            App2VMSessionRegistry.shared.session(for: vm.bundlePath)?.stop()
        }
        .disabled(!canShutDown)

        Button("Terminate") {
            requestTerminate()
        }
        .disabled(!isRunning && !isSuspended)

        Button("Edit Settings…") {
            requestEdit()
        }
        .disabled(isRunning)

        Button("Rename…") {
            requestRename()
        }
        .disabled(isRunning)

        Button("Clone…") {
            requestClone()
        }
        .disabled(isRunning || !vm.installed)

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
    @StateObject private var fileTransferService = FileTransferService()
    @StateObject private var healthCheckService = HealthCheckService()
    @State private var ghostToolsInstallState: GhostToolsInstallState = .notInstalled
    @AppStorage("captureSystemKeys") private var captureSystemKeys: Bool = true
    @State private var showPortForwardEditor = false
    @State private var shutDownCooldown = false

    init(vm: App2VM) {
        self.vm = vm
        _session = StateObject(wrappedValue: App2VMRunSession(bundleURL: vm.bundleURL))
    }

    private var activePortForwards: [PortForwardConfig] {
        session.portForwardService?.activeForwards ?? []
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

    private var ghostToolsToolbarPresentation: GhostToolsToolbarPresentation {
        GhostToolsToolbarPolicy.presentation(
            installState: ghostToolsInstallState,
            healthStatus: healthCheckService.status
        )
    }

    private var ghostToolsStatusText: String {
        switch healthCheckService.status {
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .notFound:
            return "Not Found"
        }
    }

    private var ghostToolsStatusColor: Color {
        switch healthCheckService.status {
        case .connected:
            return .green
        case .notFound:
            return .red
        case .connecting:
            return .yellow
        }
    }

    private func openGhostToolsInstallDocs() {
        guard let url = URL(string: "https://ghostvm.org/docs/ghosttools") else { return }
        NSWorkspace.shared.open(url)
    }

    var body: some View {
        ZStack {
            App2VMDisplayHost(virtualMachine: session.virtualMachine, captureSystemKeys: captureSystemKeys, fileTransferService: fileTransferService)
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

            // File transfer progress overlay
            if fileTransferService.isTransferring {
                VStack {
                    Spacer()
                    FileTransferProgressView(transfers: fileTransferService.transfers)
                        .padding()
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Group {
                    switch ghostToolsToolbarPresentation {
                    case .installCallToAction:
                        Button("Install Ghost Tools") {
                            openGhostToolsInstallDocs()
                        }
                    case .liveStatus:
                        HStack(spacing: 4) {
                            Circle()
                                .fill(ghostToolsStatusColor)
                                .frame(width: 8, height: 8)
                            Text("Guest Tools: \(ghostToolsStatusText)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .help(
                    ghostToolsToolbarPresentation == .installCallToAction
                    ? "Install Ghost Tools in the guest VM"
                    : "Ghost Tools status: \(ghostToolsStatusText)"
                )
            }
            ToolbarItem(placement: .automatic) {
                Menu {
                    if !activePortForwards.isEmpty {
                        ForEach(activePortForwards) { forward in
                            Button {
                                // Copy the localhost URL to clipboard
                                let urlString = "http://localhost:\(forward.hostPort)"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(urlString, forType: .string)
                            } label: {
                                HStack {
                                    Text(verbatim: "localhost:\(forward.hostPort)")
                                    Image(systemName: "arrow.right")
                                    Text(verbatim: "guest:\(forward.guestPort)")
                                }
                            }
                        }
                        Divider()
                        Text("Click to copy URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                    }
                    Button("Edit Port Forwards…") {
                        showPortForwardEditor = true
                    }
                } label: {
                    Label(activePortForwards.isEmpty ? "Ports" : "\(activePortForwards.count)", systemImage: "network")
                }
                .help(activePortForwards.isEmpty ? "No port forwards configured" : "Port Forwards: \(activePortForwards.map { "\($0.hostPort)→\($0.guestPort)" }.joined(separator: ", "))")
                .popover(isPresented: $showPortForwardEditor) {
                    if let service = session.portForwardService {
                        PortForwardEditorView(session: session, portForwardService: service, isPresented: $showPortForwardEditor)
                    } else {
                        Text("Port forwarding not available")
                            .padding()
                    }
                }
            }
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
            if fileTransferService.queuedGuestFileCount > 0 {
                ToolbarItem(placement: .automatic) {
                    Button {
                        fileTransferService.fetchAllGuestFiles()
                    } label: {
                        Label("\(fileTransferService.queuedGuestFileCount)", systemImage: "arrow.down.doc")
                    }
                    .help("Receive \(fileTransferService.queuedGuestFileCount) file(s) from guest")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.stop()
                    shutDownCooldown = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        shutDownCooldown = false
                    }
                } label: {
                    Label("Shut Down", systemImage: "stop.fill")
                }
                .disabled(!isRunning || shutDownCooldown)
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
            session.onStateChange = { [vmID = vm.id, bundleURL = vm.bundleURL, store, weak fileTransferService] state in
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
        .onChange(of: session.virtualMachine) { _, vm in
            // Configure services when VM becomes available
            if let vm = vm, let queue = session.vmQueue {
                let client = GhostClient(virtualMachine: vm, vmQueue: queue)
                fileTransferService.configure(client: client)
                healthCheckService.start(client: client)
            } else {
                healthCheckService.stop()
            }
        }
        .onChange(of: healthCheckService.status) { _, status in
            ghostToolsInstallState.record(healthStatus: status)
        }
        .onDisappear {
            healthCheckService.stop()
            session.stopIfNeeded()
        }
        .focusedSceneValue(\.vmSession, session)
    }
}

@available(macOS 13.0, *)
struct SettingsDemoView: View {
    @Environment(\.sparkleUpdater) private var updater
    @State private var vmPath: String
    @State private var ipswPath: String
    @State private var feedURLString: String
    @State private var verificationMessage: String? = nil
    @State private var verificationWasSuccessful: Bool? = nil
    @State private var isVerifying: Bool = false
    @State private var autoCheckForUpdates: Bool = true

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
                        .accessibilityIdentifier("settings.vmPathField")
                    Button("Browse…") {
                        // Intentionally no-op in demo app.
                    }
                    .accessibilityIdentifier("settings.browseVMsButton")
                }
            }

            labeledRow("IPSW Cache") {
                HStack(spacing: 8) {
                    TextField("Path to IPSW cache", text: $ipswPath)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.ipswPathField")
                    Button("Browse…") {
                        // Intentionally no-op in demo app.
                    }
                }
            }

            labeledRow("IPSW Feed URL") {
                HStack(spacing: 8) {
                    TextField("https://mesu.apple.com/…", text: $feedURLString)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("settings.feedURLField")
                    Button("Verify") {
                        verifyFeedURL()
                    }
                    .disabled(isVerifying)
                    .accessibilityIdentifier("settings.verifyButton")
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

            labeledRow("App Icon") {
                Picker("", selection: Binding(
                    get: { AppIconAdapter.shared.iconMode },
                    set: { AppIconAdapter.shared.iconMode = $0 }
                )) {
                    ForEach(DemoIconMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
                .accessibilityIdentifier("settings.appIconPicker")
            }

            if updater != nil {
                labeledRow("Updates") {
                    Toggle("Automatically check for updates", isOn: $autoCheckForUpdates)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("settings.autoUpdateToggle")
                        .onChange(of: autoCheckForUpdates) { _, newValue in
                            updater?.automaticallyChecksForUpdates = newValue
                        }
                }
            }

            Spacer()
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        .frame(minWidth: 520, minHeight: 320)
        .onAppear {
            if let updater = updater {
                autoCheckForUpdates = updater.automaticallyChecksForUpdates
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
                                ? "Delete"
                                : image.isDownloading
                                    ? "Cancel"
                                    : image.hasPartialDownload ? "Resume" : "Download"
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
        .alert(
            "Verification Failed",
            isPresented: Binding(
                get: { store.verificationFailure != nil },
                set: { if !$0 { store.verificationFailure = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let failure = store.verificationFailure {
                    store.trashFailedImage(filename: failure.filename)
                }
                store.verificationFailure = nil
            }
            Button("Keep", role: .cancel) {
                store.verificationFailure = nil
            }
        } message: {
            if let failure = store.verificationFailure {
                Text("The SHA-1 checksum for \"\(failure.filename)\" does not match the expected value from the feed.\n\nExpected: \(failure.expected)\nActual: \(failure.actual)")
            }
        }
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

// MARK: - File Transfer Progress View

@available(macOS 13.0, *)
struct FileTransferProgressView: View {
    let transfers: [FileTransfer]

    private var activeTransfers: [FileTransfer] {
        transfers.filter { $0.state.isActive }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(activeTransfers) { transfer in
                HStack(spacing: 12) {
                    Image(systemName: transfer.direction == .hostToGuest ? "arrow.up.doc.fill" : "arrow.down.doc.fill")
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(transfer.filename)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if case .transferring(let progress) = transfer.state {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(.white)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(.white)
                        }
                    }

                    Text(transfer.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(radius: 8)
        )
        .frame(maxWidth: 300)
    }
}
