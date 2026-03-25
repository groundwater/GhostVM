import Foundation
import Combine
import GhostVMKit

/// A guest→host port mapping created by auto port map.
public struct AutoPortMapping: Hashable {
    public let guestPort: UInt16
    public let hostPort: UInt16
}

/// Automatically creates and removes port forwards based on guest-detected listening ports.
/// Auto-mapped ports are transient (not persisted) and tracked separately from manual forwards.
@MainActor
public final class AutoPortMapService: ObservableObject {

    /// Active auto-mapped forwards: guestPort → hostPort
    @Published public private(set) var autoMappedPorts: [UInt16: UInt16] = [:]
    @Published public private(set) var blockedPorts: Set<UInt16> = []
    @Published public private(set) var newlyForwardedPorts: [UInt16: UInt16] = [:]

    public var isEnabled: Bool { _isEnabled }

    /// Set of host ports currently used by auto-mapped forwards.
    public var autoMappedHostPorts: Set<UInt16> {
        Set(autoMappedPorts.values)
    }

    private var _isEnabled = false
    private var manualPorts: Set<UInt16> = []
    private var minimumPort: UInt16 = 1025
    private var excludedPorts: Set<UInt16> = []
    private static let maxRetries = 100

    /// Process name for each auto-mapped guest port.
    private(set) var processNames: [UInt16: String] = [:]

    private weak var portForwardService: PortForwardService?
    private var cancellable: AnyCancellable?

    public init() {}

    public func start(
        portForwardService: PortForwardService,
        eventStreamService: EventStreamService,
        manualForwards: [PortForwardConfig]
    ) {
        self.portForwardService = portForwardService
        self.manualPorts = Set(manualForwards.map { $0.hostPort })

        cancellable = eventStreamService.$detectedGuestPorts
            .receive(on: RunLoop.main)
            .sink { [weak self] guestPorts in
                self?.handlePortUpdate(guestPorts)
            }
    }

    public func stop() {
        cancellable?.cancel()
        cancellable = nil
        tearDownAutoMappedPorts()
        portForwardService = nil
    }

    public func setEnabled(_ enabled: Bool) {
        _isEnabled = enabled
        if !enabled {
            tearDownAutoMappedPorts()
            blockedPorts.removeAll()
            newlyForwardedPorts.removeAll()
            processNames.removeAll()
        }
    }

    public func updateManualPorts(_ ports: Set<UInt16>) {
        manualPorts = ports
    }

    /// Block a single guest port: un-forward it, add to blockedPorts, remove from newlyForwardedPorts.
    public func blockPort(_ guestPort: UInt16) {
        if let hostPort = autoMappedPorts.removeValue(forKey: guestPort) {
            portForwardService?.removeForward(hostPort: hostPort)
        }
        blockedPorts.insert(guestPort)
        newlyForwardedPorts.removeValue(forKey: guestPort)
        NSLog("AutoPortMap: Blocked guest port %u", guestPort)
    }

    /// User dismissed the notification without action — forwards stay active.
    public func acknowledgeNewlyForwarded() {
        newlyForwardedPorts.removeAll()
    }

    /// Remove a single port from the blocked set.
    public func unblockPort(_ port: UInt16) {
        blockedPorts.remove(port)
        NSLog("AutoPortMap: Unblocked port %u", port)
    }

    /// Clear all blocked ports.
    public func unblockAll() {
        blockedPorts.removeAll()
        NSLog("AutoPortMap: Unblocked all ports")
    }

    private func handlePortUpdate(_ guestPorts: [GuestPort]) {
        guard _isEnabled, let service = portForwardService else { return }

        // Update process name tracking for all reported ports
        for gp in guestPorts {
            let p = UInt16(gp.port)
            if !gp.process.isEmpty {
                processNames[p] = gp.process
            }
        }
        if !processNames.isEmpty {
            NSLog("AutoPortMap: processNames = %@", processNames.map { "\($0.key):\($0.value)" }.joined(separator: ", "))
        }

        let desired = Set(guestPorts.compactMap { gp -> UInt16? in
            let p = UInt16(gp.port)
            guard p >= minimumPort, !excludedPorts.contains(p), !manualPorts.contains(p) else { return nil }
            return p
        })

        // Remove stale auto-mapped ports (always runs silently)
        let staleGuests = Set(autoMappedPorts.keys).subtracting(desired)
        for guestPort in staleGuests {
            if let hostPort = autoMappedPorts.removeValue(forKey: guestPort) {
                service.removeForward(hostPort: hostPort)
                processNames.removeValue(forKey: guestPort)
                NSLog("AutoPortMap: Removed auto-mapped port %u (host %u)", guestPort, hostPort)
            }
        }

        // New ports: skip blocked and already-mapped, forward everything else
        let toAdd = desired
            .subtracting(Set(autoMappedPorts.keys))
            .subtracting(blockedPorts)

        let usedHostPorts = Set(autoMappedPorts.values)
            .union(manualPorts)
            .union(Set(service.activeForwards.map { $0.hostPort }))

        var justForwarded: [UInt16: UInt16] = [:]
        for guestPort in toAdd {
            if let hostPort = tryAddForward(service: service, guestPort: guestPort, usedHostPorts: usedHostPorts.union(Set(justForwarded.values))) {
                autoMappedPorts[guestPort] = hostPort
                justForwarded[guestPort] = hostPort
            }
        }

        // Replace (not accumulate) newlyForwardedPorts with this batch
        if !justForwarded.isEmpty {
            newlyForwardedPorts = justForwarded
        }
    }

    /// Try to forward guestPort, falling back to host port guestPort+1, +2, etc.
    /// Returns the host port that was successfully bound, or nil on failure.
    private func tryAddForward(service: PortForwardService, guestPort: UInt16, usedHostPorts: Set<UInt16>) -> UInt16? {
        for offset in 0..<Self.maxRetries {
            let candidate = guestPort &+ UInt16(offset)
            guard candidate >= minimumPort, !usedHostPorts.contains(candidate) else { continue }

            let config = PortForwardConfig(hostPort: candidate, guestPort: guestPort, enabled: true)
            do {
                try service.addForward(config)
                if candidate != guestPort {
                    NSLog("AutoPortMap: Added auto-mapped port %u on host port %u (fallback)", guestPort, candidate)
                } else {
                    NSLog("AutoPortMap: Added auto-mapped port %u", guestPort)
                }
                return candidate
            } catch {
                NSLog("AutoPortMap: Host port %u unavailable for guest %u, trying next", candidate, guestPort)
            }
        }
        NSLog("AutoPortMap: Failed to find available host port for guest %u", guestPort)
        return nil
    }

    private func tearDownAutoMappedPorts() {
        guard let service = portForwardService else {
            autoMappedPorts.removeAll()
            return
        }
        for (guestPort, hostPort) in autoMappedPorts {
            service.removeForward(hostPort: hostPort)
            NSLog("AutoPortMap: Removed auto-mapped port %u (host %u, disabled)", guestPort, hostPort)
        }
        autoMappedPorts.removeAll()
    }
}
