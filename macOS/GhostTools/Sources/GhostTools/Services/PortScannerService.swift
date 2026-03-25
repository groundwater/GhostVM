import Foundation

/// Periodically scans for listening TCP ports and pushes changes to the host
/// via EventPushServer. Only sends updates when the set of ports changes.
final class PortScannerService {
    static let shared = PortScannerService()

    private var timer: Timer?
    private var previousPorts: Set<Int> = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        print("[PortScannerService] Starting port scanner (2s interval)")

        // Fire immediately, then every 2 seconds
        scanAndPush()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanAndPush()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousPorts = []
    }

    private func scanAndPush() {
        let portInfos = PortScanner.shared.getListeningPortsWithProcess()
        let currentPorts = Set(portInfos.map { $0.port })
        guard currentPorts != previousPorts else { return }

        previousPorts = currentPorts
        let summary = portInfos.map { "\($0.process.isEmpty ? "?" : $0.process):\($0.port)" }
        print("[PortScannerService] Ports changed: \(summary)")
        EventPushServer.shared.pushEvent(.ports(portInfos))
    }
}
