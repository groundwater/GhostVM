import Foundation
import AppKit
import Combine

/// Information about a forwarded port
public struct ForwardedPort: Identifiable, Equatable {
    public let id: UInt16
    public let port: UInt16
    public let process: String
    public var isActive: Bool

    public init(port: UInt16, process: String, isActive: Bool = false) {
        self.id = port
        self.port = port
        self.process = process
        self.isActive = isActive
    }
}

/// Manages the lifecycle of port forwarding subprocesses
/// Polls the guest for open ports and spawns/respawns vmctl forward processes
@MainActor
public final class PortLifecycleManager: ObservableObject {
    /// Currently active forwarders (port -> Process)
    @Published private(set) var activeForwards: [UInt16: Process] = [:]

    /// Ports currently open in the guest
    @Published private(set) var guestOpenPorts: [ForwardedPort] = []

    /// Whether auto-forwarding is enabled
    @Published var autoForwardEnabled: Bool = true

    private let bundlePath: String
    private let ghostClient: GhostClient
    private let vmctlPath: String

    private var pollTask: Task<Void, Never>?
    private let pollInterval: TimeInterval = 2.0

    /// Initialize the manager
    /// - Parameters:
    ///   - bundlePath: Path to the VM bundle
    ///   - client: GhostClient for communicating with guest
    public init(bundlePath: String, client: GhostClient) {
        self.bundlePath = bundlePath
        self.ghostClient = client

        // Find vmctl in the app bundle
        if let vmctlURL = Bundle.main.url(forAuxiliaryExecutable: "vmctl") {
            self.vmctlPath = vmctlURL.path
        } else {
            // Fallback for development
            self.vmctlPath = "/usr/local/bin/vmctl"
        }
    }

    /// Start the port lifecycle manager
    public func start() {
        print("[PortLifecycle] Starting with bundle: \(bundlePath)")
        print("[PortLifecycle] vmctl path: \(vmctlPath)")

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Stop the port lifecycle manager
    public func stop() {
        print("[PortLifecycle] Stopping")
        pollTask?.cancel()
        pollTask = nil
        killAllForwarders()
    }

    /// Manually request forwarding for a specific port
    public func requestForward(port: UInt16) {
        if activeForwards[port] == nil {
            spawnForwarder(port: port)
        }
    }

    // MARK: - Private

    private func pollLoop() async {
        while !Task.isCancelled {
            await pollGuestPorts()
            await processForwardRequests()
            await checkForwarderHealth()

            if autoForwardEnabled {
                await reconcileForwarders()
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    /// Poll guest for currently listening ports
    private func pollGuestPorts() async {
        do {
            let ports = try await ghostClient.getListeningPorts()
            guestOpenPorts = ports.map { ForwardedPort(port: $0.port, process: $0.process, isActive: activeForwards[$0.port] != nil) }
        } catch {
            // Guest might not be ready yet - ignore errors
        }
    }

    /// Check for explicit port forward requests from guest URL handler
    private func processForwardRequests() async {
        do {
            let requestedPorts = try await ghostClient.getPortForwardRequests()
            for port in requestedPorts {
                if activeForwards[port] == nil {
                    print("[PortLifecycle] Processing forward request for port \(port)")
                    spawnForwarder(port: port)
                }
            }
        } catch {
            // Guest might not be ready yet - ignore errors
        }
    }

    /// Check health of running forwarders
    private func checkForwarderHealth() async {
        var deadPorts: [UInt16] = []

        for (port, process) in activeForwards {
            if !process.isRunning {
                print("[PortLifecycle] Forwarder for port \(port) died")
                deadPorts.append(port)
            }
        }

        for port in deadPorts {
            activeForwards.removeValue(forKey: port)
        }
    }

    /// Reconcile forwarders with guest open ports
    private func reconcileForwarders() async {
        let guestPorts = Set(guestOpenPorts.map { $0.port })

        // Spawn forwarders for ports that are open in guest but not forwarded
        for port in guestPorts {
            if activeForwards[port] == nil {
                // Check if we can bind to this port on host
                if isPortAvailable(port) {
                    print("[PortLifecycle] Auto-spawning forwarder for port \(port)")
                    spawnForwarder(port: port)
                }
            }
        }

        // Kill forwarders for ports that are no longer open in guest
        var portsToKill: [UInt16] = []
        for port in activeForwards.keys {
            if !guestPorts.contains(port) {
                print("[PortLifecycle] Killing forwarder for closed port \(port)")
                portsToKill.append(port)
            }
        }

        for port in portsToKill {
            killForwarder(port: port)
        }

        // Update active status in guestOpenPorts
        guestOpenPorts = guestOpenPorts.map { portInfo in
            var updated = portInfo
            updated.isActive = activeForwards[portInfo.port] != nil
            return updated
        }
    }

    /// Spawn a forwarder subprocess for a port
    private func spawnForwarder(port: UInt16) {
        guard activeForwards[port] == nil else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: vmctlPath)
        process.arguments = ["forward", bundlePath, String(port)]

        // Capture output for debugging
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            activeForwards[port] = process
            print("[PortLifecycle] Spawned forwarder for port \(port), PID: \(process.processIdentifier)")

            // Monitor output in background
            Task.detached {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    print("[PortLifecycle] Forwarder \(port) output: \(output.prefix(500))")
                }
            }
        } catch {
            print("[PortLifecycle] Failed to spawn forwarder for port \(port): \(error)")
        }
    }

    /// Kill a forwarder subprocess
    private func killForwarder(port: UInt16) {
        guard let process = activeForwards[port] else {
            return
        }

        if process.isRunning {
            process.terminate()
        }
        activeForwards.removeValue(forKey: port)
    }

    /// Kill all forwarders
    private func killAllForwarders() {
        for (port, process) in activeForwards {
            if process.isRunning {
                print("[PortLifecycle] Terminating forwarder for port \(port)")
                process.terminate()
            }
        }
        activeForwards.removeAll()
    }

    /// Check if a port is available on the host
    private func isPortAvailable(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var optval: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

}
