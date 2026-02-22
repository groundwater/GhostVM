import Foundation
import AppKit
import CryptoKit
import Combine
import GhostVMKit

/// Service for synchronizing clipboard between host and guest VM.
/// Event-driven: syncs on window focus/blur instead of polling.
@MainActor
public final class ClipboardSyncService: ObservableObject {
    /// Current sync mode
    @Published public var syncMode: ClipboardSyncMode = .disabled

    /// Last error encountered during sync
    @Published public private(set) var lastError: String?

    /// Connection status to the guest
    @Published public private(set) var isConnected: Bool = false

    private let hostPasteboard = NSPasteboard.general
    public private(set) var lastHostChangeCount: Int = 0
    private var lastGuestDataHash: Data?

    private var guestClient: (any GhostClientProtocol)?
    private let bundlePath: String

    /// Pasteboard types to check, in priority order (richest first)
    private static let typePriority: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        .string,
    ]

    /// Map NSPasteboard.PasteboardType to UTI strings
    private static func utiString(for type: NSPasteboard.PasteboardType) -> String {
        switch type {
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        case .string: return "public.utf8-plain-text"
        default: return type.rawValue
        }
    }

    /// Map UTI string back to NSPasteboard.PasteboardType
    private static func pasteboardType(for uti: String) -> NSPasteboard.PasteboardType {
        switch uti {
        case "public.png": return .png
        case "public.tiff": return .tiff
        case "public.utf8-plain-text": return .string
        default: return NSPasteboard.PasteboardType(uti)
        }
    }

    public init(bundlePath: String) {
        self.bundlePath = bundlePath
        self.lastHostChangeCount = hostPasteboard.changeCount
    }

    /// Configure the service with a GhostClient (no polling started)
    public func configure(client: any GhostClientProtocol) {
        self.guestClient = client
    }

    /// Stop and release the client reference
    public func stop() {
        isConnected = false
        guestClient = nil
    }

    /// Set sync mode
    public func setSyncMode(_ mode: ClipboardSyncMode) {
        syncMode = mode
    }

    // MARK: - Window Focus Events

    /// Called when the VM window becomes key (gains focus).
    /// Pushes host clipboard to guest and/or pulls guest clipboard to host.
    public func windowDidBecomeKey() {
        guard syncMode != .disabled else { return }
        guard let client = guestClient else { return }

        Task {
            // Push host clipboard to guest if it changed while away
            if syncMode.allowsHostToGuest {
                await pushHostToGuest(client: client)
            }
            // Pull guest clipboard to host
            if syncMode.allowsGuestToHost {
                await pullGuestToHost(client: client)
            }
        }
    }

    /// Called when the VM window resigns key (loses focus).
    /// Pulls guest clipboard so the user can paste on the host side.
    public func windowDidResignKey() {
        guard syncMode != .disabled else { return }
        guard let client = guestClient else { return }

        Task {
            if syncMode.allowsGuestToHost {
                await pullGuestToHost(client: client)
            }
        }
    }

    // MARK: - Private

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func pushHostToGuest(client: any GhostClientProtocol) async {
        let currentCount = hostPasteboard.changeCount
        guard currentCount != lastHostChangeCount else { return }

        lastHostChangeCount = currentCount

        // Find the richest available type
        guard let (data, type) = bestPasteboardItem() else { return }

        // Avoid echo: don't send if this is what we just received from guest
        let hash = Self.sha256(data)
        if hash == lastGuestDataHash { return }

        do {
            try await client.setClipboard(data: data, type: type)
            isConnected = true
            lastError = nil
        } catch {
            lastError = "Failed to send to guest: \(error.localizedDescription)"
            isConnected = false
        }
    }

    private func pullGuestToHost(client: any GhostClientProtocol) async {
        do {
            let response = try await client.getClipboard()
            isConnected = true
            lastError = nil

            guard let data = response.data else { return }

            let hash = Self.sha256(data)
            guard hash != lastGuestDataHash else { return }

            lastGuestDataHash = hash

            // Update host clipboard
            let uti = response.type ?? "public.utf8-plain-text"
            let pbType = Self.pasteboardType(for: uti)
            hostPasteboard.clearContents()
            hostPasteboard.setData(data, forType: pbType)
            lastHostChangeCount = hostPasteboard.changeCount

        } catch GhostClientError.noContent {
            isConnected = true
            lastError = nil
        } catch {
            lastError = "Failed to get from guest: \(error.localizedDescription)"
            isConnected = false
        }
    }

    /// Read the best available pasteboard item by type priority
    private func bestPasteboardItem() -> (data: Data, type: String)? {
        for pbType in Self.typePriority {
            if let data = hostPasteboard.data(forType: pbType) {
                return (data, Self.utiString(for: pbType))
            }
        }
        return nil
    }
}
