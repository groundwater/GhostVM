import CryptoKit
import Foundation
import SwiftUI

// MARK: - Feed & Cache Models

struct App2IPSWFeedEntry: Hashable, Identifiable {
    let firmwareURL: URL
    let productVersion: String
    let buildVersion: String
    let firmwareSHA1: String?

    var id: String {
        "\(productVersion)|\(buildVersion)|\(firmwareURL.absoluteString)"
    }

    var filename: String {
        firmwareURL.lastPathComponent
    }

    var displayName: String {
        "macOS \(productVersion) (\(buildVersion))"
    }
}

struct App2IPSWCachedImage: Hashable {
    let fileURL: URL
    let sizeBytes: Int64?

    var filename: String {
        fileURL.lastPathComponent
    }

    var sizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        if let sizeBytes {
            return formatter.string(fromByteCount: sizeBytes)
        }
        return "Downloaded"
    }
}

struct App2IPSWDownloadProgress {
    let bytesWritten: Int64
    let totalBytes: Int64
    let speedBytesPerSecond: Double
}

struct IPSWVerificationFailure {
    let filename: String
    let expected: String
    let actual: String
}

// MARK: - IPSW Service (feed + cache)

@MainActor
final class App2IPSWService: ObservableObject {
    static let shared = App2IPSWService()

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default

    private let feedURLKey = "SwiftUIIPSWFeedURL"
    private let cacheDirectoryKey = "SwiftUIIPSWCacheDirectoryPath"

    static let defaultFeedURL = URL(string: "https://mesu.apple.com/assets/macos/com_apple_macOSIPSW/com_apple_macOSIPSW.xml")!

    @Published private(set) var feedURL: URL
    @Published private(set) var cacheDirectory: URL

    init() {
        if let storedFeed = defaults.string(forKey: feedURLKey), let url = URL(string: storedFeed) {
            feedURL = url
        } else {
            feedURL = Self.defaultFeedURL
        }

        if let storedPath = defaults.string(forKey: cacheDirectoryKey), !storedPath.isEmpty {
            cacheDirectory = URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
        } else {
            cacheDirectory = Self.defaultCacheDirectory(fileManager: fileManager)
        }

        try? ensureCacheDirectory()
    }

    static func defaultCacheDirectory(fileManager: FileManager = .default) -> URL {
        if let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return supportDirectory.appendingPathComponent("GhostVM/IPSW", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GhostVM/IPSW", isDirectory: true)
    }

    func setFeedURL(_ url: URL) {
        feedURL = url
        defaults.set(url.absoluteString, forKey: feedURLKey)
    }

    func setCacheDirectory(path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        cacheDirectory = url
        try ensureCacheDirectory()
        defaults.set(url.path, forKey: cacheDirectoryKey)
    }

    func validateFeedURL(string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(domain: "App2IPSW", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter a valid HTTP or HTTPS URL for the IPSW feed."])
        }
        return url
    }

    func listCachedImages() -> [App2IPSWCachedImage] {
        ensureCacheDirectoryIfNeeded()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var images: [App2IPSWCachedImage] = []
        for url in contents where url.pathExtension.lowercased() == "ipsw" {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                let size = values.fileSize.map { Int64($0) }
                images.append(App2IPSWCachedImage(fileURL: url, sizeBytes: size))
            }
        }
        return images.sorted { $0.fileURL.lastPathComponent.localizedCaseInsensitiveCompare($1.fileURL.lastPathComponent) == .orderedAscending }
    }

    func deleteCachedImage(filename: String) throws {
        let url = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let partial = url.appendingPathExtension("download")
        if fileManager.fileExists(atPath: partial.path) {
            try fileManager.removeItem(at: partial)
        }
    }

    func partialDownloadSize(filename: String) -> Int64? {
        let url = cacheDirectory.appendingPathComponent(filename, isDirectory: false)
            .appendingPathExtension("download")
        guard fileManager.fileExists(atPath: url.path),
              let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 0 else {
            return nil
        }
        return size
    }

    // MARK: - Feed

    func fetchFeed(from overrideURL: URL? = nil) async throws -> [App2IPSWFeedEntry] {
        let target = overrideURL ?? feedURL
        var request = URLRequest(url: target)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "App2IPSW", code: 2, userInfo: [NSLocalizedDescriptionKey: "Received an invalid response from the IPSW feed."])
        }
        return try parseFeedEntries(data: data)
    }

    private func parseFeedEntries(data: Data) throws -> [App2IPSWFeedEntry] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let restoreDictionaries = collectRestoreDictionaries(from: plist)
        var deduped: [String: App2IPSWFeedEntry] = [:]

        for restore in restoreDictionaries {
            guard
                let firmwareString = restore["FirmwareURL"] as? String,
                let firmwareURL = URL(string: firmwareString),
                let productVersion = restore["ProductVersion"] as? String,
                let buildVersion = restore["BuildVersion"] as? String
            else {
                continue
            }

            let entry = App2IPSWFeedEntry(
                firmwareURL: firmwareURL,
                productVersion: productVersion,
                buildVersion: buildVersion,
                firmwareSHA1: restore["FirmwareSHA1"] as? String
            )
            deduped[entry.id] = entry
        }

        let sorted = deduped.values.sorted { lhs, rhs in
            let leftParts = versionComponents(lhs.productVersion)
            let rightParts = versionComponents(rhs.productVersion)
            if leftParts != rightParts {
                return compareVersionParts(leftParts, rightParts) > 0
            }
            if lhs.buildVersion != rhs.buildVersion {
                return lhs.buildVersion > rhs.buildVersion
            }
            return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
        return sorted
    }

    private func collectRestoreDictionaries(from object: Any) -> [[String: Any]] {
        var restores: [[String: Any]] = []
        if let dict = object as? [String: Any] {
            if dict["FirmwareURL"] != nil && dict["ProductVersion"] != nil && dict["BuildVersion"] != nil {
                restores.append(dict)
            }
            for value in dict.values {
                restores.append(contentsOf: collectRestoreDictionaries(from: value))
            }
        } else if let array = object as? [Any] {
            for element in array {
                restores.append(contentsOf: collectRestoreDictionaries(from: element))
            }
        }
        return restores
    }

    private func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    private func compareVersionParts(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let maxCount = max(lhs.count, rhs.count)
        for index in 0..<maxCount {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left - right
            }
        }
        return 0
    }

    // MARK: - Download

    private static let maxRetries = 10

    func download(
        _ entry: App2IPSWFeedEntry,
        resume: Bool = false,
        progress: @escaping (App2IPSWDownloadProgress) -> Void
    ) async throws -> (image: App2IPSWCachedImage, verificationFailure: IPSWVerificationFailure?) {
        try ensureCacheDirectory()
        let destination = cacheDirectory.appendingPathComponent(entry.filename, isDirectory: false)
        let temporary = destination.appendingPathExtension("download")

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        var existingSize: Int64 = 0
        if resume, fileManager.fileExists(atPath: temporary.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: temporary.path)
            existingSize = (attrs[.size] as? Int64) ?? 0
        } else {
            if fileManager.fileExists(atPath: temporary.path) {
                try fileManager.removeItem(at: temporary)
            }
            guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: nil) else {
                throw NSError(domain: "App2IPSW", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to prepare download destination."])
            }
        }

        let fileHandle = try FileHandle(forWritingTo: temporary)
        defer {
            try? fileHandle.close()
        }

        if existingSize > 0 {
            try fileHandle.seekToEnd()
        }

        var written: Int64 = existingSize
        var totalExpected: Int64 = 0
        let start = Date()
        var retriesRemaining = Self.maxRetries

        // Outer loop: each iteration opens a new byte stream (possibly resuming).
        // Transient network errors trigger a retry with a Range request.
        outerLoop: while true {
            let bytes: URLSession.AsyncBytes
            if written > 0 {
                var request = URLRequest(url: entry.firmwareURL)
                request.setValue("bytes=\(written)-", forHTTPHeaderField: "Range")
                let (resumeBytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 206 {
                    bytes = resumeBytes
                    let contentLength = response.expectedContentLength > 0 ? response.expectedContentLength : 0
                    totalExpected = contentLength > 0 ? written + contentLength : totalExpected
                } else {
                    // Server doesn't support range requests — restart from scratch
                    try fileHandle.seek(toOffset: 0)
                    try fileHandle.truncate(atOffset: 0)
                    written = 0
                    let (freshBytes, freshResponse) = try await URLSession.shared.bytes(from: entry.firmwareURL)
                    bytes = freshBytes
                    totalExpected = freshResponse.expectedContentLength > 0 ? freshResponse.expectedContentLength : 0
                }
            } else {
                let (freshBytes, response) = try await URLSession.shared.bytes(from: entry.firmwareURL)
                bytes = freshBytes
                totalExpected = response.expectedContentLength > 0 ? response.expectedContentLength : 0
            }

            var buffer = Data()

            do {
                for try await byte in bytes {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    buffer.append(byte)
                    written += 1

                    if buffer.count >= 1 << 20 {
                        try fileHandle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                        let elapsed = max(Date().timeIntervalSince(start), 0.001)
                        let speed = Double(written) / elapsed
                        progress(App2IPSWDownloadProgress(bytesWritten: written, totalBytes: totalExpected, speedBytesPerSecond: speed))
                    }
                }

                // Stream ended normally — flush remaining buffer
                if !buffer.isEmpty {
                    try fileHandle.write(contentsOf: buffer)
                    let elapsed = max(Date().timeIntervalSince(start), 0.001)
                    let speed = Double(written) / elapsed
                    progress(App2IPSWDownloadProgress(bytesWritten: written, totalBytes: totalExpected, speedBytesPerSecond: speed))
                }
                break outerLoop
            } catch is CancellationError {
                // Flush what we have before deleting
                if !buffer.isEmpty {
                    try? fileHandle.write(contentsOf: buffer)
                }
                try? fileManager.removeItem(at: temporary)
                throw CancellationError()
            } catch {
                // Transient error — flush buffer to disk and retry
                if !buffer.isEmpty {
                    try? fileHandle.write(contentsOf: buffer)
                }
                try? fileHandle.synchronize()

                retriesRemaining -= 1
                if retriesRemaining <= 0 {
                    // Out of retries — keep .download file for manual resume
                    throw error
                }

                // Exponential backoff: 1s, 2s, 4s, 8s… capped at 30s
                let attempt = Self.maxRetries - retriesRemaining
                let delay = min(pow(2.0, Double(attempt - 1)), 30.0)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Re-check the actual file size before resuming
                try? fileHandle.synchronize()
                let offset = try fileHandle.seekToEnd()
                written = Int64(offset)
            }
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporary, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            let cached = App2IPSWCachedImage(
                fileURL: destination,
                sizeBytes: values.fileSize.map { Int64($0) }
            )

            // Verify SHA1 if the feed provided one
            var failure: IPSWVerificationFailure? = nil
            if let expectedSHA1 = entry.firmwareSHA1, !expectedSHA1.isEmpty {
                let actualSHA1 = try Self.sha1Hash(of: destination)
                if actualSHA1.lowercased() != expectedSHA1.lowercased() {
                    failure = IPSWVerificationFailure(
                        filename: entry.filename,
                        expected: expectedSHA1,
                        actual: actualSHA1
                    )
                }
            }

            return (cached, failure)
        } catch {
            try? fileManager.removeItem(at: temporary)
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Compute SHA1 hash of a file by streaming in chunks.
    private static func sha1Hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { return false }
            sha1.update(data: chunk)
            return true
        }) {}
        let digest = sha1.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private func ensureCacheDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? ensureCacheDirectory()
        }
    }

    private func ensureCacheDirectory() throws {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
}

// MARK: - Restore Image Store

struct App2RestoreImage: Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let build: String
    let filename: String
    var sizeDescription: String
    var isDownloaded: Bool
    var isDownloading: Bool
    var hasPartialDownload: Bool = false
    var partialBytes: Int64 = 0
    let firmwareURL: URL
    let firmwareSHA1: String?
}

@MainActor
final class App2RestoreImageStore: ObservableObject {
    struct DownloadStatus {
        let bytesWritten: Int64
        let totalBytes: Int64
        let speedBytesPerSecond: Double
    }

    @Published var images: [App2RestoreImage] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var downloadStatuses: [String: DownloadStatus] = [:]
    @Published var verificationFailure: IPSWVerificationFailure? = nil

    private let service: App2IPSWService
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(service: App2IPSWService = .shared) {
        self.service = service
        Task {
            await reload()
        }
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            let entries = try await service.fetchFeed()
            let cached = service.listCachedImages()
            let cachedByFilename = Dictionary(uniqueKeysWithValues: cached.map { ($0.filename, $0) })

            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            formatter.includesUnit = true

            var all: [App2RestoreImage] = entries.map { entry in
                let cachedImage = cachedByFilename[entry.filename]
                let isDownloaded = cachedImage != nil
                let partialSize = isDownloaded ? nil : service.partialDownloadSize(filename: entry.filename)
                let sizeDescription: String
                if let cachedImage {
                    sizeDescription = cachedImage.sizeDescription
                } else if let partialSize {
                    sizeDescription = "\(formatter.string(fromByteCount: partialSize)) downloaded (partial)"
                } else {
                    sizeDescription = "Not downloaded"
                }
                return App2RestoreImage(
                    id: entry.id,
                    name: entry.displayName,
                    version: entry.productVersion,
                    build: entry.buildVersion,
                    filename: entry.filename,
                    sizeDescription: sizeDescription,
                    isDownloaded: isDownloaded,
                    isDownloading: false,
                    hasPartialDownload: partialSize != nil,
                    partialBytes: partialSize ?? 0,
                    firmwareURL: entry.firmwareURL,
                    firmwareSHA1: entry.firmwareSHA1
                )
            }

            // Include any cached IPSWs that are not present in the current feed.
            let knownFilenames = Set(all.map { $0.filename })
            let orphaned = cached.filter { !knownFilenames.contains($0.filename) }
            for cachedImage in orphaned {
                let filename = cachedImage.filename
                let baseName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
                let title = baseName.isEmpty ? filename : baseName

                let guessed = guessVersionAndBuild(from: filename)
                let version = guessed?.version ?? "Unknown"
                let build = guessed?.build ?? "Unknown"
                let displayName: String
                if let guessed {
                    displayName = "macOS \(guessed.version) (\(guessed.build))"
                } else {
                    displayName = title
                }

                let image = App2RestoreImage(
                    id: "cached:\(filename)",
                    name: displayName,
                    version: version,
                    build: build,
                    filename: filename,
                    sizeDescription: cachedImage.sizeDescription,
                    isDownloaded: true,
                    isDownloading: false,
                    firmwareURL: cachedImage.fileURL,
                    firmwareSHA1: nil
                )
                all.append(image)
            }

            // Keep feed order first, then orphaned cached entries sorted by filename.
            let feedCount = entries.count
            if feedCount < all.count {
                let head = all.prefix(feedCount)
                let tail = all.suffix(all.count - feedCount).sorted {
                    $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
                }
                images = Array(head + tail)
            } else {
                images = all
            }
        } catch {
            errorMessage = error.localizedDescription
            images = []
        }
        isLoading = false
    }

    func toggleDownload(for image: App2RestoreImage) {
        guard let index = images.firstIndex(of: image) else { return }

        // Cancel an in-flight download.
        if images[index].isDownloading {
            if let task = downloadTasks[image.id] {
                task.cancel()
                downloadTasks.removeValue(forKey: image.id)
            }
            images[index].isDownloading = false
            downloadStatuses.removeValue(forKey: image.id)
            updatePartialState(at: index)
            return
        }

        if images[index].isDownloaded {
            do {
                try service.deleteCachedImage(filename: image.filename)
                images[index].isDownloaded = false
                images[index].hasPartialDownload = false
                images[index].partialBytes = 0
                images[index].sizeDescription = "Not downloaded"
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        guard !images[index].isDownloading else { return }
        images[index].isDownloading = true
        errorMessage = nil

        let entry = App2IPSWFeedEntry(
            firmwareURL: image.firmwareURL,
            productVersion: image.version,
            buildVersion: image.build,
            firmwareSHA1: image.firmwareSHA1
        )
        let shouldResume = images[index].hasPartialDownload

        downloadStatuses[image.id] = DownloadStatus(bytesWritten: 0, totalBytes: 0, speedBytesPerSecond: 0)

        let id = image.id
        let filename = image.filename
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.service.download(entry, resume: shouldResume) { progress in
                    Task { @MainActor in
                        self.downloadStatuses[id] = DownloadStatus(
                            bytesWritten: progress.bytesWritten,
                            totalBytes: progress.totalBytes,
                            speedBytesPerSecond: progress.speedBytesPerSecond
                        )
                    }
                }
                await MainActor.run {
                    if let updatedIndex = self.images.firstIndex(where: { $0.id == id }) {
                        self.images[updatedIndex].isDownloading = false
                        self.images[updatedIndex].isDownloaded = true
                        self.images[updatedIndex].hasPartialDownload = false
                        self.images[updatedIndex].partialBytes = 0
                        self.images[updatedIndex].sizeDescription = result.image.sizeDescription
                    }
                    self.downloadStatuses.removeValue(forKey: id)
                    self.downloadTasks.removeValue(forKey: id)
                    if let failure = result.verificationFailure {
                        self.verificationFailure = failure
                    }
                }
            } catch {
                if (error as? CancellationError) != nil {
                    await MainActor.run {
                        if let updatedIndex = self.images.firstIndex(where: { $0.id == id }) {
                            self.images[updatedIndex].isDownloading = false
                        }
                        self.downloadStatuses.removeValue(forKey: id)
                        self.downloadTasks.removeValue(forKey: id)
                    }
                    return
                }
                await MainActor.run {
                    if let updatedIndex = self.images.firstIndex(where: { $0.id == id }) {
                        self.images[updatedIndex].isDownloading = false
                        self.updatePartialState(at: updatedIndex)
                    }
                    self.downloadStatuses.removeValue(forKey: id)
                    self.downloadTasks.removeValue(forKey: id)
                    self.errorMessage = error.localizedDescription
                }
            }
        }

        downloadTasks[id] = task
    }

    private func updatePartialState(at index: Int) {
        let filename = images[index].filename
        if let partialSize = service.partialDownloadSize(filename: filename) {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useGB, .useMB]
            formatter.countStyle = .file
            formatter.includesUnit = true
            images[index].hasPartialDownload = true
            images[index].partialBytes = partialSize
            images[index].sizeDescription = "\(formatter.string(fromByteCount: partialSize)) downloaded (partial)"
        } else {
            images[index].hasPartialDownload = false
            images[index].partialBytes = 0
            images[index].sizeDescription = "Not downloaded"
        }
    }

    func trashFailedImage(filename: String) {
        let url = service.cacheDirectory.appendingPathComponent(filename, isDirectory: false)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if let index = images.firstIndex(where: { $0.filename == filename }) {
                images[index].isDownloaded = false
                images[index].sizeDescription = "Not downloaded"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Best-effort parser for filenames like:
    //   UniversalMac_15.1.1_24B91_Restore.ipsw
    //   Sonoma_15.0_24A335_Restore.ipsw
    private func guessVersionAndBuild(from filename: String) -> (version: String, build: String)? {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let parts = base.split(whereSeparator: { $0 == "_" || $0 == "-" })

        var version: String?
        var build: String?

        for (index, part) in parts.enumerated() {
            let token = String(part)
            if version == nil,
               token.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil {
                version = token
                if index + 1 < parts.count {
                    let next = String(parts[index + 1])
                    if next.range(of: #"^[0-9A-Za-z]+$"#, options: .regularExpression) != nil {
                        build = next
                    }
                }
                break
            }
        }

        guard let version else { return nil }
        return (version, build ?? "Unknown")
    }
}
