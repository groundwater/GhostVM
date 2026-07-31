import Foundation
import FSKit

final class GhostVMFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let resource = resource as? FSGenericURLResource,
              resource.url.scheme == "ghostvm",
              resource.url.host == "127.0.0.1",
              resource.url.port != nil,
              resource.url.pathComponents.count == 2,
              let resourceID = UUID(uuidString: resource.url.lastPathComponent) else {
            return .notRecognized
        }
        return .usable(
            name: "GhostVM",
            containerID: FSContainerIdentifier(uuid: resourceID)
        )
    }

    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        guard let resource = resource as? FSGenericURLResource,
              let resourceID = UUID(uuidString: resource.url.lastPathComponent) else {
            throw fs_errorForPOSIXError(ENOTSUP)
        }
        let client = try GhostVMFSClient(resourceURL: resource.url)
        containerStatus = .ready
        return GhostVMVolume(
            volumeID: FSVolume.Identifier(uuid: resourceID),
            volumeName: FSFileName(string: "GhostVM"),
            client: client
        )
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}
}
