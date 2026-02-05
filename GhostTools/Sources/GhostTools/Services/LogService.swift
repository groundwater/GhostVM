import Foundation

/// Service for capturing logs and making them available via HTTP polling
final class LogService: @unchecked Sendable {
    static let shared = LogService()

    /// Buffered log entries waiting to be fetched
    private var buffer: [String] = []
    private let lock = NSLock()
    private let maxBufferSize = 500

    private init() {}

    /// Add a log message to the buffer
    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(message)
        // Trim if too large
        if buffer.count > maxBufferSize {
            buffer.removeFirst(buffer.count - maxBufferSize)
        }
    }

    /// Get and clear all buffered logs
    func popAll() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let logs = buffer
        buffer.removeAll()
        return logs
    }
}

/// Global logging function that prints locally and buffers for host polling
/// Use this instead of print() throughout GhostTools
func log(_ message: String) {
    print(message)
    LogService.shared.append(message)
}
