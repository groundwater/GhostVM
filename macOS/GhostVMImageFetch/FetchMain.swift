import Containerization
import ContainerizationArchive
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import CryptoKit
import Foundation

private let initfsReference = "ghcr.io/apple/containerization/vminit@sha256:a69ff331d77997042afc3c7389969be176dfb657ec9ed46366c0e057ec40a297"

private func writeStatus(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("ghostvm-image-fetch: \(message)\n".utf8))
}

private actor ImagePullProgress {
    private static let reportInterval: Int64 = 4 * 1024 * 1024

    private let reference: String
    private var completedBytes: Int64 = 0
    private var totalBytes: Int64 = 0
    private var lastReportedBytes: Int64 = 0

    init(reference: String) {
        self.reference = reference
    }

    func update(_ events: [ProgressEvent]) {
        for event in events {
            switch event {
            case .addSize(let value): completedBytes += value
            case .addTotalSize(let value): totalBytes += value
            case .addItems, .addTotalItems: break
            }
        }

        if completedBytes - lastReportedBytes >= Self.reportInterval {
            report()
        }
    }

    func finish() {
        report(force: true)
    }

    private func report(force: Bool = false) {
        guard force || completedBytes != lastReportedBytes else { return }
        lastReportedBytes = completedBytes
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        if totalBytes > 0 {
            let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            let percent = min(100, Int((Double(completedBytes) / Double(totalBytes)) * 100))
            writeStatus("Pulling \(reference): \(completed) / \(total) (\(percent)%)")
        } else {
            writeStatus("Pulling \(reference): \(completed)")
        }
    }
}

private struct FetchOptions {
    let root: URL
    let kernel: URL
    let image: String

    static func parse(_ arguments: [String]) throws -> FetchOptions {
        guard arguments.first == "fetch" else { throw FetchError.usage }
        var root: String?
        var kernel: String?
        var image: String?
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw FetchError.usage }
            switch arguments[index] {
            case "--root": root = arguments[index + 1]
            case "--kernel": kernel = arguments[index + 1]
            case "--image": image = arguments[index + 1]
            default: throw FetchError.usage
            }
            index += 2
        }
        guard let root, let kernel, let image else { throw FetchError.usage }
        return FetchOptions(
            root: URL(fileURLWithPath: root, isDirectory: true),
            kernel: URL(fileURLWithPath: kernel),
            image: image
        )
    }
}

private enum FetchError: Error, LocalizedError {
    case usage
    case unqualifiedImageReference(String)
    case kernelDownloadFailed
    case kernelDigestMismatch

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: ghostvm-image-fetch fetch --root PATH --kernel PATH --image IMAGE"
        case .unqualifiedImageReference(let reference):
            return "image reference must include an explicit registry domain: \(reference)"
        case .kernelDownloadFailed:
            return "failed to download the container kernel"
        case .kernelDigestMismatch:
            return "downloaded container kernel archive failed SHA-256 verification"
        }
    }
}

@main
private struct GhostVMImageFetch {
    static func main() async {
        do {
            let options = try FetchOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let references = try [options.image, initfsReference].map(normalizeReference)
            try await prepareKernel(at: options.kernel)
            let store = try ImageStore(path: options.root)
            for reference in references {
                writeStatus("Resolving image \(reference)...")
                do {
                    _ = try await store.get(reference: reference)
                    writeStatus("Image cached: \(reference)")
                    continue
                } catch let error as ContainerizationError where error.code == .notFound {
                    let progress = ImagePullProgress(reference: reference)
                    _ = try await store.pull(reference: reference, progress: { events in
                        await progress.update(events)
                    })
                    await progress.finish()
                }
                writeStatus("Image ready: \(reference)")
            }
            writeStatus("Fetch complete.")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            try? FileHandle.standardError.write(contentsOf: Data("ghostvm-image-fetch: \(message)\n".utf8))
            exit(125)
        }
    }

    private static func prepareKernel(at destination: URL) async throws {
        if FileManager.default.isReadableFile(atPath: destination.path) {
            writeStatus("Kernel ready (cached): \(destination.path)")
            return
        }

        let archiveURL = URL(string: "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst")!
        let expectedDigest = "f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91"
        let kernelPath = "opt/kata/share/kata-containers/vmlinux-6.18.15-186"
        writeStatus("Downloading container kernel...")
        let (downloadURL, response) = try await URLSession.shared.download(from: archiveURL)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw FetchError.kernelDownloadFailed
        }
        writeStatus("Verifying container kernel...")
        guard try sha256(of: downloadURL) == expectedDigest else {
            throw FetchError.kernelDigestMismatch
        }

        var reader = try ArchiveReader(file: downloadURL)
        var (entry, kernelData) = try reader.extractFile(path: kernelPath)
        if entry.fileType == .symbolicLink, let link = entry.symlinkTarget {
            let target = URL(filePath: kernelPath)
                .deletingLastPathComponent()
                .appending(path: link)
                .standardized
                .relativePath
            reader = try ArchiveReader(file: downloadURL)
            (entry, kernelData) = try reader.extractFile(path: target)
        }
        _ = entry
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try kernelData.write(to: destination, options: .atomic)
        writeStatus("Kernel ready: \(destination.path)")
    }

    private static func normalizeReference(_ value: String) throws -> String {
        let reference = try Reference.parse(value)
        guard reference.domain != nil else {
            throw FetchError.unqualifiedImageReference(value)
        }
        reference.normalize()
        return reference.description
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
