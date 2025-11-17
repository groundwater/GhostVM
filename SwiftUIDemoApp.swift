import SwiftUI

// Simple in-memory model for demo VMs.
struct DemoVM: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var status: String
    var osVersion: String
}

struct DemoRestoreImage: Identifiable, Hashable {
    let id: UUID
    var name: String
    var version: String
    var build: String
    var sizeDescription: String
    var isDownloaded: Bool
}

final class DemoVMStore: ObservableObject {
    @Published var vms: [DemoVM] = [
        DemoVM(id: UUID(), name: "Sandbox", status: "Stopped", osVersion: "macOS 15.0"),
        DemoVM(id: UUID(), name: "CI Runner", status: "Running", osVersion: "macOS 14.5"),
        DemoVM(id: UUID(), name: "Legacy Test Rig", status: "Paused", osVersion: "macOS 13.6")
    ]

    func addSampleVM() {
        let index = vms.count + 1
        let vm = DemoVM(
            id: UUID(),
            name: "Demo VM \(index)",
            status: "Stopped",
            osVersion: "macOS 15.0"
        )
        vms.append(vm)
    }

    func resetToDefaults() {
        vms = [
            DemoVM(id: UUID(), name: "Sandbox", status: "Stopped", osVersion: "macOS 15.0"),
            DemoVM(id: UUID(), name: "CI Runner", status: "Running", osVersion: "macOS 14.5"),
            DemoVM(id: UUID(), name: "Legacy Test Rig", status: "Paused", osVersion: "macOS 13.6")
        ]
    }
}

final class DemoRestoreImageStore: ObservableObject {
    @Published var images: [DemoRestoreImage] = [
        DemoRestoreImage(
            id: UUID(),
            name: "Sonoma",
            version: "15.0",
            build: "24A123",
            sizeDescription: "13.2 GB",
            isDownloaded: true
        ),
        DemoRestoreImage(
            id: UUID(),
            name: "Ventura",
            version: "14.5",
            build: "23F79",
            sizeDescription: "12.8 GB",
            isDownloaded: false
        ),
        DemoRestoreImage(
            id: UUID(),
            name: "Monterey",
            version: "13.6",
            build: "22G120",
            sizeDescription: "11.9 GB",
            isDownloaded: false
        )
    ]

    func toggleDownload(for image: DemoRestoreImage) {
        guard let index = images.firstIndex(of: image) else { return }
        images[index].isDownloaded.toggle()
    }
}

@main
@available(macOS 13.0, *)
struct GhostVMSwiftUIApp: App {
    @StateObject private var store = DemoVMStore()
    @StateObject private var restoreStore = DemoRestoreImageStore()

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

        // Fake VM window shown when pressing Play.
        WindowGroup(id: "vm", for: DemoVM.self) { vmBinding in
            if let vm = vmBinding.wrappedValue {
                FakeVMWindowView(vm: vm)
            } else {
                Text("No VM selected")
                    .frame(minWidth: 320, minHeight: 200)
            }
        }
    }
}

@available(macOS 13.0, *)
struct DemoAppCommands: Commands {
    @ObservedObject var store: DemoVMStore
    @ObservedObject var restoreStore: DemoRestoreImageStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu("Demo VMs") {
            Button("New Demo VM") {
                store.addSampleVM()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Reset Demo Data") {
                store.resetToDefaults()
            }
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
    @EnvironmentObject private var store: DemoVMStore
    @Environment(\.openWindow) private var openWindow

    @State private var selectedVMID: DemoVM.ID?

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
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

@available(macOS 13.0, *)
struct VMRowView: View {
    let vm: DemoVM
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

    private func statusColor(for vm: DemoVM) -> Color {
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
    let vm: DemoVM
    let play: () -> Void

    var body: some View {
        Button("Start") {
            play()
        }
        Button("Stop") {
            // Placeholder stop action.
        }
        Divider()
        Button("Show in Finder") {
            // Placeholder show-in-finder action.
        }
        Button("Delete") {
            // Placeholder delete action.
        }
    }
}

@available(macOS 13.0, *)
struct SettingsDemoView: View {
    @State private var vmPath: String = "~/VMs"
    @State private var ipswPath: String = "~/Library/Application Support/GhostVM/IPSW"
    @State private var feedURLString: String = "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml"
    @State private var verificationMessage: String? = nil
    @State private var verificationWasSuccessful: Bool? = nil
    @State private var isVerifying: Bool = false
    @State private var showRacecarBackground: Bool = true
    @State private var iconMode: DemoIconMode = .system

    private let labelWidth: CGFloat = 130

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
                        // Intentionally no-op in demo app.
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

            HStack {
                Button("Reset to Default") {
                    // Intentionally no-op in demo app.
                }
                Spacer()
                Button("Cancel") {
                    // Intentionally no-op in demo app.
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Intentionally no-op in demo app.
                }
                .keyboardShortcut(.defaultAction)
            }
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
struct FakeVMWindowView: View {
    let vm: DemoVM

    var body: some View {
        ZStack {
            Color.black

            switch vm.status.lowercased() {
            case "stopped":
                Image(systemName: "play.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .foregroundStyle(.white)

            case "paused":
                ZStack {
                    Color.white.opacity(0.12)

                    Image(systemName: "play.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .foregroundStyle(.white)
                }

            default:
                VStack {
                    Text("Fake VM Display")
                        .foregroundStyle(.white)
                        .font(.headline)
                    Text("No real virtualization is happening here.")
                        .foregroundStyle(.gray)
                        .font(.subheadline)
                }
                .padding()
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

@available(macOS 13.0, *)
struct RestoreImagesDemoView: View {
    @EnvironmentObject private var store: DemoRestoreImageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Restore Images")
                .font(.title2.bold())

            Text("Review demo restore images and simulate downloads or deletions. This view mirrors the idea of the main app’s IPSW manager but uses only in-memory placeholder data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

                        Text(image.sizeDescription)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button(image.isDownloaded ? "Delete" : "Download") {
                            store.toggleDownload(for: image)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(EdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24))
        .frame(minWidth: 520, minHeight: 360)
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
