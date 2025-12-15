import Foundation

/// Validate and sanitize a snapshot name.
public func sanitizedSnapshotName(_ name: String) throws -> String {
    guard name.range(of: #"[\/]"#, options: .regularExpression) == nil else {
        throw VMError.message("Snapshot name cannot contain path separators.")
    }
    guard !name.isEmpty else {
        throw VMError.message("Snapshot name must not be empty.")
    }
    return name
}

/// Copy an item, removing the destination first if it exists.
public func copyItem(from source: URL, to destination: URL) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
}
