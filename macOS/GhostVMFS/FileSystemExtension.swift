import ExtensionFoundation
import FSKit
import GhostFileKit

@main
struct GhostVMFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: GhostFileSystem {
        GhostFileSystem()
    }
}
