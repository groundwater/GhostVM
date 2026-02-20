import Foundation
import Virtualization
import GhostVMKit

public struct PortForwardRuntimeError: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case connectToGuest
        case handshakeWrite
        case handshakeRead
        case handshakeProtocol
        case bridge
    }

    public let hostPort: UInt16
    public let guestPort: UInt16
    public let phase: Phase
    public let message: String
    public let timestamp: Date

    public init(hostPort: UInt16, guestPort: UInt16, phase: Phase, message: String, timestamp: Date = Date()) {
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.phase = phase
        self.message = message
        self.timestamp = timestamp
    }
}

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
    @Published public private(set) var lastRuntimeError: PortForwardRuntimeError?

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
                recordRuntimeError(
                    PortForwardRuntimeError(
                        hostPort: config.hostPort,
                        guestPort: config.guestPort,
                        phase: .connectToGuest,
                        message: error.localizedDescription
                    )
                )
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
        lastRuntimeError = nil
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
            queue: vmQueue,
            onOperationalError: { [weak self] runtimeError in
                Task { @MainActor in
                    self?.recordRuntimeError(runtimeError)
                }
            }
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
                recordRuntimeError(
                    PortForwardRuntimeError(
                        hostPort: config.hostPort,
                        guestPort: config.guestPort,
                        phase: .connectToGuest,
                        message: error.localizedDescription
                    )
                )
            }
        }
    }

    public func clearRuntimeError() {
        lastRuntimeError = nil
    }

    private func recordRuntimeError(_ runtimeError: PortForwardRuntimeError) {
        lastRuntimeError = runtimeError
    }
}
