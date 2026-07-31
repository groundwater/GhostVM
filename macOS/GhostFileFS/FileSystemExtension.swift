import ExtensionFoundation
import FSKit

@main
struct GhostFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: GhostFileSystem {
        GhostFileSystem()
    }
}
