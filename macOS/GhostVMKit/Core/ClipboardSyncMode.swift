import Foundation

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
