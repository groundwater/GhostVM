import AppKit
import Foundation

/// Service for managing clipboard operations between host and guest
/// The guest always allows clipboard operations - the host controls sync policy
final class ClipboardService {
    static let shared = ClipboardService()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0

    private init() {
        lastChangeCount = pasteboard.changeCount
    }

    /// Gets the current clipboard contents as a string
    /// - Returns: The clipboard string content, or nil if unavailable
    func getClipboardContents() -> String? {
        return pasteboard.string(forType: .string)
    }

    /// Sets the clipboard contents from a string
    /// - Parameter content: The string to set on the clipboard
    /// - Returns: true if successful
    @discardableResult
    func setClipboardContents(_ content: String) -> Bool {
        pasteboard.clearContents()
        let success = pasteboard.setString(content, forType: .string)
        if success {
            lastChangeCount = pasteboard.changeCount
        }
        return success
    }

    /// Checks if the clipboard has changed since last check
    func hasClipboardChanged() -> Bool {
        let currentCount = pasteboard.changeCount
        if currentCount != lastChangeCount {
            lastChangeCount = currentCount
            return true
        }
        return false
    }
}
