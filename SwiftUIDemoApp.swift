import SwiftUI
import UniformTypeIdentifiers

@main
@available(macOS 13.0, *)
struct GhostVMSwiftUIApp: App {
    @StateObject private var store = App2VMStore()
    @StateObject private var restoreStore = App2RestoreImageStore()

    var body: some Scene {
        WindowGroup("GhostVM (SwiftUI Demo)", id: "main") {
            VMListDemoView()
                .environmentObject(store)
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
                Text("No VM selected")
                    .frame(minWidth: 320, minHeight: 200)
            }
        }
    }
}

@available(macOS 13.0, *)
struct DemoAppCommands: Commands {
    @ObservedObject var store: App2VMStore
    @ObservedObject var restoreStore: App2RestoreImageStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: [.command])
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
}

@available(macOS 13.0, *)
struct VMListDemoView: View {
    @EnvironmentObject private var store: App2VMStore
    @Environment(\.openWindow) private var openWindow

    @State private var selectedVMID: App2VM.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    // Placeholder create action.
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
                ForEach(store.vms) { vm in
                    VMRowView(
                        vm: vm,
                        isSelected: selectedVMID == vm.id,
                        play: {
                            openWindow(id: "vm", value: vm)
                        }
                    )
                    .tag(vm.id)
                    .contextMenu {
                        VMContextMenu(
                            vm: vm,
                            play: {
                                openWindow(id: "vm", value: vm)
                            }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 8))
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else {
                        return
                    }
                    DispatchQueue.main.async {
                        store.addBundles(from: [url])
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

@available(macOS 13.0, *)
struct VMRowView: View {
    let vm: App2VM
    let isSelected: Bool
    let play: () -> Void

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
                Button {
                    play()
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)

                Menu {
                    VMContextMenu(vm: vm, play: play)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 20, height: 20, alignment: .center)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .frame(width: 64, alignment: .trailing)
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

@available(macOS 13.0, *)
struct VMContextMenu: View {
    let vm: App2VM
    let play: () -> Void
    @EnvironmentObject private var store: App2VMStore

    var body: some View {
        let lowerStatus = vm.status.lowercased()
        let isRunning = lowerStatus.contains("running") || lowerStatus.contains("starting") || lowerStatus.contains("stopping")
        let isInstalled = lowerStatus != "not installed"

        Button("Start") {
            play()
        }
        .disabled(!isInstalled || isRunning)

        Button("Stop") {
            // VM stop is coordinated by closing the VM window; for now this
            // entry is present but handled via the window close behavior.
        }
        .disabled(!isRunning)

        Divider()
        Button("Show in Finder") {
            FinderAdapter.revealItem(at: vm.bundleURL)
        }
        Button("Remove from List") {
            store.removeFromList(vm)
        }
        Button("Delete") {
            store.deleteVM(vm)
        }
        .disabled(isRunning)
    }
}

@available(macOS 13.0, *)
struct VMWindowView: View {
    let vm: App2VM
    @EnvironmentObject private var store: App2VMStore
    @StateObject private var session: App2VMRunSession

    init(vm: App2VM) {
        self.vm = vm
        _session = StateObject(wrappedValue: App2VMRunSession(bundleURL: vm.bundleURL))
    }

    var body: some View {
        ZStack {
            App2VMDisplayHost(virtualMachine: session.virtualMachine)
                .frame(minWidth: 800, minHeight: 500)
                .ignoresSafeArea()
            // Invisible view that coordinates window close behavior with the VM.
            App2VMWindowCoordinatorHost(session: session)
                .frame(width: 0, height: 0)
        }
        .onAppear {
            session.onStateChange = { [vmID = vm.id, store] state in
                let status: String
                switch state {
                case .running:
                    status = "Running"
                case .starting:
                    status = "Starting…"
                case .stopping:
                    status = "Stopping…"
                case .stopped:
                    status = "Stopped"
                case .failed:
                    status = "Error"
                case .idle:
                    status = "Stopped"
                }
                store.updateStatus(for: vmID, status: status)
            }
            session.startIfNeeded()
        }
        .onDisappear {
            session.stopIfNeeded()
        }
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
