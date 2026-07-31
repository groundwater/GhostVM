import Foundation
import FSKit

final class GhostVMVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    private let client: GhostVMFSClient
    private var items: [UInt64: GhostVMItem] = [:]
    private var root: GhostVMItem?

    init(volumeID: FSVolume.Identifier, volumeName: FSFileName, client: GhostVMFSClient) {
        self.client = client
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supports64BitObjectIDs = true
        capabilities.supports2TBFiles = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsHardLinks = false
        capabilities.supportsFastStatFS = true
        capabilities.doesNotSupportVolumeSizes = true
        capabilities.caseFormat = .sensitive
        return capabilities
    }

    var volumeStatistics: FSStatFSResult {
        let result = FSStatFSResult(fileSystemTypeName: "ghostvm")
        result.blockSize = 4096
        result.ioSize = 1024 * 1024
        return result
    }

    var requestedMountOptions: FSVolume.MountOptions = .readOnly
    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64.max }

    func mount(options: FSTaskOptions) async throws {}

    func unmount() async {
        items.removeAll()
        root = nil
    }

    func synchronize(flags: FSSyncFlags) async throws {}

    func activate(options: FSTaskOptions) async throws -> FSItem {
        if let root { return root }
        let metadata = try await client.metadata(path: "")
        let item = GhostVMItem(relativePath: "", parentID: .parentOfRoot, metadata: metadata)
        root = item
        items[FSItem.Identifier.rootDirectory.rawValue] = item
        return item
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {}

    func attributes(_ request: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        let item = try ghostItem(item)
        item.metadata = try await client.metadata(path: item.relativePath)
        return attributes(for: item)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        throw fs_errorForPOSIXError(EROFS)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        let directory = try ghostItem(directory)
        guard directory.metadata.type == .directory, let nameString = name.string, isValidName(nameString) else {
            throw fs_errorForPOSIXError(ENOENT)
        }
        let path = childPath(nameString, parent: directory.relativePath)
        let metadata = try await client.metadata(path: path)
        return (item(path: path, parent: identifier(for: directory), metadata: metadata), name)
    }

    func reclaimItem(_ item: FSItem) async throws {}

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        let item = try ghostItem(item)
        guard item.metadata.type == .symbolicLink else { throw fs_errorForPOSIXError(EINVAL) }
        return FSFileName(string: try await client.readSymbolicLink(path: item.relativePath))
    }

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest
    ) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(EROFS)
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName
    ) async throws -> (FSItem, FSFileName) {
        throw fs_errorForPOSIXError(EROFS)
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        throw fs_errorForPOSIXError(EROFS)
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        throw fs_errorForPOSIXError(EROFS)
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?
    ) async throws -> FSFileName {
        throw fs_errorForPOSIXError(EROFS)
    }

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes requestedAttributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        let directory = try ghostItem(directory)
        let listing = try await client.list(path: directory.relativePath)
        let start = Int(cookie.rawValue)
        guard start <= listing.entries.count else {
            throw fs_errorForPOSIXError(EINVAL)
        }

        for index in start..<listing.entries.count {
            let metadata = listing.entries[index]
            guard isValidName(metadata.name) else { continue }
            let path = childPath(metadata.name, parent: directory.relativePath)
            let child = item(path: path, parent: identifier(for: directory), metadata: metadata)
            let packed = packer.packEntry(
                name: FSFileName(string: metadata.name),
                itemType: itemType(metadata.type),
                itemID: identifier(for: child),
                nextCookie: FSDirectoryCookie(UInt64(index + 1)),
                attributes: requestedAttributes == nil ? nil : attributes(for: child)
            )
            if !packed { break }
        }

        return FSDirectoryVerifier(1)
    }

    func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer
    ) async throws -> Int {
        let item = try ghostItem(item)
        guard offset >= 0, length >= 0 else { throw fs_errorForPOSIXError(EINVAL) }
        guard item.metadata.type == .file else {
            throw fs_errorForPOSIXError(item.metadata.type == .directory ? EISDIR : EINVAL)
        }
        // The guest and loopback bridges cap each range read at 1 MiB.
        // Returning a partial read is valid and lets FSKit request the remainder.
        let requestLength = min(length, 1024 * 1024)
        let data = try await client.read(path: item.relativePath, offset: UInt64(offset), length: requestLength)
        return buffer.withUnsafeMutableBytes { destination in
            let count = min(destination.count, data.count)
            data.copyBytes(to: destination.bindMemory(to: UInt8.self), count: count)
            return count
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        throw fs_errorForPOSIXError(EROFS)
    }

    private func ghostItem(_ item: FSItem) throws -> GhostVMItem {
        guard let item = item as? GhostVMItem else { throw fs_errorForPOSIXError(ESTALE) }
        return item
    }

    private func item(path: String, parent: FSItem.Identifier, metadata: GhostVMFileMetadata) -> GhostVMItem {
        let id = identifier(device: metadata.device, inode: metadata.inode, path: path)
        if let existing = items[id.rawValue] {
            existing.metadata = metadata
            return existing
        }
        let item = GhostVMItem(relativePath: path, parentID: parent, metadata: metadata)
        items[id.rawValue] = item
        return item
    }

    private func attributes(for item: GhostVMItem) -> FSItem.Attributes {
        let result = FSItem.Attributes()
        result.type = itemType(item.metadata.type)
        result.mode = item.metadata.mode
        result.uid = item.metadata.uid
        result.gid = item.metadata.gid
        result.linkCount = item.metadata.linkCount
        result.size = item.metadata.size
        result.allocSize = item.metadata.size
        result.fileID = identifier(for: item)
        result.parentID = item.parentID
        result.modifyTime = timespec(
            tv_sec: item.metadata.modifiedSeconds,
            tv_nsec: Int(item.metadata.modifiedNanoseconds)
        )
        return result
    }

    private func identifier(for item: GhostVMItem) -> FSItem.Identifier {
        if item.relativePath.isEmpty { return .rootDirectory }
        return identifier(device: item.metadata.device, inode: item.metadata.inode, path: item.relativePath)
    }

    private func identifier(device: UInt64, inode: UInt64, path: String) -> FSItem.Identifier {
        var value = device ^ (inode &* 0x9E37_79B9_7F4A_7C15)
        for byte in path.utf8 {
            value = (value ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        value = max(value, FSItem.Identifier.rootDirectory.rawValue + 1)
        return FSItem.Identifier(rawValue: value) ?? .invalid
    }

    private func itemType(_ type: GhostVMFileType) -> FSItem.ItemType {
        switch type {
        case .file: return .file
        case .directory: return .directory
        case .symbolicLink: return .symlink
        case .other: return .unknown
        }
    }

    private func childPath(_ child: String, parent: String) -> String {
        parent.isEmpty ? child : "\(parent)/\(child)"
    }

    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
