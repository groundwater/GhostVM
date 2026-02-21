import Foundation

public enum GuestToolsStatus: Equatable {
    case connecting
    case connected
    case notFound
}

public enum GhostToolsInstallState: Equatable {
    case notInstalled
    case installedConfirmed

    public mutating func record(healthStatus: GuestToolsStatus) {
        guard self == .notInstalled, healthStatus == .connected else { return }
        self = .installedConfirmed
    }
}

public enum GhostToolsToolbarPresentation: Equatable {
    case installCallToAction
    case liveStatus(GuestToolsStatus)
}

public struct GhostToolsToolbarPolicy {
    public static func presentation(
        installState: GhostToolsInstallState,
        healthStatus: GuestToolsStatus
    ) -> GhostToolsToolbarPresentation {
        switch installState {
        case .notInstalled:
            return .installCallToAction
        case .installedConfirmed:
            return .liveStatus(healthStatus)
        }
    }
}
