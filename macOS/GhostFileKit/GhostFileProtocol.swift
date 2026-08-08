import Foundation

public enum GhostFilePeerPin: Equatable, Sendable {
    case publicKey(String)
    case legacyCertificate(String)

    public var value: String {
        switch self {
        case .publicKey(let value), .legacyCertificate(let value): value
        }
    }
}

public enum GhostFileProtocol {
    public static let version = 3
    public static let urlScheme = "ghostfile"
    public static let bonjourType = "_ghostfile._udp."
    public static let bonjourDomain = "local."
    public static let alpn = "h3"
    public static let transport = "http3"
    public static let publicKeyPinQueryName = "pk"
    public static let legacyCertificatePinQueryName = "tls_pin"
    public static let maximumReadLength = 1024 * 1024
    public static let maximumWriteLength = 1024 * 1024
    public static let maximumInlineFileLength = 64 * 1024
    public static let maximumInlineDirectoryLength = 512 * 1024
    public static let maximumInlineDirectoryFileCount = 256
    public static let mountInstanceQueryName = "mount_instance"
    public static let cacheTTLQueryName = "cache_ttl"
    public static let defaultCacheTTLSeconds: UInt64 = 5
    public static let maximumCacheTTLSeconds: UInt64 = 300
    public static let heartbeatInterval = Duration.seconds(5)
    public static let heartbeatStaleAfter: TimeInterval = 12

    public static func shareBasePath(id: UUID) -> String {
        "/v1/shares/\(id.uuidString.lowercased())"
    }

    public static func peerPin(from url: URL) -> GhostFilePeerPin? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        let publicKeyPins = items.filter { $0.name == publicKeyPinQueryName }.compactMap(\.value)
        if !publicKeyPins.isEmpty {
            guard publicKeyPins.count == 1, validPublicKeyPin(publicKeyPins[0]) else { return nil }
            return .publicKey(publicKeyPins[0])
        }
        let certificatePins = items.filter { $0.name == legacyCertificatePinQueryName }.compactMap(\.value)
        guard certificatePins.count == 1, !certificatePins[0].isEmpty else { return nil }
        return .legacyCertificate(certificatePins[0])
    }

    public static func validPublicKeyPin(_ value: String) -> Bool {
        let prefix = "p256-sha256-"
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        guard digest.count == 43 else { return false }
        return digest.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// FSKit uses the resource and volume identifiers to serialize work. Give
    /// every network mount a connection-specific UUID so a dead mount cannot
    /// leave a later connection to the same share permanently EBUSY.
    ///
    /// Although FSKit also exposes an eight-byte identifier qualifier for this
    /// purpose, macOS 26.4 drops it during the final LiveFS connector lookup.
    /// A plain UUID survives that handoff intact.
    public static func mountInstanceID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: {
                  $0.name == mountInstanceQueryName
              })?.value else { return nil }
        return UUID(uuidString: value)
    }
}

public struct GhostFileBonjourLease {
    // NetService does not expose record TTLs, so shares publish and refresh an
    // application-level lease in their TXT record.
    public static let advertisedTTL: TimeInterval = 6
    public static let legacyTTL: TimeInterval = 15
    public static let heartbeatInterval = Duration.seconds(2)
    public static let sweepInterval = Duration.seconds(1)

    public static func ttl(from txt: [String: Data]) -> TimeInterval {
        guard let data = txt["ttl"],
              let string = String(data: data, encoding: .utf8),
              let seconds = TimeInterval(string),
              seconds.isFinite else {
            return legacyTTL
        }
        return min(max(seconds, 4), 60)
    }

    public static func isExpired(lastSeen: Date, ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastSeen) >= ttl
    }
}

public enum GhostFileMountHealthState: String, Codable, Equatable, Sendable {
    case online
    case degraded
    case error
    case offline
}

public enum GhostFileMountHealthEvent: Equatable, Sendable {
    case heartbeatSucceeded
    case heartbeatMissed
    case operationSucceeded
    case operationFailed
    case peerClosed
}

public struct GhostFileMountHealthSnapshot: Codable, Equatable, Sendable {
    public let mountID: UUID
    public let state: GhostFileMountHealthState
    public let detail: String?
    public let updatedAt: Date

    public init(mountID: UUID, state: GhostFileMountHealthState, detail: String?, updatedAt: Date) {
        self.mountID = mountID
        self.state = state
        self.detail = detail
        self.updatedAt = updatedAt
    }

    public func applying(
        _ event: GhostFileMountHealthEvent,
        detail newDetail: String? = nil,
        at date: Date = Date()
    ) -> Self {
        let nextState: GhostFileMountHealthState
        switch event {
        case .heartbeatSucceeded, .operationSucceeded:
            nextState = .online
        case .heartbeatMissed:
            // Heartbeat silence is only evidence for degradation. It must not
            // erase a real operation error or an explicit peer close.
            switch state {
            case .online, .degraded: nextState = .degraded
            case .error, .offline: nextState = state
            }
        case .operationFailed:
            nextState = .error
        case .peerClosed:
            nextState = .offline
        }
        return Self(
            mountID: mountID,
            state: nextState,
            detail: nextState == .online ? nil : newDetail ?? detail,
            updatedAt: date
        )
    }

    public func degradingIfStale(
        at date: Date = Date(),
        staleAfter: TimeInterval = GhostFileProtocol.heartbeatStaleAfter
    ) -> Self {
        guard state == .online, date.timeIntervalSince(updatedAt) > staleAfter else { return self }
        return Self(
            mountID: mountID,
            state: .degraded,
            detail: "No recent heartbeat",
            updatedAt: updatedAt
        )
    }
}

public enum GhostFileMountHealthStorage {
    private static let directoryComponents = ["GhostFile", "Mount Health"]
    private static let extensionBundleIdentifier = "org.ghostvm.ghostfile.fs"

    public static func writerURL(for mountID: UUID, fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directoryComponents.reduce(applicationSupport) {
            $0.appendingPathComponent($1, isDirectory: true)
        }.appendingPathComponent("\(mountID.uuidString.lowercased()).json")
    }

    public static func readerURL(
        for mountID: UUID,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        var url = homeDirectory
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(extensionBundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
        for component in directoryComponents {
            url.appendPathComponent(component, isDirectory: true)
        }
        return url.appendingPathComponent("\(mountID.uuidString.lowercased()).json")
    }
}

struct GhostFileHTTPRequest: Sendable {
    let operation: String
    let path: String?
    let offset: UInt64?
    let length: Int?
}

public enum GhostFileNodeType: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
    case other
}

public struct GhostFileCapabilities: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let shareID: UUID
    public let name: String
    public let readOnly: Bool
    public let transports: [String]
    public let maximumReadLength: Int
}

public struct GhostFileMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let type: GhostFileNodeType
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

public struct GhostFileDirectoryListing: Codable, Equatable, Sendable {
    public let path: String
    public let verifier: UInt64
    public let entries: [GhostFileMetadata]
    public let inlineContents: [GhostFileInlineContent]?

    public init(
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

public struct GhostFileInlineContent: Codable, Equatable, Sendable {
    public let name: String
    public let etag: String
    public let data: Data
}

public struct GhostFileErrorPayload: Codable, Equatable, Sendable {
    public let error: String
    public let errno: Int32?

    public init(error: String, errno: Int32? = nil) {
        self.error = error
        self.errno = errno
    }
}

public enum GhostFileCreateType: String, Codable, Equatable, Sendable {
    case file
    case directory
}

public struct GhostFileCreateRequest: Codable, Equatable, Sendable {
    public let type: GhostFileCreateType
    public let mode: UInt32

    public init(type: GhostFileCreateType, mode: UInt32) {
        self.type = type
        self.mode = mode
    }
}

public struct GhostFileSymbolicLinkRequest: Codable, Equatable, Sendable {
    public let destination: String

    public init(destination: String) {
        self.destination = destination
    }
}

public struct GhostFileRenameRequest: Codable, Equatable, Sendable {
    public let destinationPath: String

    public init(destinationPath: String) {
        self.destinationPath = destinationPath
    }
}

public struct GhostFileSetAttributesRequest: Codable, Equatable, Sendable {
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
