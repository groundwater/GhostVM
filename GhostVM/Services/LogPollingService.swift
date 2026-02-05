import Foundation

/// Service that polls guest for logs and prints them to host console
final class LogPollingService: @unchecked Sendable {
    private let client: GhostClient
    private let pollInterval: TimeInterval
    private var isRunning = false
    private let lock = NSLock()

    init(client: GhostClient, pollInterval: TimeInterval = 0.5) {
        self.client = client
        self.pollInterval = pollInterval
    }

    func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        print("[LogPolling] Started")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pollLoop()
        }
    }

    func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()
        print("[LogPolling] Stopped")
    }

    private func pollLoop() {
        while true {
            lock.lock()
            let running = isRunning
            lock.unlock()

            guard running else { break }

            Task {
                do {
                    let logs = try await client.fetchLogs()
                    for line in logs {
                        print("[Guest] \(line)")
                    }
                } catch {
                    // Silently ignore errors - guest might not be ready
                }
            }

            Thread.sleep(forTimeInterval: pollInterval)
        }
    }
}
