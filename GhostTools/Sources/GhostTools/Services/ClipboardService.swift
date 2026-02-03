import AppKit
import Foundation

/// Clipboard synchronization modes
enum ClipboardSyncMode: String, CaseIterable, Codable {
    case bidirectional
    case hostToGuest
    case guestToHost
    case disabled

    var displayName: String {
        switch self {
        case .bidirectional: return "Bidirectional"
        case .hostToGuest: return "Host -> Guest"
        case .guestToHost: return "Guest -> Host"
        case .disabled: return "Disabled"
        }
    }

    static func from(displayName: String) -> ClipboardSyncMode? {
        allCases.first { $0.displayName == displayName }
    }
}

/// Service for managing clipboard operations between host and guest
final class ClipboardService {
    static let shared = ClipboardService()

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0

    var syncMode: ClipboardSyncMode {
        get {
            if let stored = UserDefaults.standard.string(forKey: "clipboardSyncMode"),
               let mode = ClipboardSyncMode(rawValue: stored) {
                return mode
            }
            return .bidirectional
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "clipboardSyncMode")
        }
    }

    private init() {
        lastChangeCount = pasteboard.changeCount
    }

    /// Gets the current clipboard contents as a string
    /// - Returns: The clipboard string content, or nil if unavailable
    func getClipboardContents() -> String? {
        guard syncMode == .bidirectional || syncMode == .guestToHost else {
            return nil
        }

        return pasteboard.string(forType: .string)
    }

    /// Sets the clipboard contents from a string
    /// - Parameter content: The string to set on the clipboard
    /// - Returns: true if successful
    @discardableResult
    func setClipboardContents(_ content: String) -> Bool {
        guard syncMode == .bidirectional || syncMode == .hostToGuest else {
            return false
        }

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
