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

    private var ghostClient: GhostClient?
    private let maxConcurrentTransfers = 3
    private var activeTransferCount = 0

    public init() {}

    /// Configure the service with a GhostClient
    public func configure(client: GhostClient) {
        self.ghostClient = client
    }

    /// Send files to the guest VM
    /// - Parameter urls: File URLs to send
    public func sendFiles(_ urls: [URL]) {
        guard let client = ghostClient else {
            lastError = "Not connected to guest"
            return
        }

        for url in urls {
            sendFile(url, client: client)
        }
    }

    /// Send a single file to the guest VM
    private func sendFile(_ url: URL, client: GhostClient) {
        let filename = url.lastPathComponent

        // Get file size
        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = (attributes[.size] as? Int64) ?? 0
        } catch {
            lastError = "Cannot read file: \(error.localizedDescription)"
            return
        }

        var transfer = FileTransfer(filename: filename, size: fileSize, direction: .hostToGuest)
        transfer.state = .preparing
        transfers.append(transfer)
        isTransferring = true

        let transferId = transfer.id

        Task {
            do {
                // Read file data
                let data = try Data(contentsOf: url)

                updateTransferState(id: transferId, state: .transferring(progress: 0))

                // Send to guest
                let savedPath = try await client.sendFile(data: data, filename: filename) { [weak self] progress in
                    Task { @MainActor in
                        self?.updateTransferState(id: transferId, state: .transferring(progress: progress))
                    }
                }

                updateTransferState(id: transferId, state: .completed(path: savedPath))

            } catch {
                updateTransferState(id: transferId, state: .failed(error: error.localizedDescription))
                lastError = "Transfer failed: \(error.localizedDescription)"
            }

            updateIsTransferring()
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
        }
    }

    private func updateIsTransferring() {
        isTransferring = transfers.contains { $0.state.isActive }
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
