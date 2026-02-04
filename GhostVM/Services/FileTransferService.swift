import Foundation
import AppKit
import Combine

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

    private var ghostClient: GhostClient?
    private let maxConcurrentTransfers = 3
    private var activeTransferCount = 0
    private var pollTimer: Timer?

    public init() {}

    /// Configure the service with a GhostClient
    public func configure(client: GhostClient) {
        self.ghostClient = client
        startPollingGuestQueue()
    }

    /// Start polling guest for queued files
    private func startPollingGuestQueue() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkGuestQueue()
            }
        }
    }

    /// Check how many files are queued in the guest and fetch pending URLs
    private func checkGuestQueue() async {
        guard let client = ghostClient else { return }

        // Check for queued files
        do {
            let files = try await client.listFiles()
            queuedGuestFileCount = files.count
        } catch {
            // Silently fail - guest might not be connected
        }

        // Check for URLs to open on host
        do {
            let urls = try await client.fetchPendingURLs()
            for urlString in urls {
                if let url = URL(string: urlString) {
                    print("[FileTransfer] Opening URL from guest: \(urlString)")
                    NSWorkspace.shared.open(url)
                }
            }
        } catch {
            // Silently fail - guest might not be connected
        }
    }

    /// Queue of files pending transfer (with relative paths for folder structure)
    private var pendingFiles: [FileWithRelativePath] = []
    private var isProcessingQueue = false

    /// Send files to the guest VM
    /// - Parameter files: Files with their relative paths to send
    public func sendFiles(_ files: [FileWithRelativePath]) {
        print("[FileTransfer] sendFiles called with \(files.count) file(s)")
        guard ghostClient != nil else {
            print("[FileTransfer] ERROR: ghostClient is nil!")
            lastError = "Not connected to guest"
            return
        }

        // Add to queue
        pendingFiles.append(contentsOf: files)
        print("[FileTransfer] Queued \(files.count) file(s), total pending: \(pendingFiles.count)")

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

        print("[FileTransfer] Processing: \(file.relativePath) (\(pendingFiles.count) remaining)")
        sendFile(file.url, relativePath: file.relativePath, client: client) { [weak self] in
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
    ///   - client: The GhostClient to use for transfer
    ///   - completion: Callback when transfer completes
    private func sendFile(_ url: URL, relativePath: String, client: GhostClient, completion: (() -> Void)? = nil) {
        let displayName = relativePath

        // Get file size
        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attributes[.size] as? Int64) ?? 0
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
                let savedPath = try await client.sendFile(fileURL: url, relativePath: relativePath) { progress in
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

                let (data, fetchedFilename) = try await client.fetchFile(at: guestPath)

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

                updateTransferState(id: transferId, state: .completed(path: saveURL.path))

                // Reveal in Finder
                NSWorkspace.shared.activateFileViewerSelecting([saveURL])

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
        guard let client = ghostClient else {
            lastError = "Not connected to guest"
            return
        }

        Task {
            do {
                let files = try await listGuestFiles()
                print("[FileTransfer] Found \(files.count) file(s) queued on guest")

                for guestPath in files {
                    fetchFile(at: guestPath, showSavePanel: false)
                }

                // Clear the queue on the guest
                if !files.isEmpty {
                    try await client.clearFileQueue()
                    queuedGuestFileCount = 0
                    print("[FileTransfer] Cleared guest file queue")
                }
            } catch {
                lastError = "Failed to list guest files: \(error.localizedDescription)"
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
