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
    private var lastHostChangeCount: Int = 0
    private var lastGuestContent: String?

    private var guestClient: GhostClient?
    private let bundlePath: String

    public init(bundlePath: String) {
        self.bundlePath = bundlePath
        self.lastHostChangeCount = hostPasteboard.changeCount
    }

    /// Configure the service with a GhostClient (no polling started)
    public func configure(client: GhostClient) {
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

    private func pushHostToGuest(client: GhostClient) async {
        let currentCount = hostPasteboard.changeCount
        guard currentCount != lastHostChangeCount else { return }

        lastHostChangeCount = currentCount

        guard let content = hostPasteboard.string(forType: .string) else { return }

        // Avoid echo: don't send if this is what we just received from guest
        if content == lastGuestContent { return }

        do {
            try await client.setClipboard(content: content)
            isConnected = true
            lastError = nil
        } catch {
            lastError = "Failed to send to guest: \(error.localizedDescription)"
            isConnected = false
        }
    }

    private func pullGuestToHost(client: GhostClient) async {
        do {
            let response = try await client.getClipboard()
            isConnected = true
            lastError = nil

            guard let content = response.content else { return }
            guard content != lastGuestContent else { return }

            lastGuestContent = content

            // Update host clipboard
            hostPasteboard.clearContents()
            hostPasteboard.setString(content, forType: .string)
            lastHostChangeCount = hostPasteboard.changeCount

        } catch GhostClientError.noContent {
            isConnected = true
            lastError = nil
        } catch {
            lastError = "Failed to get from guest: \(error.localizedDescription)"
            isConnected = false
        }
    }
}
