import ExtensionFoundation
import FSKit
import GhostFileKit

@main
struct GhostFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: GhostFileSystem {
        GhostFileSystem()
    }
}
