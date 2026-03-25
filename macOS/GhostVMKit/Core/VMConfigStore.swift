import Foundation

/// Handles loading and saving VM configuration to config.json.
public final class VMConfigStore {
    private let layout: VMFileLayout

    public init(layout: VMFileLayout) {
        self.layout = layout
    }

    public func load() throws -> VMStoredConfig {
        let data = try Data(contentsOf: layout.configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var config = try decoder.decode(VMStoredConfig.self, from: data)
        if config.normalize(relativeTo: layout) {
            try save(config)
        }
        return config
    }

    public func save(_ config: VMStoredConfig) throws {
        var updated = config
        updated.modifiedAt = Date()
        _ = updated.normalize(relativeTo: layout)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(updated)
        try data.write(to: layout.configURL, options: .atomic)
    }
}
