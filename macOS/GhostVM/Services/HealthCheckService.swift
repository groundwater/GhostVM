import Foundation
import Combine
import Virtualization

/// Persistent health check via vsock port 5002.
/// Connects once, reads version line, then blocks on read until EOF.
/// Connection close = unhealthy. Reconnects after a delay.
@MainActor
public final class HealthCheckService: ObservableObject {
    @Published public private(set) var isConnected: Bool = false

    private var client: GhostClient?
    private var task: Task<Void, Never>?
    private let port: UInt32 = 5002

    public init() {}

    public func start(client: GhostClient) {
        self.client = client
        task?.cancel()
        task = Task { [weak self] in
            await self?.reconnectLoop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        client = nil
        isConnected = false
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
                    isConnected = true

                    // Block on read until EOF (guest disconnects or dies).
                    // `connection` is captured by the closure to keep it alive.
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global(qos: .utility).async {
                            var buf = [UInt8](repeating: 0, count: 1)
                            while true {
                                let n = Darwin.read(fd, &buf, 1)
                                if n <= 0 { break }
                            }
                            NSLog("HealthCheck: connection lost (EOF)")
                            connection.close()
                            continuation.resume()
                        }
                    }
                } else {
                    NSLog("HealthCheck: version read failed, closing")
                    connection.close()
                }
            } catch {
                NSLog("HealthCheck: connection failed: %@", error.localizedDescription)
            }

            isConnected = false

            // Wait before retrying
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            } catch {
                break
            }
        }
    }
}
