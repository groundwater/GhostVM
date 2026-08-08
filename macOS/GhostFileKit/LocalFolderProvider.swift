import Darwin
import Foundation

public final class LocalFolderProvider: GhostFileProvider, @unchecked Sendable {
    public let rootURL: URL
    private let resolvedRootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        self.resolvedRootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
    }

    public func metadata(path: String) async throws -> GhostFileProviderMetadata {
        try fileMetadata(at: resolvedURL(path: path, followFinalSymbolicLink: false))
    }

    public func contentsOfDirectory(path: String) async throws -> [GhostFileProviderMetadata] {
        let url = try resolvedURL(path: path, followFinalSymbolicLink: true)
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().map {
            try fileMetadata(at: url.appendingPathComponent($0, isDirectory: false))
        }
    }

    public func read(path: String, offset: UInt64, length: Int) async throws -> GhostFileProviderRead {
        let url = try resolvedURL(path: path, followFinalSymbolicLink: true)
        let metadata = try fileMetadata(at: url)
        guard metadata.type == .file else { throw POSIXError(.EINVAL) }
        return .fileRegion(path: url.path, identity: metadata.etag, offset: offset, length: length)
    }

    public func readSymbolicLink(path: String) async throws -> String {
        let url = try resolvedURL(path: path, followFinalSymbolicLink: false)
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError.current() }
        guard info.st_mode & S_IFMT == S_IFLNK else { throw POSIXError(.EINVAL) }
        return try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    public func create(path: String, type: GhostFileProviderCreateType, mode: UInt32) async throws -> GhostFileProviderMetadata {
        let url = try resolvedURL(path: path, followFinalSymbolicLink: false)
        let permissions = mode_t(mode & 0o7777)
        switch type {
        case .file:
            let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, permissions)
            guard descriptor >= 0 else { throw POSIXError.current() }
            guard Darwin.close(descriptor) == 0 else { throw POSIXError.current() }
        case .directory:
            guard Darwin.mkdir(url.path, permissions) == 0 else { throw POSIXError.current() }
        }
        return try fileMetadata(at: url)
    }

    public func createSymbolicLink(path: String, destination: String) async throws -> GhostFileProviderMetadata {
        let url = try resolvedURL(path: path, followFinalSymbolicLink: false)
        guard Darwin.symlink(destination, url.path) == 0 else { throw POSIXError.current() }
        return try fileMetadata(at: url)
    }

    public func write(path: String, offset: UInt64, data: Data) async throws -> GhostFileProviderMetadata {
        guard offset <= UInt64(Int64.max) else { throw POSIXError(.EOVERFLOW) }
        let url = try resolvedURL(path: path, followFinalSymbolicLink: true)
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError.current() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        let descriptor = Darwin.open(url.path, O_WRONLY)
        guard descriptor >= 0 else { throw POSIXError.current() }
        defer { Darwin.close(descriptor) }
        var written = 0
        try data.withUnsafeBytes { bytes in
            while written < bytes.count {
                let result = Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written,
                    off_t(offset) + off_t(written)
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw POSIXError.current() }
                written += result
            }
        }
        return try fileMetadata(at: url)
    }

    public func setAttributes(path: String, attributes: GhostFileProviderAttributes) async throws -> GhostFileProviderMetadata {
        let url = try resolvedURL(path: path, followFinalSymbolicLink: true)
        if let size = attributes.size {
            guard size <= UInt64(Int64.max), Darwin.truncate(url.path, off_t(size)) == 0 else {
                throw POSIXError.current()
            }
        }
        if let mode = attributes.mode, Darwin.chmod(url.path, mode_t(mode & 0o7777)) != 0 {
            throw POSIXError.current()
        }
        if attributes.modifiedSeconds != nil || attributes.accessedSeconds != nil {
            func requestedTime(seconds: Int64?, nanoseconds: Int32?) -> timespec {
                guard let seconds else { return timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)) }
                return timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds ?? 0))
            }
            let times = [
                requestedTime(seconds: attributes.accessedSeconds, nanoseconds: attributes.accessedNanoseconds),
                requestedTime(seconds: attributes.modifiedSeconds, nanoseconds: attributes.modifiedNanoseconds),
            ]
            let result = times.withUnsafeBufferPointer {
                Darwin.utimensat(AT_FDCWD, url.path, $0.baseAddress, 0)
            }
            guard result == 0 else { throw POSIXError.current() }
        }
        return try fileMetadata(at: url)
    }

    public func remove(path: String) async throws {
        let url = try resolvedURL(path: path, followFinalSymbolicLink: false)
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError.current() }
        let result = info.st_mode & S_IFMT == S_IFDIR ? Darwin.rmdir(url.path) : Darwin.unlink(url.path)
        guard result == 0 else { throw POSIXError.current() }
    }

    public func rename(path: String, destinationPath: String) async throws -> GhostFileProviderMetadata {
        let source = try resolvedURL(path: path, followFinalSymbolicLink: false)
        let destination = try resolvedURL(path: destinationPath, followFinalSymbolicLink: false)
        guard Darwin.rename(source.path, destination.path) == 0 else { throw POSIXError.current() }
        return try fileMetadata(at: destination)
    }

    private func resolvedURL(path: String, followFinalSymbolicLink: Bool) throws -> URL {
        guard !path.contains("\0"), !path.hasPrefix("/") else { throw POSIXError(.EINVAL) }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else { throw POSIXError(.EINVAL) }
        if components.isEmpty { return rootURL }
        let candidate = components.reduce(rootURL) {
            $0.appendingPathComponent(String($1), isDirectory: false)
        }.standardizedFileURL
        let containmentCandidate = followFinalSymbolicLink
            ? candidate.resolvingSymlinksInPath().standardizedFileURL
            : candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRootURL.path
        guard containmentCandidate.path == rootPath || containmentCandidate.path.hasPrefix(rootPath + "/") else {
            throw POSIXError(.EINVAL)
        }
        return candidate
    }

    private func fileMetadata(at url: URL) throws -> GhostFileProviderMetadata {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw POSIXError.current() }
        let type: GhostFileProviderNodeType
        switch info.st_mode & S_IFMT {
        case S_IFREG: type = .file
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symbolicLink
        default: type = .other
        }
        let objectID = UInt64(info.st_ino) ^ (UInt64(info.st_dev) &* 0x9E37_79B9_7F4A_7C15)
        let modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        let modifiedNanoseconds = Int32(info.st_mtimespec.tv_nsec)
        let etagValue = objectID
            ^ UInt64(max(0, info.st_size))
            ^ UInt64(bitPattern: modifiedSeconds)
            ^ UInt64(bitPattern: Int64(modifiedNanoseconds))
        return GhostFileProviderMetadata(
            name: url.lastPathComponent,
            type: type,
            size: UInt64(max(0, info.st_size)),
            mode: UInt32(info.st_mode),
            uid: info.st_uid,
            gid: info.st_gid,
            objectID: max(objectID, 3),
            modifiedSeconds: modifiedSeconds,
            modifiedNanoseconds: modifiedNanoseconds,
            accessedSeconds: Int64(info.st_atimespec.tv_sec),
            accessedNanoseconds: Int32(info.st_atimespec.tv_nsec),
            changedSeconds: Int64(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int32(info.st_ctimespec.tv_nsec),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int32(info.st_birthtimespec.tv_nsec),
            etag: "\"node-\(String(etagValue, radix: 16))\""
        )
    }
}

private extension POSIXError {
    static func current() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
