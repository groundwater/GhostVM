import Foundation
import GhostFileKit
import GhostVMKit

final class GuestPathProvider: GhostFileProvider, @unchecked Sendable {
    private weak var client: (any GhostClientProtocol)?
    private let root: String

    init(client: any GhostClientProtocol, root: String) {
        self.client = client
        self.root = root
    }

    func metadata(path: String) async throws -> GhostFileProviderMetadata {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return Self.metadata(try await client.fileMetadata(path: try guestPath(path)))
    }

    func contentsOfDirectory(path: String) async throws -> [GhostFileProviderMetadata] {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return try await client.listDirectoryMetadata(path: guestPath(path)).entries.map(Self.metadata)
    }

    func read(path: String, offset: UInt64, length: Int) async throws -> GhostFileProviderRead {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return .data(try await client.readFile(path: guestPath(path), offset: offset, length: length))
    }

    func readSymbolicLink(path: String) async throws -> String {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return try await client.readSymbolicLink(path: guestPath(path))
    }

    func create(path: String, type: GhostFileProviderCreateType, mode: UInt32) async throws -> GhostFileProviderMetadata {
        guard let client else { throw POSIXError(.ENOTCONN) }
        let guestType: GuestFileCreateType = type == .file ? .file : .directory
        return Self.metadata(try await client.createFileSystemItem(
            path: guestPath(path),
            type: guestType,
            mode: mode
        ))
    }

    func createSymbolicLink(path: String, destination: String) async throws -> GhostFileProviderMetadata {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return Self.metadata(try await client.createSymbolicLink(
            path: guestPath(path),
            destination: destination
        ))
    }

    func write(path: String, offset: UInt64, data: Data) async throws -> GhostFileProviderMetadata {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return Self.metadata(try await client.writeFile(path: guestPath(path), offset: offset, data: data))
    }

    func setAttributes(path: String, attributes: GhostFileProviderAttributes) async throws -> GhostFileProviderMetadata {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return Self.metadata(try await client.setFileAttributes(
            path: guestPath(path),
            attributes: GuestFileAttributes(
                mode: attributes.mode,
                size: attributes.size,
                modifiedSeconds: attributes.modifiedSeconds,
                modifiedNanoseconds: attributes.modifiedNanoseconds,
                accessedSeconds: attributes.accessedSeconds,
                accessedNanoseconds: attributes.accessedNanoseconds
            )
        ))
    }

    func remove(path: String) async throws {
        guard let client else { throw POSIXError(.ENOTCONN) }
        try await client.removeFileSystemItem(path: guestPath(path))
    }

    func rename(path: String, destinationPath: String) async throws -> GhostFileProviderMetadata {
        guard let client else { throw POSIXError(.ENOTCONN) }
        return Self.metadata(try await client.renameFileSystemItem(
            path: guestPath(path),
            destinationPath: guestPath(destinationPath)
        ))
    }

    private func guestPath(_ relativePath: String) throws -> String {
        guard !relativePath.contains("\0"), !relativePath.hasPrefix("/") else {
            throw POSIXError(.EINVAL)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw POSIXError(.EINVAL)
        }
        return components.reduce(root) { ($0 as NSString).appendingPathComponent(String($1)) }
    }

    private static func metadata(_ value: GuestFileMetadata) -> GhostFileProviderMetadata {
        let type: GhostFileProviderNodeType
        switch value.type {
        case .file: type = .file
        case .directory: type = .directory
        case .symbolicLink: type = .symbolicLink
        case .other: type = .other
        }
        let objectID = value.inode ^ (value.device &* 0x9E37_79B9_7F4A_7C15)
        let etagValue = objectID
            ^ value.size
            ^ UInt64(bitPattern: Int64(value.modifiedSeconds))
            ^ UInt64(bitPattern: Int64(value.modifiedNanoseconds))
        return GhostFileProviderMetadata(
            name: value.name,
            type: type,
            size: value.size,
            mode: value.mode,
            uid: value.uid,
            gid: value.gid,
            objectID: max(objectID, 3),
            modifiedSeconds: Int64(value.modifiedSeconds),
            modifiedNanoseconds: value.modifiedNanoseconds,
            accessedSeconds: value.accessedSeconds.map(Int64.init),
            accessedNanoseconds: value.accessedNanoseconds,
            changedSeconds: value.changedSeconds.map(Int64.init),
            changedNanoseconds: value.changedNanoseconds,
            birthSeconds: value.birthSeconds.map(Int64.init),
            birthNanoseconds: value.birthNanoseconds,
            etag: "\"node-\(String(etagValue, radix: 16))\""
        )
    }
}
