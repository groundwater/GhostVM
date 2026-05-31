import Foundation
import os

/// Migrates a VM bundle from raw disk.img to ASIF format.
/// The source bundle is NEVER modified — the migration creates a new bundle at the destination.
public final class VMMigrationService: NSObject {

    private static let logger = Logger(subsystem: "org.ghostvm", category: "VMMigrationService")

    public enum MigrationError: Error, LocalizedError {
        case sourceNotFound
        case diskNotFound
        case asifCreationFailed(Int32, String)
        case moveFailed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .sourceNotFound: return "Source VM bundle not found"
            case .diskNotFound: return "Source disk.img not found"
            case .asifCreationFailed(let code, let detail):
                return detail.isEmpty ? "Failed to create ASIF image (exit \(code))" : detail
            case .moveFailed(let msg): return "Failed to finalize migration: \(msg)"
            case .cancelled: return "Migration cancelled"
            }
        }
    }

    private let fileManager = FileManager.default
    private let cancelLock = NSLock()
    private var _isCancelled = false
    private var diskutilProcess: Process?

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return _isCancelled
    }

    public override init() { super.init() }

    /// Cancel the in-progress migration. Safe to call from any thread.
    @objc public func cancel() {
        cancelLock.lock()
        _isCancelled = true
        let process = diskutilProcess
        cancelLock.unlock()
        process?.terminate()
    }

    /// Migrate a VM bundle to ASIF format.
    ///
    /// - Parameters:
    ///   - source: URL of the existing .GhostVM bundle
    ///   - destination: URL for the new .GhostVM bundle (must not exist)
    ///   - progressHandler: Called with (fractionCompleted, statusMessage)
    ///   - outputHandler: Called with each line of diskutil output for terminal display
    public func migrate(
        source: URL,
        destination: URL,
        progressHandler: @escaping (Double, String) -> Void,
        outputHandler: @escaping (String) -> Void = { _ in }
    ) throws {
        cancelLock.lock()
        _isCancelled = false
        diskutilProcess = nil
        cancelLock.unlock()

        let srcLayout = VMFileLayout(bundleURL: source)

        guard fileManager.fileExists(atPath: source.path) else {
            throw MigrationError.sourceNotFound
        }
        guard fileManager.fileExists(atPath: srcLayout.diskURL.path) else {
            throw MigrationError.diskNotFound
        }

        // Work in a temp directory, then atomic move to destination.
        // This allows migrating to the same path (overwrite) safely,
        // and ensures partial failures leave no debris at the destination.
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("ghostvm-migration-\(UUID().uuidString).GhostVM")
        let dstLayout = VMFileLayout(bundleURL: tempDir)
        try dstLayout.ensureBundleDirectory()

        // Copy non-disk files first (small, fast)
        progressHandler(0.0, "Copying VM configuration...")
        let filesToCopy: [(String, URL, URL)] = [
            ("config.json", srcLayout.configURL, dstLayout.configURL),
            ("HardwareModel.bin", srcLayout.hardwareModelURL, dstLayout.hardwareModelURL),
            ("MachineIdentifier.bin", srcLayout.machineIdentifierURL, dstLayout.machineIdentifierURL),
            ("AuxiliaryStorage.bin", srcLayout.auxiliaryStorageURL, dstLayout.auxiliaryStorageURL),
        ]

        for (_, src, dst) in filesToCopy {
            if fileManager.fileExists(atPath: src.path) {
                try fileManager.copyItem(at: src, to: dst)
            }
            if isCancelled { cleanup(tempDir); throw MigrationError.cancelled }
        }

        // Copy optional files (icon, etc.)
        if fileManager.fileExists(atPath: srcLayout.customIconURL.path) {
            try? fileManager.copyItem(at: srcLayout.customIconURL, to: dstLayout.customIconURL)
        }

        if isCancelled { cleanup(destination); throw MigrationError.cancelled }

        // Convert raw disk to ASIF using diskutil (handles sparsity natively)
        progressHandler(0.1, "Converting disk to ASIF format...")
        let diskutil = Process()
        diskutil.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        diskutil.arguments = ["image", "create", "from",
                              "--verbose",
                              "--format", "ASIF",
                              srcLayout.diskURL.path,
                              dstLayout.diskURL.path]

        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        diskutil.standardOutput = stdoutPipe
        diskutil.standardError = stderrPipe

        // Collect stderr for error reporting (synchronized)
        let stderrLock = NSLock()
        var stderrOutput = ""

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if self?.isCancelled == true { return }
            outputHandler(text)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if self?.isCancelled == true { return }
            stderrLock.lock()
            stderrOutput += text
            stderrLock.unlock()
            outputHandler(text)
        }

        // Store process reference so cancel() can terminate it
        cancelLock.lock()
        diskutilProcess = diskutil
        cancelLock.unlock()

        try diskutil.run()
        diskutil.waitUntilExit()

        cancelLock.lock()
        diskutilProcess = nil
        cancelLock.unlock()

        // Stop handlers BEFORE draining to avoid concurrent access
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drain remaining pipe data
        if let remaining = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !remaining.isEmpty {
            outputHandler(remaining)
        }
        if let remaining = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), !remaining.isEmpty {
            stderrLock.lock()
            stderrOutput += remaining
            stderrLock.unlock()
            outputHandler(remaining)
        }

        guard diskutil.terminationStatus == 0 else {
            stderrLock.lock()
            let detail = stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            stderrLock.unlock()
            Self.logger.error("diskutil failed (exit \(diskutil.terminationStatus)): \(detail, privacy: .public)")
            cleanup(tempDir)
            throw MigrationError.asifCreationFailed(diskutil.terminationStatus, detail)
        }

        if isCancelled { cleanup(tempDir); throw MigrationError.cancelled }

        // Verify the output is valid ASIF
        let outputFormat = DiskFormat.detect(at: dstLayout.diskURL)
        guard outputFormat == .asif else {
            Self.logger.error("diskutil produced non-ASIF output: \(outputFormat.rawValue, privacy: .public)")
            cleanup(tempDir)
            throw MigrationError.asifCreationFailed(0, "Conversion completed but output is not ASIF format")
        }

        if isCancelled { cleanup(tempDir); throw MigrationError.cancelled }

        // Atomic move: remove destination if it exists, then move temp → destination
        progressHandler(0.95, "Finalizing...")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: tempDir, to: destination)
        } catch {
            cleanup(tempDir)
            throw MigrationError.moveFailed(error.localizedDescription)
        }

        progressHandler(1.0, "Migration complete")
    }

    private func cleanup(_ destination: URL) {
        do {
            try fileManager.removeItem(at: destination)
        } catch {
            Self.logger.warning("Failed to clean up partial migration at \(destination.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
