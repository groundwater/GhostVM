import Foundation
import AppKit
import Combine

/// Clipboard synchronization modes between host and guest
public enum ClipboardSyncMode: String, CaseIterable, Codable, Identifiable {
    case bidirectional
    case hostToGuest
    case guestToHost
    case disabled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bidirectional: return "Bidirectional"
        case .hostToGuest: return "Host to Guest"
        case .guestToHost: return "Guest to Host"
        case .disabled: return "Disabled"
        }
    }

    public var description: String {
        switch self {
        case .bidirectional: return "Full sync both directions"
        case .hostToGuest: return "Can paste into VM, cannot copy out"
        case .guestToHost: return "Can copy out of VM, cannot paste in"
        case .disabled: return "No clipboard access"
        }
    }

    /// Whether this mode allows sending host clipboard to guest
    public var allowsHostToGuest: Bool {
        switch self {
        case .bidirectional, .hostToGuest:
            return true
        case .guestToHost, .disabled:
            return false
        }
    }

    /// Whether this mode allows receiving guest clipboard on host
    public var allowsGuestToHost: Bool {
        switch self {
        case .bidirectional, .guestToHost:
            return true
        case .hostToGuest, .disabled:
            return false
        }
    }
}

/// Service for synchronizing clipboard between host and guest VM
@MainActor
public final class ClipboardSyncService: ObservableObject {
    /// Current sync mode
    @Published public var syncMode: ClipboardSyncMode = .disabled

    /// Whether the service is actively syncing
    @Published public private(set) var isActive: Bool = false

    /// Last error encountered during sync
    @Published public private(set) var lastError: String?

    /// Connection status to the guest
    @Published public private(set) var isConnected: Bool = false

    private let hostPasteboard = NSPasteboard.general
    private var lastHostChangeCount: Int = 0
    private var lastGuestChangeCount: Int = 0
    private var lastGuestContent: String?

    private var syncTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 0.5 // 500ms

    private var guestClient: GhostClient?
    private let bundlePath: String

    public init(bundlePath: String) {
        self.bundlePath = bundlePath
        self.lastHostChangeCount = hostPasteboard.changeCount
    }

    /// Start clipboard synchronization
    public func start(client: GhostClient) {
        guard syncMode != .disabled else {
            stop()
            return
        }

        self.guestClient = client
        isActive = true
        lastError = nil

        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.runSyncLoop()
        }
    }

    /// Stop clipboard synchronization
    public func stop() {
        syncTask?.cancel()
        syncTask = nil
        isActive = false
        isConnected = false
        guestClient = nil
    }

    /// Set sync mode and restart if active
    public func setSyncMode(_ mode: ClipboardSyncMode) {
        let wasActive = isActive
        let client = guestClient

        syncMode = mode

        if mode == .disabled {
            stop()
        } else if wasActive, let client = client {
            start(client: client)
        }
    }

    // MARK: - Private

    private func runSyncLoop() async {
        while !Task.isCancelled {
            await syncOnce()

            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    private func syncOnce() async {
        guard let client = guestClient, syncMode != .disabled else {
            return
        }

        // Check host clipboard for changes
        if syncMode.allowsHostToGuest {
            await syncHostToGuest(client: client)
        }

        // Poll guest clipboard for changes
        if syncMode.allowsGuestToHost {
            await syncGuestToHost(client: client)
        }
    }

    private func syncHostToGuest(client: GhostClient) async {
        let currentCount = hostPasteboard.changeCount
        guard currentCount != lastHostChangeCount else {
            return
        }

        print("[ClipboardSync] Host clipboard changed (count: \(currentCount))")
        lastHostChangeCount = currentCount

        guard let content = hostPasteboard.string(forType: .string) else {
            print("[ClipboardSync] No string content on host clipboard")
            return
        }

        // Avoid echo: don't send if this is what we just received from guest
        if content == lastGuestContent {
            print("[ClipboardSync] Skipping send - content matches last guest content (echo prevention)")
            return
        }

        print("[ClipboardSync] Sending to guest: \(content.prefix(50))...")
        do {
            try await client.setClipboard(content: content)
            print("[ClipboardSync] Successfully sent to guest")
            isConnected = true
            lastError = nil
        } catch {
            print("[ClipboardSync] Failed to send to guest: \(error)")
            lastError = "Failed to send to guest: \(error.localizedDescription)"
            isConnected = false
        }
    }

    private func syncGuestToHost(client: GhostClient) async {
        do {
            let response = try await client.getClipboard()
            isConnected = true
            lastError = nil

            // Check if guest clipboard changed
            guard let content = response.content,
                  content != lastGuestContent else {
                return
            }

            print("[ClipboardSync] Guest clipboard changed: \(content.prefix(50))...")
            lastGuestContent = content

            // Update host clipboard
            hostPasteboard.clearContents()
            hostPasteboard.setString(content, forType: .string)
            lastHostChangeCount = hostPasteboard.changeCount
            print("[ClipboardSync] Updated host clipboard")

        } catch GhostClientError.noContent {
            // No clipboard content on guest - this is normal
            isConnected = true
            lastError = nil
        } catch {
            print("[ClipboardSync] Failed to get from guest: \(error)")
            lastError = "Failed to get from guest: \(error.localizedDescription)"
            isConnected = false
        }
    }

    deinit {
        syncTask?.cancel()
    }
}
