import Foundation
import AppKit
import Combine
import Virtualization

/// Persistent event stream from guest via vsock port 5003.
/// Reads NDJSON lines and dispatches: file queue updates, URL opens, log messages.
@MainActor
public final class EventStreamService: ObservableObject {
    @Published public private(set) var queuedGuestFiles: [String] = []

    public var queuedGuestFileCount: Int { queuedGuestFiles.count }

    private var client: GhostClient?
    private var task: Task<Void, Never>?
    private let port: UInt32 = 5003

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
        queuedGuestFiles = []
    }

    private func reconnectLoop() async {
        while !Task.isCancelled {
            guard let client = client else { break }

            do {
                // IMPORTANT: Hold `connection` alive — dropping it closes the fd.
                let connection = try await client.connectRaw(port: port)
                let fd = connection.fileDescriptor

                // Read NDJSON lines on background queue.
                // `connection` is captured to keep it alive.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        self?.readLines(fd: fd)
                        connection.close()
                        continuation.resume()
                    }
                }
            } catch {
                // Connection failed - guest not ready
            }

            // Wait before retrying
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            } catch {
                break
            }
        }
    }

    /// Read NDJSON lines from the fd until EOF. Dispatches events to MainActor.
    private nonisolated func readLines(fd: Int32) {
        let bufferSize = 4096
        var leftover = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            let n = Darwin.read(fd, &buffer, bufferSize)
            if n <= 0 { break }

            leftover.append(contentsOf: buffer[0..<n])

            // Process complete lines
            while let newlineIndex = leftover.firstIndex(of: 0x0A) { // \n
                let lineData = leftover[leftover.startIndex..<newlineIndex]
                leftover = Data(leftover[(newlineIndex + 1)...])

                guard !lineData.isEmpty,
                      let line = String(data: Data(lineData), encoding: .utf8) else { continue }

                dispatchEvent(line)
            }
        }
    }

    private nonisolated func dispatchEvent(_ jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "files":
            if let files = obj["files"] as? [String] {
                Task { @MainActor [weak self] in
                    self?.queuedGuestFiles = files
                }
            }
        case "urls":
            if let urls = obj["urls"] as? [String] {
                Task { @MainActor in
                    for urlString in urls {
                        if let url = URL(string: urlString) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        case "log":
            if let message = obj["message"] as? String {
                print("[Guest] \(message)")
            }
        default:
            break
        }
    }
}
