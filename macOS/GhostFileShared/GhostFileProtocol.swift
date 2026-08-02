import Foundation

enum GhostFileProtocol {
    static let version = 1
    static let urlScheme = "ghostfile"
    static let bonjourType = "_ghostfile._udp."
    static let bonjourDomain = "local."
    static let alpn = "h3"
    static let transport = "http3"
    static let maximumReadLength = 1024 * 1024
    static let maximumInlineFileLength = 64 * 1024
    static let maximumInlineDirectoryLength = 512 * 1024
    static let maximumInlineDirectoryFileCount = 256
    static let mountInstanceQueryName = "mount_instance"

    static func shareBasePath(id: UUID) -> String {
        "/v1/shares/\(id.uuidString.lowercased())"
    }

    /// FSKit uses the resource and volume identifiers to serialize work. Give
    /// every network mount a connection-specific UUID so a dead mount cannot
    /// leave a later connection to the same share permanently EBUSY.
    ///
    /// Although FSKit also exposes an eight-byte identifier qualifier for this
    /// purpose, macOS 26.4 drops it during the final LiveFS connector lookup.
    /// A plain UUID survives that handoff intact.
    static func mountInstanceID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: {
                  $0.name == mountInstanceQueryName
              })?.value else { return nil }
        return UUID(uuidString: value)
    }
}

struct GhostFileHTTPRequest: Sendable {
    let operation: String
    let path: String?
    let offset: UInt64?
    let length: Int?
}

enum GhostFileNodeType: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

struct GhostFileCapabilities: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let shareID: UUID
    let name: String
    let readOnly: Bool
    let transports: [String]
    let maximumReadLength: Int
}

struct GhostFileMetadata: Codable, Equatable, Sendable {
    let name: String
    let type: GhostFileNodeType
    let size: UInt64
    let mode: UInt32
    let uid: UInt32
    let gid: UInt32
    let objectID: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int32
    let accessedSeconds: Int64?
    let accessedNanoseconds: Int32?
    let changedSeconds: Int64?
    let changedNanoseconds: Int32?
    let birthSeconds: Int64?
    let birthNanoseconds: Int32?
    let etag: String

    init(
        name: String,
        type: GhostFileNodeType,
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

struct GhostFileDirectoryListing: Codable, Equatable, Sendable {
    let path: String
    let verifier: UInt64
    let entries: [GhostFileMetadata]
    let inlineContents: [GhostFileInlineContent]?

    init(
        path: String,
        verifier: UInt64,
        entries: [GhostFileMetadata],
        inlineContents: [GhostFileInlineContent]? = nil
    ) {
        self.path = path
        self.verifier = verifier
        self.entries = entries
        self.inlineContents = inlineContents
    }
}

struct GhostFileInlineContent: Codable, Equatable, Sendable {
    let name: String
    let etag: String
    let data: Data
}

struct GhostFileErrorPayload: Codable, Equatable, Sendable {
    let error: String
}

enum GhostFilePath {
    static func validatedComponents(_ relativePath: String) -> [String]? {
        guard !relativePath.contains("\0"), !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return components
    }

    static func percentEncodedQuery(_ value: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "path", value: value)]
        return components.percentEncodedQuery ?? "path="
    }
}

struct GhostFileByteRange: Equatable, Sendable {
    let offset: UInt64
    let length: Int

    static func parse(_ value: String?, fileSize: UInt64, maximumLength: Int) -> Self? {
        guard let value, value.lowercased().hasPrefix("bytes=") else { return nil }
        let raw = value.dropFirst("bytes=".count)
        let pieces = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let start = UInt64(pieces[0]),
              start < fileSize else { return nil }

        let requestedEnd = pieces[1].isEmpty ? nil : UInt64(pieces[1])
        guard requestedEnd == nil || requestedEnd! >= start else { return nil }
        let boundedEnd = min(requestedEnd ?? (start + UInt64(maximumLength) - 1), fileSize - 1)
        let length = Int(min(UInt64(maximumLength), boundedEnd - start + 1))
        return Self(offset: start, length: length)
    }
}
