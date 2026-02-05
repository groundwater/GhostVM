import Foundation
import Virtualization
import GhostVMKit
import NIOCore
import NIOPosix

/// The backend implementation for port forwarding
public enum PortForwardBackend {
    /// Darwin sockets with poll() - original implementation
    case darwin
    /// SwiftNIO with event-driven I/O and backpressure
    case nio
}

/// Manages all active port forwards for a VM.
///
/// This service creates and manages PortForwardListener instances based on
/// the VM's port forward configuration. Supports both Darwin (poll-based) and
/// NIO (event-driven) backends.
@MainActor
public final class PortForwardService: ObservableObject {
    private let virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue

    /// Darwin-based listeners (poll implementation)
    private var darwinListeners: [UInt16: PortForwardListener] = [:]

    /// NIO-based listeners (SwiftNIO implementation)
    private var nioListeners: [UInt16: NIOPortForwardListener] = [:]

    /// The EventLoopGroup for NIO operations (lazily initialized)
    private var eventLoopGroup: MultiThreadedEventLoopGroup?

    /// The preferred backend for new port forwards
    /// Darwin backend uses poll() which is simpler and more reliable for vsock
    public var preferredBackend: PortForwardBackend = .darwin

    @Published public private(set) var activeForwards: [PortForwardConfig] = []

    public init(vm: VZVirtualMachine, queue: DispatchQueue) {
        self.virtualMachine = vm
        self.vmQueue = queue
    }

    deinit {
        // Note: stop() should be called before deinit on MainActor
    }

    /// Get or create the EventLoopGroup for NIO operations
    private func getEventLoopGroup() -> MultiThreadedEventLoopGroup {
        if let group = eventLoopGroup {
            return group
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        eventLoopGroup = group
        return group
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

        // Stop Darwin listeners
        for (_, listener) in darwinListeners {
            listener.stop()
        }
        darwinListeners.removeAll()

        // Stop NIO listeners
        for (_, listener) in nioListeners {
            listener.stop()
        }
        nioListeners.removeAll()

        // Shutdown EventLoopGroup gracefully
        if let group = eventLoopGroup {
            do {
                try group.syncShutdownGracefully()
            } catch {
                print("[PortForwardService] Error shutting down EventLoopGroup: \(error)")
            }
            eventLoopGroup = nil
        }

        activeForwards.removeAll()
    }

    /// Add a new port forward
    public func addForward(_ config: PortForwardConfig) throws {
        guard config.enabled else { return }

        // Check if already listening on this host port
        if darwinListeners[config.hostPort] != nil || nioListeners[config.hostPort] != nil {
            print("[PortForwardService] Port \(config.hostPort) already in use")
            return
        }

        switch preferredBackend {
        case .darwin:
            try addDarwinForward(config)
        case .nio:
            try addNIOForward(config)
        }

        activeForwards.append(config)
        print("[PortForwardService] Added forward: localhost:\(config.hostPort) -> guest:\(config.guestPort) (backend: \(preferredBackend))")
    }

    /// Add a forward using the Darwin/poll backend
    private func addDarwinForward(_ config: PortForwardConfig) throws {
        let listener = PortForwardListener(
            hostPort: config.hostPort,
            guestPort: config.guestPort,
            vm: virtualMachine,
            queue: vmQueue
        )

        try listener.start()
        darwinListeners[config.hostPort] = listener
    }

    /// Add a forward using the SwiftNIO backend
    private func addNIOForward(_ config: PortForwardConfig) throws {
        let listener = NIOPortForwardListener(
            hostPort: config.hostPort,
            guestPort: config.guestPort,
            eventLoopGroup: getEventLoopGroup(),
            vm: virtualMachine,
            vmQueue: vmQueue
        )

        try listener.start()
        nioListeners[config.hostPort] = listener
    }

    /// Remove a port forward by host port
    public func removeForward(hostPort: UInt16) {
        var removed = false

        if let listener = darwinListeners.removeValue(forKey: hostPort) {
            listener.stop()
            removed = true
        }

        if let listener = nioListeners.removeValue(forKey: hostPort) {
            listener.stop()
            removed = true
        }

        if removed {
            activeForwards.removeAll { $0.hostPort == hostPort }
            print("[PortForwardService] Removed forward on port \(hostPort)")
        }
    }

    /// Update port forwards to match new configuration
    public func updateForwards(_ newForwards: [PortForwardConfig]) {
        let enabledNew = newForwards.filter { $0.enabled }
        let currentPorts = Set(darwinListeners.keys).union(Set(nioListeners.keys))
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
