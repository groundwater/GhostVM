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

            do {
                // IMPORTANT: Hold `connection` alive — dropping it closes the fd.
                let connection = try await client.connectRaw(port: port)
                let fd = connection.fileDescriptor

                // Read version line on a background queue
                let versionOK: Bool = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        var buffer = [UInt8](repeating: 0, count: 512)
                        let n = Darwin.read(fd, &buffer, buffer.count - 1)
                        continuation.resume(returning: n > 0)
                    }
                }

                if versionOK {
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
                            connection.close()
                            continuation.resume()
                        }
                    }
                } else {
                    connection.close()
                }
            } catch {
                // Connection failed - guest not ready
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
