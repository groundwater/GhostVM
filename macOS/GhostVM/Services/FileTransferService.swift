import Foundation
import AppKit
import Combine
import GhostVMKit

/// Represents the state of a file transfer
public enum FileTransferState: Equatable {
    case idle
    case preparing
    case transferring(progress: Double)
    case completed(path: String)
    case failed(error: String)

    public var isActive: Bool {
        switch self {
        case .preparing, .transferring:
            return true
        default:
            return false
        }
    }
}

/// Represents a single file transfer operation
public struct FileTransfer: Identifiable {
    public let id = UUID()
    public let filename: String
    public let size: Int64
    public var state: FileTransferState
    public let direction: TransferDirection
    public let startTime: Date

    public enum TransferDirection {
        case hostToGuest
        case guestToHost
    }

    public init(filename: String, size: Int64, direction: TransferDirection) {
        self.filename = filename
        self.size = size
        self.state = .idle
        self.direction = direction
        self.startTime = Date()
    }
}

/// Service for managing file transfers between host and guest VM
@MainActor
public final class FileTransferService: ObservableObject {
    /// Active transfers
    @Published public private(set) var transfers: [FileTransfer] = []

    /// Whether a transfer is currently in progress
    @Published public private(set) var isTransferring: Bool = false

    /// Whether the drop zone should be highlighted
    @Published public var isDropTargetActive: Bool = false

    /// Last error message
    @Published public private(set) var lastError: String?

    /// Number of files queued in guest waiting to be fetched
    @Published public private(set) var queuedGuestFileCount: Int = 0

    /// Full paths of files queued in guest (from event stream)
    public private(set) var queuedGuestFilePaths: [String] = []

    private var ghostClient: (any GhostClientProtocol)?
    private let maxConcurrentTransfers = 3
    private var activeTransferCount = 0

    public init() {}

    /// Configure the service with a GhostClient (no polling)
    public func configure(client: any GhostClientProtocol) {
        self.ghostClient = client
    }

    /// Update the queued file list from EventStreamService push events
    public func updateQueuedFiles(_ files: [String]) {
        queuedGuestFilePaths = files
        queuedGuestFileCount = files.count
    }

    /// Queue of files pending transfer (with relative paths for folder structure)
    private var pendingFiles: [FileWithRelativePath] = []
    private var isProcessingQueue = false
    private var currentBatchID: String?
    private var currentBatchTotal: Int = 0
    private var currentBatchSent: Int = 0

    /// Send files to the guest VM
    /// - Parameter files: Files with their relative paths to send
    public func sendFiles(_ files: [FileWithRelativePath]) {
        print("[FileTransfer] sendFiles called with \(files.count) file(s)")
        guard ghostClient != nil else {
            print("[FileTransfer] ERROR: ghostClient is nil!")
            lastError = "Not connected to guest"
            return
        }

        // Add to queue with batch tracking
        currentBatchID = UUID().uuidString
        currentBatchTotal = files.count
        currentBatchSent = 0
        pendingFiles.append(contentsOf: files)
        print("[FileTransfer] Queued \(files.count) file(s), batch \(currentBatchID ?? "nil"), total pending: \(pendingFiles.count)")

        // Start processing if not already
        processNextFile()
    }

    /// Process files one at a time
    private func processNextFile() {
        guard !isProcessingQueue else { return }
        guard let client = ghostClient else { return }
        guard !pendingFiles.isEmpty else { return }

        isProcessingQueue = true
        let file = pendingFiles.removeFirst()
        currentBatchSent += 1
        let batchID = currentBatchID
        let isLast = currentBatchSent >= currentBatchTotal

        print("[FileTransfer] Processing: \(file.relativePath) (\(pendingFiles.count) remaining, batch isLast=\(isLast))")
        sendFile(file.url, relativePath: file.relativePath, batchID: batchID, isLastInBatch: isLast, client: client) { [weak self] in
            // Completion callback - process next file
            Task { @MainActor in
                self?.isProcessingQueue = false
                self?.processNextFile()
            }
        }
    }

    /// Send a single file to the guest VM (streaming)
    /// - Parameters:
    ///   - url: The local file URL
    ///   - relativePath: The relative path to preserve folder structure (e.g., "folder/file.txt")
    ///   - batchID: Batch identifier for grouped Finder reveal
    ///   - isLastInBatch: Whether this is the last file in the batch
    ///   - client: The GhostClient to use for transfer
    ///   - completion: Callback when transfer completes
    private func sendFile(_ url: URL, relativePath: String, batchID: String?, isLastInBatch: Bool, client: any GhostClientProtocol, completion: (() -> Void)? = nil) {
        let displayName = relativePath

        // Get file size and permissions
        let fileSize: Int64
        let permissions: Int?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attributes[.size] as? Int64) ?? 0
            permissions = attributes[.posixPermissions] as? Int
        } catch {
            lastError = "Cannot read file: \(error.localizedDescription)"
            completion?()
            return
        }

        var transfer = FileTransfer(filename: displayName, size: fileSize, direction: .hostToGuest)
        transfer.state = .preparing
        transfers.append(transfer)
        isTransferring = true

        let transferId = transfer.id

        // Run transfer on background thread to keep UI responsive
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                print("[FileTransfer] Streaming file: \(relativePath) (\(fileSize) bytes)")

                await MainActor.run {
                    self?.updateTransferState(id: transferId, state: .transferring(progress: 0))
                }

                // Stream to guest (no memory loading) - pass relative path for folder structure
                let savedPath = try await client.sendFile(fileURL: url, relativePath: relativePath, batchID: batchID, isLastInBatch: isLastInBatch, permissions: permissions) { progress in
                    Task { @MainActor in
                        self?.updateTransferState(id: transferId, state: .transferring(progress: progress))
                    }
                }

                print("[FileTransfer] Success! Saved at: \(savedPath)")
                await MainActor.run {
                    self?.updateTransferState(id: transferId, state: .completed(path: savedPath))
                    self?.updateIsTransferring()
                    completion?()
                }

            } catch {
                print("[FileTransfer] FAILED: \(error)")
                await MainActor.run {
                    self?.updateTransferState(id: transferId, state: .failed(error: error.localizedDescription))
                    self?.lastError = "Transfer failed: \(error.localizedDescription)"
                    self?.updateIsTransferring()
                    completion?()
                }
            }
        }
    }

    /// Fetch a file from the guest VM and save to host
    /// - Parameter guestPath: Path in the guest to fetch
    /// - Parameter savePanel: Whether to show a save panel (true) or save to Downloads (false)
    public func fetchFile(at guestPath: String, showSavePanel: Bool = true) {
        guard let client = ghostClient else {
            lastError = "Not connected to guest"
            return
        }

        let filename = URL(fileURLWithPath: guestPath).lastPathComponent
        var transfer = FileTransfer(filename: filename, size: 0, direction: .guestToHost)
        transfer.state = .preparing
        transfers.append(transfer)
        isTransferring = true

        let transferId = transfer.id

        Task {
            do {
                updateTransferState(id: transferId, state: .transferring(progress: 0.5))

                let (data, fetchedFilename, permissions) = try await client.fetchFile(at: guestPath)

                // Determine save location
                let saveURL: URL
                if showSavePanel {
                    guard let url = await showSavePanelAsync(suggestedFilename: fetchedFilename) else {
                        updateTransferState(id: transferId, state: .failed(error: "Save cancelled"))
                        updateIsTransferring()
                        return
                    }
                    saveURL = url
                } else {
                    // Save to Downloads
                    let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
                    saveURL = downloadsURL.appendingPathComponent(fetchedFilename)
                }

                // Write file
                try data.write(to: saveURL)
                Self.applyQuarantine(to: saveURL)

                // Apply permissions if provided
                if let permissions = permissions {
                    try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: saveURL.path)
                }

                updateTransferState(id: transferId, state: .completed(path: saveURL.path))

                // Reveal in Finder (only for single-file fetch with save panel)
                if showSavePanel {
                    NSWorkspace.shared.activateFileViewerSelecting([saveURL])
                }

            } catch {
                updateTransferState(id: transferId, state: .failed(error: error.localizedDescription))
                lastError = "Fetch failed: \(error.localizedDescription)"
            }

            updateIsTransferring()
        }
    }

    /// List available files from the guest
    public func listGuestFiles() async throws -> [String] {
        guard let client = ghostClient else {
            throw GhostClientError.notConnected
        }
        return try await client.listFiles()
    }

    /// Fetch all queued files from the guest and save to Downloads
    public func fetchAllGuestFiles() {
        NSLog("[FileTransfer] fetchAllGuestFiles called, ghostClient=%@, queuedPaths=%d",
              ghostClient != nil ? "present" : "NIL", queuedGuestFilePaths.count)
        guard let client = ghostClient else {
            NSLog("[FileTransfer] ERROR: ghostClient is nil — cannot fetch files")
            lastError = "Not connected to guest"
            return
        }

        // Use the file paths we already have from the event stream
        // instead of making a redundant HTTP round-trip via listGuestFiles()
        let files = queuedGuestFilePaths
        NSLog("[FileTransfer] Using %d file path(s) from event stream: %@", files.count, files.description)

        guard !files.isEmpty else {
            NSLog("[FileTransfer] No files to fetch — clearing stale toolbar state")
            queuedGuestFilePaths = []
            queuedGuestFileCount = 0
            return
        }

        Task {
            var savedURLs: [URL] = []
            var failedPaths: [String] = []
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!

            for guestPath in files {
                do {
                    NSLog("[FileTransfer] Fetching: %@", guestPath)
                    let (data, fetchedFilename, permissions) = try await client.fetchFile(at: guestPath)
                    let saveURL = downloadsURL.appendingPathComponent(fetchedFilename)
                    try data.write(to: saveURL)
                    Self.applyQuarantine(to: saveURL)

                    if let permissions = permissions {
                        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: saveURL.path)
                    }

                    savedURLs.append(saveURL)
                    NSLog("[FileTransfer] Fetched: %@", fetchedFilename)
                } catch {
                    NSLog("[FileTransfer] Failed to fetch %@: %@", guestPath, error.localizedDescription)
                    failedPaths.append(URL(fileURLWithPath: guestPath).lastPathComponent)
                }
            }

            // Reveal all files in Finder at once
            if !savedURLs.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
            }

            // Only clear the queue when ALL files transferred successfully
            if failedPaths.isEmpty {
                do {
                    try await client.clearFileQueue()
                    self.queuedGuestFilePaths = []
                    self.queuedGuestFileCount = 0
                    NSLog("[FileTransfer] Cleared guest file queue")
                } catch {
                    NSLog("[FileTransfer] ERROR clearing queue: %@", error.localizedDescription)
                    self.lastError = "Failed to clear queue: \(error.localizedDescription)"
                }
            } else {
                self.lastError = "Failed to fetch: \(failedPaths.joined(separator: ", "))"
                NSLog("[FileTransfer] %d file(s) failed, queue NOT cleared", failedPaths.count)
            }
        }
    }

    /// Clear the guest file queue without fetching (Deny action)
    public func clearGuestFileQueue() {
        guard let client = ghostClient else { return }
        Task {
            do {
                try await client.clearFileQueue()
                queuedGuestFileCount = 0
            } catch {
                lastError = "Failed to clear guest file queue: \(error.localizedDescription)"
            }
        }
    }

    /// Clear completed and failed transfers from the list
    public func clearCompletedTransfers() {
        transfers.removeAll { transfer in
            switch transfer.state {
            case .completed, .failed:
                return true
            default:
                return false
            }
        }
    }

    /// Cancel all active transfers
    public func cancelAllTransfers() {
        // Mark all active transfers as failed
        for i in transfers.indices {
            if transfers[i].state.isActive {
                transfers[i].state = .failed(error: "Cancelled")
            }
        }
        isTransferring = false
    }

    // MARK: - Private

    /// Mark a file as quarantined so Gatekeeper checks it before execution.
    private static func applyQuarantine(to url: URL) {
        let value = "0082;\(String(format: "%lx", Int(Date().timeIntervalSince1970)));GhostVM;"
        _ = value.withCString { ptr in
            setxattr(url.path, "com.apple.quarantine", ptr, strlen(ptr), 0, 0)
        }
    }

    private func updateTransferState(id: UUID, state: FileTransferState) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            transfers[index].state = state
            print("[FileTransfer] State updated: \(state)")
        }
    }

    private func updateIsTransferring() {
        let wasTransferring = isTransferring
        isTransferring = transfers.contains { $0.state.isActive }
        if wasTransferring != isTransferring {
            print("[FileTransfer] isTransferring changed: \(isTransferring)")
        }
    }

    private func showSavePanelAsync(suggestedFilename: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.canCreateDirectories = true

            panel.begin { response in
                if response == .OK {
                    continuation.resume(returning: panel.url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - File Size Formatting

extension FileTransfer {
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
