import Foundation

/// Service for managing URLs to be opened on the host
final class URLService {
    static let shared = URLService()

    /// URLs queued for opening on host
    private var pendingURLs: [URL] = []
    private let lock = NSLock()

    private init() {}

    /// Queue a URL to be opened on the host
    func queueURL(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        pendingURLs.append(url)
        print("[URLService] Queued URL: \(url.absoluteString)")
    }

    /// Get all pending URLs
    func listPendingURLs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return pendingURLs.map { $0.absoluteString }
    }

    /// Clear all pending URLs
    func clearPendingURLs() {
        lock.lock()
        defer { lock.unlock() }
        pendingURLs.removeAll()
        print("[URLService] Cleared pending URLs")
    }

    /// Get and clear pending URLs atomically
    func popAllURLs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let urls = pendingURLs.map { $0.absoluteString }
        pendingURLs.removeAll()
        return urls
    }
}
