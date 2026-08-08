import Foundation

public enum GhostFileProviderNodeType: String, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

public struct GhostFileProviderMetadata: Sendable {
    public let name: String
    public let type: GhostFileProviderNodeType
    public let size: UInt64
    public let mode: UInt32
    public let uid: UInt32
    public let gid: UInt32
    public let objectID: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int32
    public let accessedSeconds: Int64?
    public let accessedNanoseconds: Int32?
    public let changedSeconds: Int64?
    public let changedNanoseconds: Int32?
    public let birthSeconds: Int64?
    public let birthNanoseconds: Int32?
    public let etag: String

    public init(
        name: String,
        type: GhostFileProviderNodeType,
        size: UInt64,
        mode: UInt32,
        uid: UInt32,
        gid: UInt32,
        objectID: UInt64,
        modifiedSeconds: Int64,
        modifiedNanoseconds: Int32,
        accessedSeconds: Int64? = nil,
        accessedNanoseconds: Int32? = nil,
        changedSeconds: Int64? = nil,
        changedNanoseconds: Int32? = nil,
        birthSeconds: Int64? = nil,
        birthNanoseconds: Int32? = nil,
        etag: String
    ) {
        self.name = name
        self.type = type
        self.size = size
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.objectID = objectID
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.accessedSeconds = accessedSeconds
        self.accessedNanoseconds = accessedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
        self.etag = etag
    }
}

public enum GhostFileProviderRead: Sendable {
    case data(Data)
    case fileRegion(path: String, identity: String, offset: UInt64, length: Int)
}

public enum GhostFileProviderCreateType: Sendable {
    case file
    case directory
}

public struct GhostFileProviderAttributes: Sendable {
    public let mode: UInt32?
    public let size: UInt64?
    public let modifiedSeconds: Int64?
    public let modifiedNanoseconds: Int32?
    public let accessedSeconds: Int64?
    public let accessedNanoseconds: Int32?

    public init(
        mode: UInt32? = nil,
        size: UInt64? = nil,
        modifiedSeconds: Int64? = nil,
        modifiedNanoseconds: Int32? = nil,
        accessedSeconds: Int64? = nil,
        accessedNanoseconds: Int32? = nil
    ) {
        self.mode = mode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.accessedSeconds = accessedSeconds
        self.accessedNanoseconds = accessedNanoseconds
    }
}

public protocol GhostFileProvider: Sendable {
    func metadata(path: String) async throws -> GhostFileProviderMetadata
    func contentsOfDirectory(path: String) async throws -> [GhostFileProviderMetadata]
    func read(path: String, offset: UInt64, length: Int) async throws -> GhostFileProviderRead
    func readSymbolicLink(path: String) async throws -> String
    func create(path: String, type: GhostFileProviderCreateType, mode: UInt32) async throws -> GhostFileProviderMetadata
    func createSymbolicLink(path: String, destination: String) async throws -> GhostFileProviderMetadata
    func write(path: String, offset: UInt64, data: Data) async throws -> GhostFileProviderMetadata
    func setAttributes(path: String, attributes: GhostFileProviderAttributes) async throws -> GhostFileProviderMetadata
    func remove(path: String) async throws
    func rename(path: String, destinationPath: String) async throws -> GhostFileProviderMetadata
}
