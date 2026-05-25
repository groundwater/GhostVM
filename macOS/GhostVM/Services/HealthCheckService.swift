import Foundation
import Combine
import Virtualization
import GhostVMKit

/// Periodic health check via the unified HTTP server on vsock port 5000.
/// Polls `/health` and treats success as healthy.
@MainActor
public final class HealthCheckService: ObservableObject {
    @Published public private(set) var status: GuestToolsStatus = .connecting

    public var isConnected: Bool { status == .connected }

    private var client: GhostClient?
    private var task: Task<Void, Never>?
    private var notFoundDeadline: Date?
    private var deadlineTask: Task<Void, Never>?

    public init() {}

    public func start(client: GhostClient) {
        self.client = client
        status = .connecting
        startNotFoundDeadline()
        task?.cancel()
        task = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        client = nil
        notFoundDeadline = nil
        status = .connecting
    }

    /// Fire a timer that flips status to .notFound after 2 minutes,
    /// independent of how long connectRaw blocks.
    private func startNotFoundDeadline() {
        deadlineTask?.cancel()
        notFoundDeadline = Date().addingTimeInterval(120)
        deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000) // 2 min
            } catch { return }
            guard let self = self, self.status != .connected else { return }
            self.status = .notFound
            NSLog("HealthCheck: deadline reached — status set to notFound")
        }
    }

    private func reconnectLoop() async {
        while !Task.isCancelled {
            guard let client = client else { break }

            NSLog("HealthCheck: polling unified HTTP health endpoint...")

            let isHealthy = await client.checkHealth()
            if isHealthy {
                NSLog("HealthCheck: CONNECTED")
                deadlineTask?.cancel()
                deadlineTask = nil
                notFoundDeadline = nil
                status = .connected
            } else {
                NSLog("HealthCheck: request failed")
                if status == .connected {
                    status = .connecting
                    startNotFoundDeadline()
                }
            }

            // Update status based on deadline (if deadline task already fired)
            if let deadline = notFoundDeadline, Date() >= deadline {
                status = .notFound
            } else if status != .connected {
                status = .connecting
            }

            // Wait before retrying
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            } catch {
                break
            }
        }
    }
}
