import SwiftUI
import GhostVMKit
import UniformTypeIdentifiers

@available(macOS 13.0, *)
struct CustomNetworkListView: View {
    @State private var networks: [RouterConfig] = []
    @State private var selectedID: UUID?
    @State private var errorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var pendingDeleteID: UUID?
    @State private var showImportPicker = false
    @State private var showExportPicker = false

    /// Names of VMs using each network (populated externally via .onAppear or binding).
    var vmNamesForNetwork: (UUID) -> [String] = { _ in [] }

    private let store = CustomNetworkStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Networks")
                .font(.headline)

            HStack(spacing: 0) {
                // Master list + toolbar
                VStack(spacing: 0) {
                    List(networks, selection: $selectedID) { network in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network.name)
                                .font(.body.weight(.medium))
                            Text(network.summaryLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(network.id)
                        .accessibilityIdentifier("customNetworks.row.\(network.name)")
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))

                    listToolbar
                }
                .frame(width: 240)

                Divider()

                // Detail editor
                if let selectedID, let binding = bindingForNetwork(selectedID) {
                    RouterDetailView(
                        router: binding,
                        vmNames: vmNamesForNetwork(selectedID)
                    )
                    .padding(.leading, 8)
                } else {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear {
            loadNetworks()
        }
        .alert("Delete Network?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID {
                    deleteNetwork(id)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            if let id = pendingDeleteID {
                let vmNames = vmNamesForNetwork(id)
                if vmNames.isEmpty {
                    Text("This network will be permanently deleted.")
                } else {
                    Text("This network is used by: \(vmNames.joined(separator: ", ")). Those VMs will switch to NAT mode.")
                }
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            importNetworks(result)
        }
        .fileExporter(
            isPresented: $showExportPicker,
            document: selectedNetworkDocument,
            contentType: .json,
            defaultFilename: selectedExportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - List Toolbar (+/–/...)

    private var listToolbar: some View {
        HStack(spacing: 0) {
            Button(action: addNetwork) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("customNetworks.addButton")

            Divider()
                .frame(height: 16)

            Button {
                if let id = selectedID {
                    pendingDeleteID = id
                    showDeleteConfirmation = true
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(selectedID == nil)
            .accessibilityIdentifier("customNetworks.removeButton")

            Spacer()

            Menu {
                Button("Import Network\u{2026}") {
                    showImportPicker = true
                }
                .accessibilityIdentifier("customNetworks.importButton")

                Button("Export Selected\u{2026}") {
                    showExportPicker = true
                }
                .disabled(selectedID == nil)
                .accessibilityIdentifier("customNetworks.exportButton")

                Divider()

                Button("Duplicate") {
                    duplicateSelected()
                }
                .disabled(selectedID == nil)
                .accessibilityIdentifier("customNetworks.duplicateButton")
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("customNetworks.actionsMenu")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        if networks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No Custom Networks")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Create a custom network to configure virtual LANs with DHCP, routing, and firewall rules.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 240)
                Button("Create Network") { addNetwork() }
                    .accessibilityIdentifier("customNetworks.createFirstButton")
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a network to edit")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Import / Export

    private var selectedNetworkDocument: NetworkJSONDocument? {
        guard let id = selectedID,
              let network = networks.first(where: { $0.id == id }) else { return nil }
        return NetworkJSONDocument(router: network)
    }

    private var selectedExportFilename: String {
        guard let id = selectedID,
              let network = networks.first(where: { $0.id == id }) else { return "network.json" }
        let safe = network.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return (safe.isEmpty ? "network" : safe) + ".json"
    }

    private func importNetworks(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = "Import failed: \(error.localizedDescription)"
        case .success(let urls):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var imported = 0
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try Data(contentsOf: url)
                    // Try RouterConfig first, fall back to legacy
                    var config: RouterConfig
                    if let router = try? decoder.decode(RouterConfig.self, from: data) {
                        config = router
                    } else {
                        let legacy = try decoder.decode(CustomNetworkConfig.self, from: data)
                        config = RouterConfig(migratingFrom: legacy)
                    }
                    // Assign new ID to avoid collisions
                    config.id = UUID()
                    config.name = config.name + " (imported)"
                    config.createdAt = Date()
                    config.modifiedAt = Date()
                    try store.save(config)
                    networks.append(config)
                    selectedID = config.id
                    imported += 1
                } catch {
                    errorMessage = "Failed to import \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            if imported > 0 {
                errorMessage = nil
            }
        }
    }

    // MARK: - Data Operations

    private func loadNetworks() {
        do {
            networks = try store.list()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load networks: \(error.localizedDescription)"
        }
    }

    private func addNetwork() {
        let newNetwork = RouterConfig()
        do {
            try store.save(newNetwork)
            networks.append(newNetwork)
            selectedID = newNetwork.id
            errorMessage = nil
        } catch {
            errorMessage = "Failed to create network: \(error.localizedDescription)"
        }
    }

    private func deleteNetwork(_ id: UUID) {
        do {
            try store.delete(id)
            networks.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
            pendingDeleteID = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to delete network: \(error.localizedDescription)"
        }
    }

    private func duplicateSelected() {
        guard let id = selectedID,
              let source = networks.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " Copy"
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        do {
            try store.save(copy)
            networks.append(copy)
            selectedID = copy.id
            errorMessage = nil
        } catch {
            errorMessage = "Failed to duplicate: \(error.localizedDescription)"
        }
    }

    private func saveCurrentNetwork(_ config: RouterConfig) {
        do {
            try store.save(config)
            if let idx = networks.firstIndex(where: { $0.id == config.id }) {
                networks[idx] = config
            }
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save network: \(error.localizedDescription)"
        }
    }

    private func bindingForNetwork(_ id: UUID) -> Binding<RouterConfig>? {
        guard let idx = networks.firstIndex(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { networks[idx] },
            set: { newValue in
                networks[idx] = newValue
                saveCurrentNetwork(newValue)
            }
        )
    }
}

// MARK: - JSON Document for Export

struct NetworkJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(router: RouterConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.data = (try? encoder.encode(router)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
