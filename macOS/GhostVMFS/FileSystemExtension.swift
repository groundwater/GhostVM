import ExtensionFoundation
import FSKit

@main
struct GhostVMFileSystemExtension: UnaryFileSystemExtension {
    var fileSystem: GhostVMFileSystem {
        GhostVMFileSystem()
    }
}
