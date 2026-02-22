import AppKit
import Foundation

/// Service for managing clipboard operations between host and guest
/// The guest always allows clipboard operations - the host controls sync policy
final class ClipboardService {
    static let shared = ClipboardService()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0

    /// Pasteboard types to check, in priority order (richest first)
    private static let typePriority: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        .string,
    ]

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

    /// Gets the best available clipboard data and its UTI type
    /// - Returns: Tuple of (data, uti) or nil if clipboard is empty
    func getClipboardData() -> (data: Data, type: String)? {
        for pbType in Self.typePriority {
            if let data = pasteboard.data(forType: pbType) {
                return (data, utiString(for: pbType))
            }
        }
        return nil
    }

    /// Sets clipboard data with a UTI type
    /// - Parameters:
    ///   - data: The binary data to set
    ///   - type: UTI string (e.g. "public.png", "public.utf8-plain-text")
    /// - Returns: true if successful
    @discardableResult
    func setClipboardData(_ data: Data, type: String) -> Bool {
        let pbType = pasteboardType(for: type)
        pasteboard.clearContents()
        let success = pasteboard.setData(data, forType: pbType)
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

    // MARK: - UTI Mapping

    private func utiString(for type: NSPasteboard.PasteboardType) -> String {
        switch type {
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        case .string: return "public.utf8-plain-text"
        default: return type.rawValue
        }
    }

    private func pasteboardType(for uti: String) -> NSPasteboard.PasteboardType {
        switch uti {
        case "public.png": return .png
        case "public.tiff": return .tiff
        case "public.utf8-plain-text": return .string
        default: return NSPasteboard.PasteboardType(uti)
        }
    }
}
