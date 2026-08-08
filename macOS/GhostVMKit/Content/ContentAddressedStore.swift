import CryptoKit
import Foundation

public enum ContentStoreError: Error, Equatable {
    case unsupportedDigestAlgorithm(String)
    case invalidDigest(String)
    case digestMismatch(expected: ContentDigest, actual: ContentDigest)
    case blobNotFound(ContentDigest)
}

/// OCI-style content digest, currently restricted to SHA-256.
public struct ContentDigest: Codable, Hashable, Sendable, CustomStringConvertible {
    public let algorithm: String
    public let encoded: String

    public init(algorithm: String, encoded: String) throws {
        guard algorithm == "sha256" else {
            throw ContentStoreError.unsupportedDigestAlgorithm(algorithm)
        }
        let lowercaseHex = CharacterSet(charactersIn: "0123456789abcdef")
        guard encoded.count == 64, encoded.unicodeScalars.allSatisfy(lowercaseHex.contains) else {
            throw ContentStoreError.invalidDigest("\(algorithm):\(encoded)")
        }
        self.algorithm = algorithm
        self.encoded = encoded
    }

    public init(_ value: String) throws {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw ContentStoreError.invalidDigest(value)
        }
        try self.init(algorithm: String(parts[0]), encoded: String(parts[1]))
    }

    public var description: String {
        "\(algorithm):\(encoded)"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public static func sha256(_ data: Data) -> ContentDigest {
        let encoded = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try! ContentDigest(algorithm: "sha256", encoded: encoded)
    }
}

/// On-disk locations for immutable blobs and mutable image metadata.
public struct ContentStoreLayout: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var blobsURL: URL { rootURL.appendingPathComponent("blobs", isDirectory: true) }
    public var ingestURL: URL { rootURL.appendingPathComponent("ingest", isDirectory: true) }
    public var referencesURL: URL { rootURL.appendingPathComponent("refs", isDirectory: true) }
    public var snapshotsURL: URL { rootURL.appendingPathComponent("snapshots", isDirectory: true) }

    public func blobURL(for digest: ContentDigest) -> URL {
        blobsURL
            .appendingPathComponent(digest.algorithm, isDirectory: true)
            .appendingPathComponent(digest.encoded, isDirectory: false)
    }
}

/// Append-only content store. Publication is a same-volume rename from ingest
/// into the digest path, so readers never observe a partial blob.
public actor ContentAddressedStore {
    public let layout: ContentStoreLayout

    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.layout = ContentStoreLayout(rootURL: rootURL)
        self.fileManager = fileManager
    }

    public func prepare() throws {
        try fileManager.createDirectory(at: layout.blobsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.ingestURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.referencesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: layout.snapshotsURL, withIntermediateDirectories: true)
    }

    @discardableResult
    public func put(_ data: Data) throws -> ContentDigest {
        try prepare()
        let digest = ContentDigest.sha256(data)
        let temporaryURL = layout.ingestURL.appendingPathComponent(UUID().uuidString.lowercased())
        try data.write(to: temporaryURL)
        _ = try publish(temporaryURL: temporaryURL, expectedDigest: digest)
        return digest
    }

    /// Copies an external download into ingest, verifies it, then publishes it.
    @discardableResult
    public func importBlob(at sourceURL: URL, expectedDigest: ContentDigest) throws -> URL {
        try prepare()
        let temporaryURL = layout.ingestURL.appendingPathComponent(UUID().uuidString.lowercased())
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        return try publish(temporaryURL: temporaryURL, expectedDigest: expectedDigest)
    }

    public func contains(_ digest: ContentDigest) -> Bool {
        fileManager.fileExists(atPath: layout.blobURL(for: digest).path)
    }

    public func blobURL(for digest: ContentDigest) throws -> URL {
        let url = layout.blobURL(for: digest)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ContentStoreError.blobNotFound(digest)
        }
        return url
    }

    private func publish(temporaryURL: URL, expectedDigest: ContentDigest) throws -> URL {
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let actualDigest = try Self.sha256(of: temporaryURL)
        guard actualDigest == expectedDigest else {
            throw ContentStoreError.digestMismatch(expected: expectedDigest, actual: actualDigest)
        }

        let destinationURL = layout.blobURL(for: actualDigest)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        shouldRemoveTemporary = false
        return destinationURL
    }

    private static func sha256(of url: URL) throws -> ContentDigest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let encoded = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return try ContentDigest(algorithm: "sha256", encoded: encoded)
    }
}
