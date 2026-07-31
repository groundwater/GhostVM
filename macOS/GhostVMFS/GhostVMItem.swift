import FSKit

final class GhostVMItem: FSItem {
    let relativePath: String
    let parentID: FSItem.Identifier
    var metadata: GhostVMFileMetadata

    init(relativePath: String, parentID: FSItem.Identifier, metadata: GhostVMFileMetadata) {
        self.relativePath = relativePath
        self.parentID = parentID
        self.metadata = metadata
    }
}
