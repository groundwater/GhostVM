import Foundation

/// Controls what network traffic a VM is allowed to send/receive.
public enum NetworkAccessPolicy: String, Codable, CaseIterable {
    case fullAccess
    case internetOnly
    case disableNetwork

    public var displayName: String {
        switch self {
        case .fullAccess: return "Full Access"
        case .internetOnly: return "Internet Only"
        case .disableNetwork: return "Disable Network"
        }
    }

    /// Whether this policy requires packet filtering.
    /// Always true — we always use a socketpair so policy can be changed at runtime.
    public var requiresFiltering: Bool {
        return true
    }

    /// Whether this policy needs a vmnet interface for external connectivity.
    public var requiresVmnet: Bool {
        switch self {
        case .fullAccess, .internetOnly: return true
        case .disableNetwork: return false
        }
    }
}
