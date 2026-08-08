import AppKit
import Combine
import Foundation
import GhostFileKit
import Security

struct SavedGhostFileShare: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var folderBookmark: Data
    var preferredPort: UInt16
    var readOnly: Bool
}

enum GhostFileShareStatus: Equatable {
    case stopped
    case starting
    case online
    case failed(String)
}

protocol GhostFileShareConfigurationStorage {
    func load() throws -> [SavedGhostFileShare]
    func save(_ shares: [SavedGhostFileShare]) throws
}

struct GhostFileShareJSONStorage: GhostFileShareConfigurationStorage {
    let fileURL: URL

    static var applicationStorage: Self {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GhostFile", isDirectory: true)
        return Self(fileURL: root.appendingPathComponent("shares.json"))
    }

    func load() throws -> [SavedGhostFileShare] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SavedGhostFileShare].self, from: Data(contentsOf: fileURL))
    }

    func save(_ shares: [SavedGhostFileShare]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(shares)
        try data.write(to: fileURL, options: .atomic)
    }
}

protocol GhostFileAccessKeyStorage {
    func accessKey(for shareID: UUID) throws -> String?
    func setAccessKey(_ accessKey: String, for shareID: UUID) throws
    func removeAccessKey(for shareID: UUID) throws
}

struct GhostFileKeychainAccessKeyStorage: GhostFileAccessKeyStorage {
    private let service: String

    init(service: String = "org.ghostvm.ghostfile.share-access-key") {
        self.service = service
    }

    func accessKey(for shareID: UUID) throws -> String? {
        var query = baseQuery(for: shareID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw GhostFileKeychainError(status: status)
        }
        return value
    }

    func setAccessKey(_ accessKey: String, for shareID: UUID) throws {
        let query = baseQuery(for: shareID)
        let attributes = [kSecValueData as String: Data(accessKey.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GhostFileKeychainError(status: updateStatus)
        }
        var item = query
        item[kSecValueData as String] = Data(accessKey.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GhostFileKeychainError(status: addStatus)
        }
    }

    func removeAccessKey(for shareID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: shareID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GhostFileKeychainError(status: status)
        }
    }

    private func baseQuery(for shareID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: shareID.uuidString.lowercased(),
        ]
    }
}

protocol GhostFileTLSPrivateKeyStorage {
    func privateKey(for shareID: UUID) throws -> Data?
    func setPrivateKey(_ privateKey: Data, for shareID: UUID) throws
    func removePrivateKey(for shareID: UUID) throws
}

struct GhostFileKeychainTLSPrivateKeyStorage: GhostFileTLSPrivateKeyStorage {
    private let service: String

    init(service: String = "org.ghostvm.ghostfile.share-tls-private-key") {
        self.service = service
    }

    func privateKey(for shareID: UUID) throws -> Data? {
        var query = baseQuery(for: shareID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw GhostFileKeychainError(status: status)
        }
        return data
    }

    func setPrivateKey(_ privateKey: Data, for shareID: UUID) throws {
        let query = baseQuery(for: shareID)
        let attributes = [kSecValueData as String: privateKey]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GhostFileKeychainError(status: updateStatus)
        }
        var item = query
        item[kSecValueData as String] = privateKey
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GhostFileKeychainError(status: addStatus)
        }
    }

    func removePrivateKey(for shareID: UUID) throws {
        let status = SecItemDelete(baseQuery(for: shareID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GhostFileKeychainError(status: status)
        }
    }

    private func baseQuery(for shareID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: shareID.uuidString.lowercased(),
        ]
    }
}

private struct GhostFileKeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error \(status)"
    }
}

@MainActor
protocol GhostFileShareRuntime: AnyObject {
    var isRunning: Bool { get }
    var shareURL: URL? { get }
    var requestCount: Int { get }
    var objectWillChange: ObservableObjectPublisher { get }
    func start(preferredPort: UInt16) throws
    func stop()
    func setReadOnly(_ readOnly: Bool)
}

extension GhostFileShareServer: GhostFileShareRuntime {}

@MainActor
final class GhostFileLibrary: ObservableObject {
    typealias ServerFactory = @MainActor (
        SavedGhostFileShare,
        URL,
        String,
        GhostFileTLSIdentity
    ) -> any GhostFileShareRuntime

    @Published private(set) var shares: [SavedGhostFileShare]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published var generalError: String?

    private let configurationStorage: any GhostFileShareConfigurationStorage
    private let accessKeyStorage: any GhostFileAccessKeyStorage
    private let tlsPrivateKeyStorage: any GhostFileTLSPrivateKeyStorage
    private let serverFactory: ServerFactory
    private var servers: [UUID: any GhostFileShareRuntime] = [:]
    private var serverObservers: [UUID: AnyCancellable] = [:]
    private var accessedFolders: [UUID: URL] = [:]

    init(
        configurationStorage: any GhostFileShareConfigurationStorage = GhostFileShareJSONStorage.applicationStorage,
        accessKeyStorage: any GhostFileAccessKeyStorage = GhostFileKeychainAccessKeyStorage(),
        tlsPrivateKeyStorage: any GhostFileTLSPrivateKeyStorage = GhostFileKeychainTLSPrivateKeyStorage(),
        serverFactory: @escaping ServerFactory = { share, folder, accessKey, identity in
            GhostFileShareServer(
                rootURL: folder,
                shareName: share.name,
                accessKey: accessKey,
                shareID: share.id,
                readOnly: share.readOnly,
                tlsIdentity: identity
            )
        }
    ) {
        self.configurationStorage = configurationStorage
        self.accessKeyStorage = accessKeyStorage
        self.tlsPrivateKeyStorage = tlsPrivateKeyStorage
        self.serverFactory = serverFactory
        do {
            shares = try configurationStorage.load()
        } catch {
            shares = []
            generalError = "Unable to load saved shares: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func addShareUsingPanel() -> SavedGhostFileShare? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to share"
        panel.prompt = "Add Share"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        do {
            let share = try addShare(folderURL: folder)
            generalError = nil
            return share
        } catch {
            generalError = "Unable to add the share: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func addShare(
        folderURL: URL,
        name: String? = nil,
        preferredPort: UInt16 = 0,
        accessKey: String = UUID().uuidString.lowercased()
    ) throws -> SavedGhostFileShare {
        let trimmedAccessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccessKey.isEmpty else { throw GhostFileLibraryError.emptyAccessKey }
        let bookmark = try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let share = SavedGhostFileShare(
            id: UUID(),
            name: trimmedName?.isEmpty == false ? trimmedName! : folderURL.lastPathComponent,
            folderBookmark: bookmark,
            preferredPort: preferredPort,
            readOnly: true
        )
        let identity = try GhostFileTLSIdentity.make()
        try tlsPrivateKeyStorage.setPrivateKey(identity.privateKeyRepresentation, for: share.id)
        do {
            try accessKeyStorage.setAccessKey(trimmedAccessKey, for: share.id)
            var updated = shares
            updated.append(share)
            try configurationStorage.save(updated)
            shares = updated
            return share
        } catch {
            try? accessKeyStorage.removeAccessKey(for: share.id)
            try? tlsPrivateKeyStorage.removePrivateKey(for: share.id)
            throw error
        }
    }

    func share(withID id: UUID) -> SavedGhostFileShare? {
        shares.first { $0.id == id }
    }

    func accessKey(for shareID: UUID) throws -> String {
        guard let accessKey = try accessKeyStorage.accessKey(for: shareID), !accessKey.isEmpty else {
            throw GhostFileLibraryError.missingAccessKey
        }
        return accessKey
    }

    func publicKeyPin(for shareID: UUID) throws -> String {
        guard share(withID: shareID) != nil else { throw GhostFileLibraryError.shareNotFound }
        return try persistentIdentity(for: shareID).publicKeyPin
    }

    func rotateTLSIdentity(for shareID: UUID) {
        guard share(withID: shareID) != nil else { return }
        guard servers[shareID] == nil else {
            errors[shareID] = "Stop sharing before rotating its TLS identity."
            return
        }
        do {
            let identity = try GhostFileTLSIdentity.make()
            try tlsPrivateKeyStorage.setPrivateKey(identity.privateKeyRepresentation, for: shareID)
            errors[shareID] = nil
            generalError = nil
        } catch {
            errors[shareID] = "Unable to rotate the TLS identity: \(error.localizedDescription)"
        }
    }

    func updateShare(
        _ shareID: UUID,
        name: String,
        preferredPort: UInt16,
        accessKey: String,
        folderURL: URL? = nil
    ) throws {
        guard let index = shares.firstIndex(where: { $0.id == shareID }) else {
            throw GhostFileLibraryError.shareNotFound
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAccessKey = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw GhostFileLibraryError.emptyName }
        guard !trimmedAccessKey.isEmpty else { throw GhostFileLibraryError.emptyAccessKey }

        var updatedShare = shares[index]
        updatedShare.name = trimmedName
        updatedShare.preferredPort = preferredPort
        if let folderURL {
            updatedShare.folderBookmark = try folderURL.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }

        let oldShares = shares
        let oldAccessKey = try accessKeyStorage.accessKey(for: shareID)
        let wasActive = status(for: shareID) == .online || status(for: shareID) == .starting
        if wasActive { stop(shareID) }
        do {
            try accessKeyStorage.setAccessKey(trimmedAccessKey, for: shareID)
            var updatedShares = shares
            updatedShares[index] = updatedShare
            try configurationStorage.save(updatedShares)
            shares = updatedShares
            errors[shareID] = nil
            generalError = nil
            if wasActive { start(shareID) }
        } catch {
            shares = oldShares
            if let oldAccessKey {
                try? accessKeyStorage.setAccessKey(oldAccessKey, for: shareID)
            } else {
                try? accessKeyStorage.removeAccessKey(for: shareID)
            }
            if wasActive { start(shareID) }
            throw error
        }
    }

    func setReadOnly(_ readOnly: Bool, for shareID: UUID) {
        guard let index = shares.firstIndex(where: { $0.id == shareID }),
              shares[index].readOnly != readOnly else { return }
        let original = shares
        var updated = shares
        updated[index].readOnly = readOnly
        do {
            try configurationStorage.save(updated)
            shares = updated
            servers[shareID]?.setReadOnly(readOnly)
            errors[shareID] = nil
            generalError = nil
        } catch {
            shares = original
            generalError = "Unable to change share access: \(error.localizedDescription)"
        }
    }

    func folderURL(for shareID: UUID) -> URL? {
        guard let share = share(withID: shareID) else { return nil }
        return try? resolveFolder(for: share)
    }

    func shareURL(for shareID: UUID) -> URL? {
        servers[shareID]?.shareURL
    }

    func requestCount(for shareID: UUID) -> Int {
        servers[shareID]?.requestCount ?? 0
    }

    func status(for shareID: UUID) -> GhostFileShareStatus {
        if let error = errors[shareID] { return .failed(error) }
        guard let server = servers[shareID] else { return .stopped }
        return server.isRunning ? .online : .starting
    }

    func start(_ shareID: UUID) {
        guard servers[shareID] == nil, let share = share(withID: shareID) else { return }
        do {
            guard let accessKey = try accessKeyStorage.accessKey(for: shareID), !accessKey.isEmpty else {
                throw GhostFileLibraryError.missingAccessKey
            }
            let folder = try resolveFolder(for: share)
            let isAccessing = folder.startAccessingSecurityScopedResource()
            if isAccessing { accessedFolders[shareID] = folder }
            let identity = try persistentIdentity(for: shareID)
            let server = serverFactory(share, folder, accessKey, identity)
            serverObservers[shareID] = server.objectWillChange.sink { [weak self] _ in
                Task { @MainActor in self?.objectWillChange.send() }
            }
            servers[shareID] = server
            errors[shareID] = nil
            do {
                try server.start(preferredPort: share.preferredPort)
            } catch {
                servers[shareID] = nil
                serverObservers[shareID] = nil
                stopAccessingFolder(for: shareID)
                throw error
            }
            objectWillChange.send()
        } catch {
            stopAccessingFolder(for: shareID)
            errors[shareID] = error.localizedDescription
        }
    }

    func stop(_ shareID: UUID) {
        servers.removeValue(forKey: shareID)?.stop()
        serverObservers[shareID] = nil
        stopAccessingFolder(for: shareID)
        errors[shareID] = nil
        objectWillChange.send()
    }

    func reveal(_ shareID: UUID) {
        guard let folder = folderURL(for: shareID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    func delete(_ shareIDs: Set<UUID>) {
        guard !shareIDs.isEmpty else { return }
        for shareID in shareIDs { stop(shareID) }
        let original = shares
        let updated = shares.filter { !shareIDs.contains($0.id) }
        do {
            try configurationStorage.save(updated)
            shares = updated
            for shareID in shareIDs {
                try? accessKeyStorage.removeAccessKey(for: shareID)
                try? tlsPrivateKeyStorage.removePrivateKey(for: shareID)
            }
            generalError = nil
        } catch {
            shares = original
            generalError = "Unable to delete the share: \(error.localizedDescription)"
        }
    }

    private func resolveFolder(for share: SavedGhostFileShare) throws -> URL {
        var stale = false
        let folder = try URL(
            resolvingBookmarkData: share.folderBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            throw GhostFileLibraryError.staleFolderPermission
        }
        return folder
    }

    private func persistentIdentity(for shareID: UUID) throws -> GhostFileTLSIdentity {
        if let storedKey = try tlsPrivateKeyStorage.privateKey(for: shareID) {
            return try GhostFileTLSIdentity.make(privateKeyRepresentation: storedKey)
        }
        // Existing shares are migrated lazily the first time they start.
        let identity = try GhostFileTLSIdentity.make()
        try tlsPrivateKeyStorage.setPrivateKey(identity.privateKeyRepresentation, for: shareID)
        return identity
    }

    private func stopAccessingFolder(for shareID: UUID) {
        accessedFolders.removeValue(forKey: shareID)?.stopAccessingSecurityScopedResource()
    }
}

private enum GhostFileLibraryError: LocalizedError {
    case shareNotFound
    case emptyName
    case emptyAccessKey
    case missingAccessKey
    case staleFolderPermission

    var errorDescription: String? {
        switch self {
        case .shareNotFound: "The saved share no longer exists."
        case .emptyName: "Enter a share name."
        case .emptyAccessKey: "Enter an access key."
        case .missingAccessKey: "The saved access key is missing. Delete and add the share again."
        case .staleFolderPermission: "Choose the shared folder again; its saved permission is stale."
        }
    }
}
