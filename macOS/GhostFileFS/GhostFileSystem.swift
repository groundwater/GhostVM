import Foundation
import FSKit

final class GhostFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    func probeResource(resource: FSResource) async throws -> FSProbeResult {
        guard let resource = resource as? FSGenericURLResource,
              Self.validResourceURL(resource.url),
              let shareID = Self.shareID(from: resource.url) else {
            return .notRecognized
        }
        return .usable(
            name: "GhostFile",
            containerID: FSContainerIdentifier(uuid: shareID)
        )
    }

    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume {
        guard let resource = resource as? FSGenericURLResource,
              Self.validResourceURL(resource.url),
              let shareID = Self.shareID(from: resource.url) else {
            throw fs_errorForPOSIXError(ENOTSUP)
        }
        let client = try GhostFileHTTP3Client(resourceURL: resource.url)
        let capabilities = try await client.capabilities()
        guard capabilities.protocolVersion == GhostFileProtocol.version,
              capabilities.shareID == shareID,
              capabilities.readOnly else {
            throw fs_errorForPOSIXError(ENOTSUP)
        }
        containerStatus = .ready
        return GhostFileVolume(
            volumeID: FSVolume.Identifier(uuid: shareID),
            volumeName: FSFileName(string: capabilities.name),
            client: client
        )
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {}

    private static func validResourceURL(_ url: URL) -> Bool {
        guard url.scheme == GhostFileProtocol.urlScheme,
              url.host != nil,
              url.port != nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "access_key" && !($0.value ?? "").isEmpty }) == true,
              components.queryItems?.contains(where: { $0.name == "tls_pin" && !($0.value ?? "").isEmpty }) == true else {
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
