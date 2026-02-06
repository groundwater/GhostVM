import Foundation
import GhostVMKit

/// Bridges the VM's network socket to vmnet with packet filtering in between.
///
/// Data flow: VM <-> [socketpair FD] <-> PacketFilter <-> VMNetInterface <-> Internet
///
/// For `.disableNetwork` policy, all frames from the VM are read and discarded (sink mode).
///
/// The socketpair is always present so the policy can be switched at runtime without
/// restarting the VM. Call `updatePolicy(_:)` to change the active policy.
@MainActor
final class NetworkFilterService {
    private var policy: NetworkAccessPolicy
    private let hostFD: Int32
    private var vmnetInterface: VMNetInterface?
    private var packetFilter: PacketFilter
    private var readSource: DispatchSourceRead?
    private var running = false

    init(policy: NetworkAccessPolicy, hostFD: Int32) {
        self.policy = policy
        self.hostFD = hostFD
        self.packetFilter = PacketFilter(policy: policy)
    }

    func start() {
        guard !running else { return }
        running = true

        NSLog("NetworkFilterService: Starting with policy '\(policy.rawValue)'")
        setupForwarding()
    }

    func stop() {
        guard running else { return }
        running = false

        teardownForwarding()
        close(hostFD)
        NSLog("NetworkFilterService: Stopped")
    }

    /// Switches to a new network policy at runtime without restarting the VM.
    func updatePolicy(_ newPolicy: NetworkAccessPolicy) {
        guard running else { return }

        NSLog("NetworkFilterService: Switching policy '\(policy.rawValue)' -> '\(newPolicy.rawValue)'")

        teardownForwarding()

        policy = newPolicy
        packetFilter.policy = newPolicy

        setupForwarding()
    }

    // MARK: - Private

    /// Starts vmnet (if needed) and the VM read source for the current policy.
    private func setupForwarding() {
        if policy == .disableNetwork {
            // Sink mode: just drain frames from VM so the socketpair buffer doesn't fill
            startVMReadSource(handler: { _ in })
            return
        }

        // Start vmnet interface for filtered modes
        let vmnet = VMNetInterface()
        self.vmnetInterface = vmnet

        do {
            let gatewayIP = try vmnet.start()
            packetFilter.vmnetGatewayIP = gatewayIP
            if let gw = gatewayIP {
                let a = (gw >> 24) & 0xFF, b = (gw >> 16) & 0xFF
                let c = (gw >> 8) & 0xFF, d = gw & 0xFF
                NSLog("NetworkFilterService: vmnet gateway \(a).\(b).\(c).\(d)")
            }
        } catch {
            NSLog("NetworkFilterService: Failed to start vmnet: \(error)")
            // Fall back to sink mode so we don't leak the read source
            startVMReadSource(handler: { _ in })
            return
        }

        // Network -> VM: filter then forward
        vmnet.onReceive = { [weak self] frame in
            guard let self = self else { return }
            if self.packetFilter.shouldAllow(frame: frame) {
                self.sendToVM(frame: frame)
            }
        }

        // VM -> Network: filter then forward
        startVMReadSource { [weak self] frame in
            guard let self = self else { return }
            if self.packetFilter.shouldAllow(frame: frame) {
                vmnet.send(frame: frame)
            }
        }

        NSLog("NetworkFilterService: Running with policy '\(policy.rawValue)'")
    }

    /// Cancels the read source and stops vmnet, but does NOT close hostFD.
    private func teardownForwarding() {
        readSource?.cancel()
        readSource = nil

        vmnetInterface?.stop()
        vmnetInterface = nil
    }

    /// Sets up a DispatchSource to read Ethernet frames from the VM side of the socketpair.
    private func startVMReadSource(handler: @escaping (Data) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: hostFD, queue: DispatchQueue(label: "ghostvm.netfilter.vm", qos: .userInteractive))

        source.setEventHandler { [weak self] in
            guard let self = self, self.running else { return }

            // SOCK_DGRAM preserves message boundaries — each recv gets one frame
            var buffer = [UInt8](repeating: 0, count: 65536)
            let bytesRead = recv(self.hostFD, &buffer, buffer.count, Int32(MSG_DONTWAIT))
            if bytesRead > 0 {
                let frame = Data(bytes: buffer, count: bytesRead)
                handler(frame)
            }
        }

        source.setCancelHandler { /* nothing to clean up */ }
        source.resume()
        self.readSource = source
    }

    /// Sends a frame to the VM via the socketpair.
    private nonisolated func sendToVM(frame: Data) {
        frame.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            _ = Darwin.send(hostFD, baseAddress, frame.count, Int32(MSG_DONTWAIT))
        }
    }

    deinit {
        if running {
            readSource?.cancel()
            vmnetInterface?.stop()
            close(hostFD)
        }
    }
}
