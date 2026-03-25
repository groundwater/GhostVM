import Foundation

/// Configuration for a single shared folder.
public struct SharedFolderConfig: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var path: String
    public var readOnly: Bool

    public init(id: UUID = UUID(), path: String, readOnly: Bool = true) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
    }

    /// Normalize the path by expanding tilde and resolving to absolute path.
    public mutating func normalize() -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = expanded.isEmpty ? path : expanded
        let absolute = URL(fileURLWithPath: resolved).standardizedFileURL.path
        if absolute != path {
            path = absolute
            return true
        }
        return false
    }
}
