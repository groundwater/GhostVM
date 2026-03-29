import Foundation

/// Handles loading and saving router configurations to JSON files.
/// Stores each network as `{id}.json` in `~/Library/Application Support/org.ghostvm.GhostVM/Networks/`.
/// Transparently migrates legacy `CustomNetworkConfig` JSON on read.
public final class CustomNetworkStore {

    public static let shared = CustomNetworkStore()

    private let networksDirectory: URL

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        networksDirectory = appSupport
            .appendingPathComponent("org.ghostvm.GhostVM", isDirectory: true)
            .appendingPathComponent("Networks", isDirectory: true)
    }

    /// For testing: init with a custom directory.
    public init(directory: URL) {
        networksDirectory = directory
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: networksDirectory, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        networksDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Decode a single JSON file, trying RouterConfig first then falling back to legacy CustomNetworkConfig.
    private func decodeRouter(from data: Data) throws -> RouterConfig {
        if let router = try? decoder.decode(RouterConfig.self, from: data) {
            return router
        }
        let legacy = try decoder.decode(CustomNetworkConfig.self, from: data)
        return RouterConfig(migratingFrom: legacy)
    }

    /// List all saved networks, sorted by name.
    public func list() throws -> [RouterConfig] {
        try ensureDirectory()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: networksDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> RouterConfig? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decodeRouter(from: data)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Get a single network by ID.
    public func get(_ id: UUID) throws -> RouterConfig? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decodeRouter(from: data)
    }

    /// Save (create or update) a network.
    public func save(_ config: RouterConfig) throws {
        try ensureDirectory()
        var updated = config
        updated.modifiedAt = Date()
        let data = try encoder.encode(updated)
        try data.write(to: fileURL(for: updated.id), options: .atomic)
    }

    /// Delete a network by ID.
    public func delete(_ id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
