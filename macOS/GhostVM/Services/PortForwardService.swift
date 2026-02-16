import Foundation
import Virtualization
import GhostVMKit

/// Manages all active port forwards for a VM.
///
/// This service creates and manages PortForwardListener instances based on
/// the VM's port forward configuration.
@MainActor
public final class PortForwardService: ObservableObject {
    private let virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue

    private var listeners: [UInt16: PortForwardListener] = [:]

    @Published public private(set) var activeForwards: [PortForwardConfig] = []

    public init(vm: VZVirtualMachine, queue: DispatchQueue) {
        self.virtualMachine = vm
        self.vmQueue = queue
    }

    deinit {
        // Note: stop() should be called before deinit on MainActor
    }

    /// Start all enabled port forwards from the configuration
    public func start(forwards: [PortForwardConfig]) {
        print("[PortForwardService] Starting \(forwards.count) port forward(s)")

        for config in forwards {
            guard config.enabled else { continue }

            do {
                try addForward(config)
            } catch {
                print("[PortForwardService] Failed to start forward \(config.hostPort) -> \(config.guestPort): \(error)")
            }
        }
    }

    /// Stop all port forwards
    public func stop() {
        print("[PortForwardService] Stopping all port forwards")

        for (_, listener) in listeners {
            listener.stop()
        }
        listeners.removeAll()

        activeForwards.removeAll()
    }

    /// Add a new port forward
    public func addForward(_ config: PortForwardConfig) throws {
        guard config.enabled else { return }

        // Check if already listening on this host port
        if listeners[config.hostPort] != nil {
            print("[PortForwardService] Port \(config.hostPort) already in use")
            return
        }

        let listener = PortForwardListener(
            hostPort: config.hostPort,
            guestPort: config.guestPort,
            vm: virtualMachine,
            queue: vmQueue
        )

        try listener.start()
        listeners[config.hostPort] = listener

        activeForwards.append(config)
        print("[PortForwardService] Added forward: localhost:\(config.hostPort) -> guest:\(config.guestPort)")
    }

    /// Remove a port forward by host port
    public func removeForward(hostPort: UInt16) {
        if let listener = listeners.removeValue(forKey: hostPort) {
            listener.stop()
            activeForwards.removeAll { $0.hostPort == hostPort }
            print("[PortForwardService] Removed forward on port \(hostPort)")
        }
    }

    /// Update port forwards to match new configuration
    public func updateForwards(_ newForwards: [PortForwardConfig]) {
        let enabledNew = newForwards.filter { $0.enabled }
        let currentPorts = Set(listeners.keys)
        let newPorts = Set(enabledNew.map { $0.hostPort })

        // Remove forwards that are no longer in config
        for port in currentPorts.subtracting(newPorts) {
            removeForward(hostPort: port)
        }

        // Add new forwards
        for config in enabledNew where !currentPorts.contains(config.hostPort) {
            do {
                try addForward(config)
            } catch {
                print("[PortForwardService] Failed to add forward \(config.hostPort): \(error)")
            }
        }
    }
}
