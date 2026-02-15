import Foundation
import AppKit
import Combine
import Virtualization
import GhostVMKit

/// A guest port with optional process name.
public struct GuestPort: Equatable {
    public let port: Int
    public let process: String
}

/// Guest foreground app info pushed via the event stream.
public struct GuestForegroundApp: Equatable {
    public let name: String
    public let bundleId: String
    public let icon: NSImage?
}

/// Persistent event stream from guest via vsock port 5003.
/// Reads NDJSON lines and dispatches: file queue updates, URL opens, log messages.
@MainActor
public final class EventStreamService: ObservableObject {
    @Published public private(set) var queuedGuestFiles: [String] = []
    @Published public private(set) var detectedGuestPorts: [GuestPort] = []
    @Published public private(set) var foregroundApp: GuestForegroundApp?
    @Published public private(set) var pendingURLs: [String] = []

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
        detectedGuestPorts = []
        foregroundApp = nil
        pendingURLs = []
    }

    public func clearPendingURLs() {
        pendingURLs = []
    }

    private func reconnectLoop() async {
        while !Task.isCancelled {
            guard let client = client else { break }

            NSLog("EventStream: connecting to port %u...", port)

            do {
                // IMPORTANT: Hold `connection` alive — dropping it closes the fd.
                let connection = try await client.connectRaw(port: port)
                let fd = connection.fileDescriptor

                NSLog("EventStream: connected (fd=%d), reading NDJSON lines...", fd)

                // Read NDJSON lines on background queue.
                // `connection` is captured to keep it alive.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        self?.readLines(fd: fd)
                        NSLog("EventStream: connection lost (EOF)")
                        connection.close()
                        continuation.resume()
                    }
                }
            } catch {
                NSLog("EventStream: connection failed: %@", error.localizedDescription)
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
                let validURLs = URLUtilities.filterWebURLs(urls)
                if !validURLs.isEmpty {
                    Task { @MainActor [weak self] in
                        self?.pendingURLs = validURLs
                    }
                }
            }
        case "ports":
            if let portObjects = obj["ports"] as? [[String: Any]] {
                // New format: [{"port": 5012, "process": "node"}, ...]
                let guestPorts = portObjects.compactMap { entry -> GuestPort? in
                    guard let port = entry["port"] as? Int else { return nil }
                    let process = entry["process"] as? String ?? ""
                    return GuestPort(port: port, process: process)
                }
                let summary = guestPorts.map { "\($0.process.isEmpty ? "?" : $0.process):\($0.port)" }
                NSLog("EventStream: ports (new format): %@", summary.joined(separator: ", "))
                Task { @MainActor [weak self] in
                    self?.detectedGuestPorts = guestPorts
                }
            } else if let ports = obj["ports"] as? [Int] {
                // Legacy format: [5012, 3000, ...] — no process names
                NSLog("EventStream: ports (LEGACY format, no process names): %@", ports.map { String($0) }.joined(separator: ", "))
                let guestPorts = ports.map { GuestPort(port: $0, process: "") }
                Task { @MainActor [weak self] in
                    self?.detectedGuestPorts = guestPorts
                }
            } else {
                NSLog("EventStream: WARNING: 'ports' field not parseable: %@", String(describing: obj["ports"]))
            }
        case "app":
            if let name = obj["name"] as? String, let bundleId = obj["bundleId"] as? String {
                var icon: NSImage? = nil
                if let iconStr = obj["icon"] as? String,
                   let iconData = Data(base64Encoded: iconStr) {
                    icon = NSImage(data: iconData)
                }
                let app = GuestForegroundApp(name: name, bundleId: bundleId, icon: icon)
                Task { @MainActor [weak self] in
                    self?.foregroundApp = app
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
