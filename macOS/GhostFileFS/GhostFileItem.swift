import FSKit
import Foundation

final class GhostFileItem: FSItem {
    let relativePath: String
    let parentID: FSItem.Identifier
    private let lock = NSLock()
    private var storedMetadata: GhostFileMetadata

    init(relativePath: String, parentID: FSItem.Identifier, metadata: GhostFileMetadata) {
        self.relativePath = relativePath
        self.parentID = parentID
        self.storedMetadata = metadata
    }

    var metadata: GhostFileMetadata {
        lock.lock()
        defer { lock.unlock() }
        return storedMetadata
    }

    func update(metadata: GhostFileMetadata) {
        lock.lock()
        storedMetadata = metadata
        lock.unlock()
    }
}
