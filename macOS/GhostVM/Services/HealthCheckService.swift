import Foundation
import Combine
import Virtualization

public enum GuestToolsStatus: Equatable {
    case connecting
    case connected
    case notFound
}

/// Persistent health check via vsock port 5002.
/// Connects once, reads version line, then blocks on read until EOF.
/// Connection close = unhealthy. Reconnects after a delay.
@MainActor
public final class HealthCheckService: ObservableObject {
    @Published public private(set) var status: GuestToolsStatus = .connecting

    public var isConnected: Bool { status == .connected }

    private var client: GhostClient?
    private var task: Task<Void, Never>?
    private let port: UInt32 = 5002
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

            NSLog("HealthCheck: connecting to port %u...", port)

            do {
                // IMPORTANT: Hold `connection` alive — dropping it closes the fd.
                let connection = try await client.connectRaw(port: port)
                let fd = connection.fileDescriptor

                NSLog("HealthCheck: connected, reading version (fd=%d)...", fd)

                // Read version line on a background queue
                let versionOK: Bool = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        var buffer = [UInt8](repeating: 0, count: 512)
                        let n = Darwin.read(fd, &buffer, buffer.count - 1)
                        NSLog("HealthCheck: version read n=%d", n)
                        continuation.resume(returning: n > 0)
                    }
                }

                if versionOK {
                    NSLog("HealthCheck: CONNECTED")
                    deadlineTask?.cancel()
                    deadlineTask = nil
                    notFoundDeadline = nil
                    status = .connected

                    // Block on read until EOF (guest disconnects or dies).
                    // `connection` is captured by the closure to keep it alive.
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .utility).async {
                            var buf = [UInt8](repeating: 0, count: 1)
                            while true {
                                var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                                let ret = poll(&pfd, 1, 5000) // 5-second timeout
                                if ret > 0 {
                                    if pfd.revents & Int16(POLLHUP | POLLERR) != 0 {
                                        NSLog("HealthCheck: connection hangup/error detected via poll")
                                        break
                                    }
                                    let n = Darwin.read(fd, &buf, 1)
                                    if n <= 0 { break }
                                } else if ret < 0 {
                                    break // poll error
                                }
                                // ret == 0: timeout, loop back and poll again
                            }
                            NSLog("HealthCheck: connection lost (EOF)")
                            connection.close()
                            continuation.resume()
                        }
                    }

                    // Connection lost — restart deadline
                    status = .connecting
                    startNotFoundDeadline()
                } else {
                    NSLog("HealthCheck: version read failed, closing")
                    connection.close()
                }
            } catch {
                NSLog("HealthCheck: connection failed: %@", error.localizedDescription)
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
