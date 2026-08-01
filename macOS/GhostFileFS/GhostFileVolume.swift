import Foundation
import FSKit

final class GhostFileVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    private let client: GhostFileHTTP3Client
    private let itemLock = NSLock()
    private var items: [UInt64: GhostFileItem] = [:]
    private var rootItem: GhostFileItem?

    init(volumeID: FSVolume.Identifier, volumeName: FSFileName, client: GhostFileHTTP3Client) {
        self.client = client
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = false
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
        let result = FSStatFSResult(fileSystemTypeName: "ghostfile")
        result.blockSize = 4096
        result.ioSize = GhostFileProtocol.maximumReadLength
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
        clearItems()
    }

    func synchronize(flags: FSSyncFlags) async throws {}

    func activate(options: FSTaskOptions) async throws -> FSItem {
        let existingRoot = itemLock.withLock { rootItem }
        if let existingRoot { return existingRoot }

        let metadata = try await client.metadata(path: "")
        let candidate = GhostFileItem(relativePath: "", parentID: .parentOfRoot, metadata: metadata)
        return itemLock.withLock {
            if let rootItem { return rootItem }
            rootItem = candidate
            items[FSItem.Identifier.rootDirectory.rawValue] = candidate
            return candidate
        }
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        clearItems()
    }

    func attributes(_ request: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        let item = try ghostItem(item)
        let metadata = try await client.metadata(path: item.relativePath)
        item.update(metadata: metadata)
        return attributes(for: item, request: request)
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        throw fs_errorForPOSIXError(EROFS)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        let directory = try ghostItem(directory)
        guard directory.metadata.type == .directory,
              let nameString = name.string,
              isValidName(nameString) else {
            throw fs_errorForPOSIXError(ENOENT)
        }
        let path = childPath(nameString, parent: directory.relativePath)
        let metadata = try await client.metadata(path: path)
        return (cachedItem(path: path, parent: identifier(for: directory), metadata: metadata), name)
    }

    func reclaimItem(_ item: FSItem) async throws {
        guard let item = item as? GhostFileItem, !item.relativePath.isEmpty else { return }
        let id = identifier(for: item).rawValue
        itemLock.withLock {
            if items[id] === item { items.removeValue(forKey: id) }
        }
    }

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
        verifier suppliedVerifier: FSDirectoryVerifier,
        attributes requestedAttributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker
    ) async throws -> FSDirectoryVerifier {
        let directory = try ghostItem(directory)
        let listing = try await client.directory(path: directory.relativePath)
        let currentVerifier = FSDirectoryVerifier(max(listing.verifier, 1))
        if suppliedVerifier != .initial && suppliedVerifier != currentVerifier {
            throw invalidDirectoryCookieError()
        }

        let entries = listing.entries.filter { isValidName($0.name) }
        let syntheticEntryCount = requestedAttributes == nil ? 2 : 0
        let totalEntryCount = syntheticEntryCount + entries.count
        let start = Int(cookie.rawValue)
        guard start <= totalEntryCount else { throw invalidDirectoryCookieError() }

        var cursor = start
        while cursor < totalEntryCount {
            let packed: Bool
            if requestedAttributes == nil, cursor < 2 {
                let isDot = cursor == 0
                let itemID: FSItem.Identifier
                if isDot || directory.relativePath.isEmpty {
                    itemID = identifier(for: directory)
                } else {
                    itemID = directory.parentID
                }
                packed = packer.packEntry(
                    name: FSFileName(string: isDot ? "." : ".."),
                    itemType: .directory,
                    itemID: itemID,
                    nextCookie: FSDirectoryCookie(UInt64(cursor + 1)),
                    attributes: nil
                )
            } else {
                let metadata = entries[cursor - syntheticEntryCount]
                let path = childPath(metadata.name, parent: directory.relativePath)
                let child = cachedItem(path: path, parent: identifier(for: directory), metadata: metadata)
                packed = packer.packEntry(
                    name: FSFileName(string: metadata.name),
                    itemType: itemType(metadata.type),
                    itemID: identifier(for: child),
                    nextCookie: FSDirectoryCookie(UInt64(cursor + 1)),
                    attributes: requestedAttributes.map { attributes(for: child, request: $0) }
                )
            }
            guard packed else { break }
            cursor += 1
        }
        return currentVerifier
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
        let requestLength = min(length, GhostFileProtocol.maximumReadLength)
        if requestLength == 0 { return 0 }
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

    private func ghostItem(_ item: FSItem) throws -> GhostFileItem {
        guard let item = item as? GhostFileItem else { throw fs_errorForPOSIXError(ESTALE) }
        return item
    }

    private func cachedItem(path: String, parent: FSItem.Identifier, metadata: GhostFileMetadata) -> GhostFileItem {
        let id = identifier(for: metadata).rawValue
        itemLock.lock()
        defer { itemLock.unlock() }
        if let existing = items[id] {
            existing.update(metadata: metadata)
            return existing
        }
        let item = GhostFileItem(relativePath: path, parentID: parent, metadata: metadata)
        items[id] = item
        return item
    }

    private func clearItems() {
        itemLock.lock()
        items.removeAll()
        rootItem = nil
        itemLock.unlock()
    }

    private func attributes(
        for item: GhostFileItem,
        request: FSItem.GetAttributesRequest? = nil
    ) -> FSItem.Attributes {
        let metadata = item.metadata
        let result = FSItem.Attributes()
        func wanted(_ attribute: FSItem.Attribute) -> Bool {
            request?.isAttributeWanted(attribute) ?? true
        }
        if wanted(.type) { result.type = itemType(metadata.type) }
        if wanted(.mode) { result.mode = metadata.mode }
        if wanted(.uid) { result.uid = metadata.uid }
        if wanted(.gid) { result.gid = metadata.gid }
        if wanted(.linkCount) { result.linkCount = 1 }
        if wanted(.flags) { result.flags = 0 }
        if wanted(.size) { result.size = metadata.size }
        if wanted(.allocSize) { result.allocSize = metadata.size }
        if wanted(.fileID) { result.fileID = identifier(for: item) }
        if wanted(.parentID) { result.parentID = item.parentID }

        let modifyTime = timestamp(
            seconds: metadata.modifiedSeconds,
            nanoseconds: metadata.modifiedNanoseconds
        )
        let accessTime = timestamp(
            seconds: metadata.accessedSeconds ?? metadata.modifiedSeconds,
            nanoseconds: metadata.accessedNanoseconds ?? metadata.modifiedNanoseconds
        )
        let changeTime = timestamp(
            seconds: metadata.changedSeconds ?? metadata.modifiedSeconds,
            nanoseconds: metadata.changedNanoseconds ?? metadata.modifiedNanoseconds
        )
        let birthTime = timestamp(
            seconds: metadata.birthSeconds ?? metadata.modifiedSeconds,
            nanoseconds: metadata.birthNanoseconds ?? metadata.modifiedNanoseconds
        )
        if wanted(.modifyTime) { result.modifyTime = modifyTime }
        if wanted(.accessTime) { result.accessTime = accessTime }
        if wanted(.changeTime) { result.changeTime = changeTime }
        if wanted(.birthTime) { result.birthTime = birthTime }
        if wanted(.addedTime) { result.addedTime = birthTime }
        if wanted(.backupTime) { result.backupTime = timespec() }
        if wanted(.supportsLimitedXAttrs) { result.supportsLimitedXAttrs = false }
        if wanted(.inhibitKernelOffloadedIO) { result.inhibitKernelOffloadedIO = false }
        return result
    }

    private func timestamp(seconds: Int64, nanoseconds: Int32) -> timespec {
        timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
    }

    private func identifier(for item: GhostFileItem) -> FSItem.Identifier {
        item.relativePath.isEmpty ? .rootDirectory : identifier(for: item.metadata)
    }

    private func identifier(for metadata: GhostFileMetadata) -> FSItem.Identifier {
        FSItem.Identifier(rawValue: max(metadata.objectID, 3)) ?? .invalid
    }

    private func itemType(_ type: GhostFileNodeType) -> FSItem.ItemType {
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

    private func invalidDirectoryCookieError() -> Error {
        NSError(domain: FSKitErrorDomain, code: FSError.Code.invalidDirectoryCookie.rawValue)
    }
}
