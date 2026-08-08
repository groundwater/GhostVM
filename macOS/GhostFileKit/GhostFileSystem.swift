import Foundation
import FSKit

public final class GhostFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    public override init() {
        super.init()
    }

    public func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let resource = resource as? FSGenericURLResource,
              Self.validResourceURL(resource.url),
              let shareID = Self.shareID(from: resource.url) else {
            return .notRecognized
        }
        let mountID = GhostFileProtocol.mountInstanceID(from: resource.url) ?? shareID
        return .usable(
            name: "GhostFile",
            containerID: FSContainerIdentifier(uuid: mountID)
        )
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        guard let resource = resource as? FSGenericURLResource,
              Self.validResourceURL(resource.url),
              let shareID = Self.shareID(from: resource.url) else {
            throw fs_errorForPOSIXError(ENOTSUP)
        }
        let mountID = GhostFileProtocol.mountInstanceID(from: resource.url) ?? shareID
        let client = try GhostFileHTTP3Client(resourceURL: resource.url)
        let capabilities = try await client.capabilities()
        guard capabilities.protocolVersion == GhostFileProtocol.version,
              capabilities.shareID == shareID else {
            throw fs_errorForPOSIXError(ENOTSUP)
        }
        await client.startHealthMonitoring()
        containerStatus = .ready
        return GhostFileVolume(
            // LiveFS performs its final connector lookup using this identity.
            // Use the same unqualified per-mount UUID returned by probeResource.
            volumeID: FSVolume.Identifier(uuid: mountID),
            volumeName: FSFileName(string: capabilities.name),
            client: client,
            readOnly: capabilities.readOnly
        )
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}

    private static func validResourceURL(_ url: URL) -> Bool {
        guard url.scheme == GhostFileProtocol.urlScheme,
              url.host != nil,
              url.port != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "access_key" && !($0.value ?? "").isEmpty }) == true,
              GhostFileProtocol.peerPin(from: url) != nil else {
            return false
        }
        return shareID(from: url) != nil
    }

    private static func shareID(from url: URL) -> UUID? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "v1", parts[1] == "shares" else { return nil }
        return UUID(uuidString: String(parts[2]))
    }
}
