import Foundation
import Network
import Virtualization
import GhostVMKit

/// Monitors the host network path and cycles the bridged network attachment
/// when the underlying interface changes (e.g. Wi-Fi network switch).
///
/// When the path becomes unsatisfied the attachment is set to nil (link-down).
/// When the path becomes satisfied a fresh VZBridgedNetworkDeviceAttachment is
/// assigned (link-up), causing the guest to re-run DHCP automatically.
@MainActor
public final class BridgeMonitorService {
    private let virtualMachine: VZVirtualMachine
    private let vmQueue: DispatchQueue
    private let interfaceIdentifier: String

    private var monitor: NWPathMonitor?
    private var monitorQueue: DispatchQueue?
    private var wasUnsatisfied = false

    public init(vm: VZVirtualMachine, queue: DispatchQueue, interfaceIdentifier: String) {
        self.virtualMachine = vm
        self.vmQueue = queue
        self.interfaceIdentifier = interfaceIdentifier
    }

    public func start() {
        let queue = DispatchQueue(label: "org.ghostvm.bridge-monitor")
        self.monitorQueue = queue

        let monitor = NWPathMonitor()
        self.monitor = monitor

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
        print("[BridgeMonitorService] Monitoring host network for bridge interface '\(interfaceIdentifier)'")
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
        monitorQueue = nil
        print("[BridgeMonitorService] Stopped")
    }

    private func handlePathUpdate(_ path: NWPath) {
        switch path.status {
        case .satisfied:
            if wasUnsatisfied {
                wasUnsatisfied = false
                reassignAttachment()
            }
        case .unsatisfied, .requiresConnection:
            if !wasUnsatisfied {
                wasUnsatisfied = true
                clearAttachment()
            }
        @unknown default:
            break
        }
    }

    /// Set the network attachment to nil so the guest sees link-down.
    private func clearAttachment() {
        guard let device = virtualMachine.networkDevices.first else {
            print("[BridgeMonitorService] No network device found on VM")
            return
        }
        vmQueue.async {
            device.attachment = nil
            print("[BridgeMonitorService] Cleared attachment (link-down)")
        }
    }

    /// Create a fresh bridged attachment so the guest sees link-up and re-runs DHCP.
    private func reassignAttachment() {
        guard let device = virtualMachine.networkDevices.first else {
            print("[BridgeMonitorService] No network device found on VM")
            return
        }
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        guard let interface = interfaces.first(where: { $0.identifier == interfaceIdentifier }) else {
            print("[BridgeMonitorService] Bridge interface '\(interfaceIdentifier)' no longer available")
            return
        }
        let attachment = VZBridgedNetworkDeviceAttachment(interface: interface)
        vmQueue.async {
            device.attachment = attachment
            print("[BridgeMonitorService] Reassigned bridged attachment (link-up) on '\(interface.identifier)'")
        }
    }
}
