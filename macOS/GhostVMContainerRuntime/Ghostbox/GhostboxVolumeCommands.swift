import Containerization
import ContainerizationEXT4
import Foundation
import GhostVMKit
import SystemPackage

let ghostboxVolumeStoreContextKey = "ghostbox.volume-store"

struct GhostboxVolumeMetadata: Codable, Equatable, Sendable {
    let name: String
    let format: String
    let sizeInBytes: UInt64
    let createdAt: Date
}

actor GhostboxVolumeStore {
    static let defaultSize: UInt64 = 8 * 1024 * 1024 * 1024
    static let minimumSize: UInt64 = 1024 * 1024
    static let maximumSize: UInt64 = 1024 * 1024 * 1024 * 1024
    static let volumeQuota = 128

    private static let metadataFile = "entity.json"
    private static let imageFile = "volume.img"

    private let rootURL: URL
    private var mountLeases: [String: String] = [:]

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    func create(name: String, sizeInBytes: UInt64) throws -> GhostboxVolumeMetadata {
        try validate(name: name)
        guard (Self.minimumSize...Self.maximumSize).contains(sizeInBytes) else {
            throw DirectDispatchError(
                .invalidArgument,
                "volume size must be between \(Self.minimumSize) and \(Self.maximumSize) bytes"
            )
        }

        try ensureRoot()
        let destination = volumeURL(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw DirectDispatchError(.alreadyExists, "volume '@volume/\(name)' already exists")
        }
        guard try volumeNames().count < Self.volumeQuota else {
            throw DirectDispatchError(.resourceExhausted, "persistent volume limit of \(Self.volumeQuota) reached")
        }

        let temporary = rootURL.appendingPathComponent(".\(name).\(UUID().uuidString).tmp", isDirectory: true)
        var committed = false
        defer {
            if !committed { try? FileManager.default.removeItem(at: temporary) }
        }
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let imageURL = temporary.appendingPathComponent(Self.imageFile)
        let formatter = try EXT4.Formatter(FilePath(imageURL.path), minDiskSize: sizeInBytes)
        try formatter.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)

        let metadata = GhostboxVolumeMetadata(
            name: name,
            format: "ext4",
            sizeInBytes: sizeInBytes,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let metadataURL = temporary.appendingPathComponent(Self.metadataFile)
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)

        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            committed = true
        } catch CocoaError.fileWriteFileExists {
            throw DirectDispatchError(.alreadyExists, "volume '@volume/\(name)' already exists")
        }
        return metadata
    }

    func list() throws -> [GhostboxVolumeMetadata] {
        try ensureRoot()
        return try volumeNames().map(load).sorted { $0.name < $1.name }
    }

    func inspect(name: String) throws -> GhostboxVolumeMetadata {
        try validate(name: name)
        return try load(name: name)
    }

    func delete(name: String) throws {
        try validate(name: name)
        _ = try load(name: name)
        if let mountReference = mountLeases[name] {
            throw DirectDispatchError(
                .failedPrecondition,
                "volume '@volume/\(name)' is in use by '\(mountReference)'"
            )
        }
        try FileManager.default.removeItem(at: volumeURL(name))
    }

    func makeMount(
        volumeName: String,
        mountReference: String,
        destination: String,
        readOnly: Bool
    ) throws -> Containerization.Mount {
        let metadata = try inspect(name: volumeName)
        if let existing = mountLeases[volumeName], existing != mountReference {
            throw DirectDispatchError(
                .failedPrecondition,
                "volume '@volume/\(volumeName)' is already reserved by '\(existing)'"
            )
        }
        mountLeases[volumeName] = mountReference
        return Containerization.Mount.block(
            format: metadata.format,
            source: imageURL(volumeName).path,
            destination: destination,
            options: readOnly ? ["ro"] : [],
            runtimeOptions: [
                "vzDiskImageCachingMode=cached",
                "vzDiskImageSynchronizationMode=fsync",
            ]
        )
    }

    func releaseMount(_ mountReference: String) {
        if let name = mountLeases.first(where: { $0.value == mountReference })?.key {
            mountLeases.removeValue(forKey: name)
        }
    }

    func redactedSource(for mountReference: String) -> String? {
        mountLeases.first(where: { $0.value == mountReference }).map { "@volume/\($0.key)" }
    }

    private func validate(name: String) throws {
        _ = try GhostboxReference.canonical(kind: "volume", name: name)
        guard name.first?.isLetter == true || name.first?.isNumber == true else {
            throw DirectDispatchError(.invalidArgument, "volume name must begin with a letter or digit")
        }
    }

    private func ensureRoot() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    }

    private func volumeNames() throws -> [String] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let name = url.lastPathComponent
            guard (try? validate(name: name)) != nil else { return nil }
            return name
        }
    }

    private func load(name: String) throws -> GhostboxVolumeMetadata {
        let directory = volumeURL(name)
        do {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw DirectDispatchError(.notFound, "volume '@volume/\(name)' was not found")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode(
                GhostboxVolumeMetadata.self,
                from: Data(contentsOf: directory.appendingPathComponent(Self.metadataFile))
            )
            guard metadata.name == name, metadata.format == "ext4" else {
                throw DirectDispatchError(.failedPrecondition, "volume '@volume/\(name)' has invalid metadata")
            }
            let image = imageURL(name)
            let imageValues = try image.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard imageValues.isRegularFile == true, imageValues.isSymbolicLink != true else {
                throw DirectDispatchError(.failedPrecondition, "volume '@volume/\(name)' has no valid backing image")
            }
            return metadata
        } catch let error as DirectDispatchError {
            throw error
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            throw DirectDispatchError(.notFound, "volume '@volume/\(name)' was not found")
        } catch {
            throw DirectDispatchError(.failedPrecondition, "volume '@volume/\(name)' could not be read: \(error.localizedDescription)")
        }
    }

    private func volumeURL(_ name: String) -> URL {
        rootURL.appendingPathComponent(name, isDirectory: true)
    }

    private func imageURL(_ name: String) -> URL {
        volumeURL(name).appendingPathComponent(Self.imageFile)
    }
}

struct GhostboxVolumeCommands: GhostboxDomainHandler {
    let resource = "volume"

    func handle(
        method: GhostboxDirectMethod,
        parameters: [String: GhostboxJSONValue],
        session: GhostboxSession
    ) async throws -> GhostboxDirectValue {
        let store = try ghostboxVolumeStore(session)
        switch method.rawValue {
        case GhostboxDirectMethod.volumeCreate.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["volume", "size"])
            let name = try decoded.requiredString("volume")
            let size = try decoded.optionalUInt64("size") ?? GhostboxVolumeStore.defaultSize
            _ = try await store.create(name: name, sizeInBytes: size)
            return .reference(try GhostboxReference.canonical(kind: "volume", name: name))

        case GhostboxDirectMethod.volumeList.rawValue:
            _ = try GhostboxParameters(parameters, allowed: [])
            let values = try await store.list()
            return .references(try values.map { try GhostboxReference.canonical(kind: "volume", name: $0.name) })

        case GhostboxDirectMethod.volumeInspect.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["volume"])
            let name = try volumeName(decoded)
            return metadataValue(try await store.inspect(name: name))

        case GhostboxDirectMethod.volumeMount.rawValue:
            let decoded = try GhostboxParameters(
                parameters,
                allowed: ["volume", "mount", "destination", "readOnly"]
            )
            let volumeName = try volumeName(decoded)
            let mountName = try decoded.requiredString("mount")
            let mountReference = try GhostboxReference.canonical(kind: "mount", name: mountName)
            let destination = try decoded.requiredString("destination")
            guard ghostboxIsValidVolumeDestination(destination) else {
                throw DirectDispatchError(
                    .invalidArgument,
                    "volume destination must be an absolute non-root path without dot components"
                )
            }
            let mount = try await store.makeMount(
                volumeName: volumeName,
                mountReference: mountReference,
                destination: destination,
                readOnly: try decoded.optionalBool("readOnly") ?? false
            )
            do {
                let reference = try session.register(
                    kind: "mount",
                    name: mountName,
                    value: mount,
                    equivalent: ghostboxVolumeMountsEqual,
                    cleanup: { _ in await store.releaseMount(mountReference) }
                )
                return .reference(reference)
            } catch {
                await store.releaseMount(mountReference)
                throw error
            }

        case GhostboxDirectMethod.volumeDelete.rawValue:
            let decoded = try GhostboxParameters(parameters, allowed: ["volume"])
            try await store.delete(name: volumeName(decoded))
            return .void

        default:
            throw DirectDispatchError(.unsupported, "unsupported volume method '\(method.rawValue)'")
        }
    }

    private func volumeName(_ decoded: GhostboxParameters) throws -> String {
        let reference = try decoded.requiredReference("volume", expectedKind: "volume")
        return String(reference.dropFirst("@volume/".count))
    }

    private func metadataValue(_ metadata: GhostboxVolumeMetadata) -> GhostboxDirectValue {
        .object([
            "name": .string(metadata.name),
            "format": .string(metadata.format),
            "sizeInBytes": .unsignedInteger(metadata.sizeInBytes),
            "createdAt": .string(ISO8601DateFormatter().string(from: metadata.createdAt)),
        ])
    }
}

func ghostboxVolumeStore(_ session: GhostboxSession) throws -> GhostboxVolumeStore {
    guard let store = session.contextValue(ghostboxVolumeStoreContextKey, as: GhostboxVolumeStore.self) else {
        throw DirectDispatchError(.unavailable, "persistent volume storage is unavailable")
    }
    return store
}

private func ghostboxIsValidVolumeDestination(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
    }
}

private func ghostboxVolumeMountsEqual(_ lhs: Containerization.Mount, _ rhs: Containerization.Mount) -> Bool {
    lhs.type == rhs.type
        && lhs.source == rhs.source
        && lhs.destination == rhs.destination
        && lhs.options == rhs.options
        && String(describing: lhs.runtimeOptions) == String(describing: rhs.runtimeOptions)
}
