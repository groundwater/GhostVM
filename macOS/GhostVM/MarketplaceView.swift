import SwiftUI

// MARK: - Models

enum MarketplaceCategory: String, Codable, CaseIterable, Identifiable {
    case iconSet
    case theme
    case extension_

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iconSet: return "Icon Set"
        case .theme: return "Theme"
        case .extension_: return "Extension"
        }
    }
}

struct MarketplaceItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: MarketplaceCategory
    let description: String
    let price: String
    let priceValue: Double
    let iconName: String
    let previewImageNames: [String]
    let author: String
    let version: String
}

// MARK: - Store

@available(macOS 13.0, *)
class MarketplaceStore: ObservableObject {
    @Published var items: [MarketplaceItem] = []
    @Published var searchText: String = ""
    @Published var ownedItemIDs: Set<String> = [] {
        didSet { Self.persistOwnedIDs(ownedItemIDs) }
    }

    private static let ownedKey = "marketplace_ownedItemIDs"

    func isOwned(_ item: MarketplaceItem) -> Bool {
        ownedItemIDs.contains(item.id)
    }

    func toggleOwnership(_ item: MarketplaceItem) {
        if ownedItemIDs.contains(item.id) {
            ownedItemIDs.remove(item.id)
        } else {
            ownedItemIDs.insert(item.id)
        }
    }

    var filteredItems: [MarketplaceItem] {
        if searchText.isEmpty { return items }
        let query = searchText.lowercased()
        return items.filter {
            $0.name.lowercased().contains(query) ||
            $0.category.displayName.lowercased().contains(query) ||
            $0.author.lowercased().contains(query)
        }
    }

    init() {
        ownedItemIDs = Self.loadOwnedIDs()
        loadItems()
    }

    private func loadItems() {
        guard let url = Bundle.main.url(forResource: "marketplace", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            NSLog("[Marketplace] marketplace.json not found in bundle")
            return
        }
        do {
            items = try JSONDecoder().decode([MarketplaceItem].self, from: data)
        } catch {
            NSLog("[Marketplace] Failed to decode marketplace.json: \(error)")
        }
    }

    func purchase(_ item: MarketplaceItem) {
        NSLog("[Marketplace] Purchase requested: \(item.name) (\(item.price)) — no-op placeholder")
    }

    // MARK: - Persistence

    private static func loadOwnedIDs() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: ownedKey) ?? []
        return Set(array)
    }

    private static func persistOwnedIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: ownedKey)
    }

    // MARK: - Icon availability (used by EditVMView icon picker)

    /// Returns the set of icon resource names from owned marketplace icon sets.
    /// Reads directly from UserDefaults + bundled JSON so callers don't need a store instance.
    static func ownedIconResources() -> Set<String> {
        let ownedIDs = loadOwnedIDs()
        guard !ownedIDs.isEmpty,
              let url = Bundle.main.url(forResource: "marketplace", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([MarketplaceItem].self, from: data) else {
            return []
        }
        var resources = Set<String>()
        for item in items where ownedIDs.contains(item.id) && item.category == .iconSet {
            resources.formUnion(item.previewImageNames)
        }
        return resources
    }
}

// MARK: - Views

@available(macOS 13.0, *)
struct MarketplaceView: View {
    @StateObject private var store = MarketplaceStore()
    @State private var selectedItemID: MarketplaceItem.ID?

    var body: some View {
        NavigationSplitView {
            List(store.filteredItems, selection: $selectedItemID) { item in
                MarketplaceRowView(item: item)
                    .tag(item.id)
            }
            .searchable(text: $store.searchText, prompt: "Search marketplace")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selectedItemID,
               let item = store.items.first(where: { $0.id == id }) {
                MarketplaceDetailView(item: item, store: store)
            } else {
                Text("Select an item")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 460)
        .onAppear {
            if selectedItemID == nil {
                selectedItemID = store.items.first?.id
            }
        }
    }
}

@available(macOS 13.0, *)
struct MarketplaceRowView: View {
    let item: MarketplaceItem

    var body: some View {
        HStack(spacing: 10) {
            if let img = NSImage(named: item.iconName) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 40 * 185.4 / 1024, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 40 * 185.4 / 1024, style: .continuous)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body)
                    .lineLimit(1)
                Text(item.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@available(macOS 13.0, *)
struct MarketplaceDetailView: View {
    let item: MarketplaceItem
    let store: MarketplaceStore

    private let previewColumns = Array(repeating: GridItem(.fixed(80), spacing: 12), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack(spacing: 16) {
                        if let img = NSImage(named: item.iconName) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 80 * 185.4 / 1024, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 80 * 185.4 / 1024, style: .continuous)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 80, height: 80)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.title2.bold())
                            Text(item.category.displayName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Text(item.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("v\(item.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Description
                    Text(item.description)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)

                    // Preview grid
                    if !item.previewImageNames.isEmpty {
                        Text("Preview")
                            .font(.headline)

                        LazyVGrid(columns: previewColumns, alignment: .leading, spacing: 12) {
                            ForEach(item.previewImageNames, id: \.self) { name in
                                if let img = NSImage(named: name) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 80 * 185.4 / 1024, style: .continuous))
                                } else {
                                    RoundedRectangle(cornerRadius: 80 * 185.4 / 1024, style: .continuous)
                                        .fill(Color.secondary.opacity(0.15))
                                        .frame(width: 80, height: 80)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            // Bottom bar
            HStack {
                #if DEBUG
                Toggle(isOn: Binding(
                    get: { store.isOwned(item) },
                    set: { _ in store.toggleOwnership(item) }
                )) {
                    Label("Owned", systemImage: "ladybug")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                )
                #endif

                Spacer()

                if store.isOwned(item) {
                    Label("Owned", systemImage: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.green)
                } else {
                    Button {
                        store.purchase(item)
                    } label: {
                        Text("\(item.price) Buy")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }
}
