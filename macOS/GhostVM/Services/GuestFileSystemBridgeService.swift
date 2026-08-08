import Foundation
import GhostFileKit
import GhostVMKit

/// Owns short-lived, loopback-only GhostFile shares used as backing stores for
/// private container volume mounts.
@MainActor
final class GuestFileSystemBridgeService {
    struct RegisteredExport: Sendable {
        let id: String
        let resourceURL: URL
    }

    private struct Export {
        let server: GhostFileShareServer
    }

    private weak var client: (any GhostClientProtocol)?
    private var exports: [String: Export] = [:]
    private var isRunning = false

    func start(client: any GhostClientProtocol) throws {
        guard !isRunning else { return }
        self.client = client
        isRunning = true
    }

    func stop() {
        for export in exports.values {
            export.server.stop()
        }
        exports.removeAll()
        client = nil
        isRunning = false
    }

    func registerExport(
        guestPath: String,
        readOnly: Bool = true,
        cacheTTLSeconds: UInt64 = GhostFileProtocol.defaultCacheTTLSeconds
    ) async throws -> RegisteredExport {
        guard isRunning else { throw BridgeError.notRunning }
        guard guestPath.hasPrefix("/"), !guestPath.contains("\0") else {
            throw BridgeError.invalidGuestPath
        }
        guard cacheTTLSeconds <= GhostFileProtocol.maximumCacheTTLSeconds else {
            throw BridgeError.invalidCacheTTL
        }
        guard exports.count < 32 else { throw BridgeError.tooManyExports }
        guard let client else { throw BridgeError.guestUnavailable }

        let id = UUID().uuidString.lowercased()
        let shareID = UUID()
        let accessKey = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        let identity = try GhostFileTLSIdentity.make()
        let server = GhostFileShareServer(
            provider: GuestPathProvider(client: client, root: guestPath),
            shareName: "GhostVM Container Volume",
            accessKey: accessKey,
            shareID: shareID,
            readOnly: readOnly,
            tlsIdentity: identity,
            visibility: .loopbackOnly,
            advertisesBonjour: false
        )
        try server.start()

        do {
            let baseURL = try await waitForShareURL(server)
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw BridgeError.invalidResourceURL
            }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "access_key", value: accessKey))
            queryItems.append(URLQueryItem(name: "mount_instance", value: UUID().uuidString.lowercased()))
            queryItems.append(URLQueryItem(
                name: GhostFileProtocol.cacheTTLQueryName,
                value: String(cacheTTLSeconds)
            ))
            components.queryItems = queryItems
            guard let resourceURL = components.url else { throw BridgeError.invalidResourceURL }
            exports[id] = Export(server: server)
            return RegisteredExport(id: id, resourceURL: resourceURL)
        } catch {
            server.stop()
            throw error
        }
    }

    func unregisterExport(id: String) {
        exports.removeValue(forKey: id)?.server.stop()
    }

    private func waitForShareURL(_ server: GhostFileShareServer) async throws -> URL {
        for _ in 0..<500 {
            if let url = server.shareURL, server.port != 0 { return url }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BridgeError.listenerTimeout
    }

    enum BridgeError: Error, LocalizedError {
        case notRunning
        case invalidGuestPath
        case invalidCacheTTL
        case tooManyExports
        case invalidResourceURL
        case guestUnavailable
        case listenerTimeout

        var errorDescription: String? {
            switch self {
            case .notRunning: return "filesystem bridge is not running"
            case .invalidGuestPath: return "guest export path must be absolute"
            case .invalidCacheTTL:
                return "filesystem cache TTL must be from 0 through \(GhostFileProtocol.maximumCacheTTLSeconds) seconds"
            case .tooManyExports: return "filesystem export limit reached"
            case .invalidResourceURL: return "failed to create FSKit resource URL"
            case .guestUnavailable: return "guest is unavailable"
            case .listenerTimeout: return "timed out starting the filesystem export"
            }
        }
    }
}
