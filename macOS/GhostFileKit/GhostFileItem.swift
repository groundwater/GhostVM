import FSKit
import Foundation

final class GhostFileItem: FSItem {
    private let lock = NSLock()
    private var storedRelativePath: String
    private var storedParentID: FSItem.Identifier
    private var storedMetadata: GhostFileMetadata

    init(relativePath: String, parentID: FSItem.Identifier, metadata: GhostFileMetadata) {
        self.storedRelativePath = relativePath
        self.storedParentID = parentID
        self.storedMetadata = metadata
    }

    var relativePath: String {
        lock.withLock { storedRelativePath }
    }

    var parentID: FSItem.Identifier {
        lock.withLock { storedParentID }
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

    func updateLocation(relativePath: String, parentID: FSItem.Identifier) {
        lock.lock()
        storedRelativePath = relativePath
        storedParentID = parentID
        lock.unlock()
    }
}
