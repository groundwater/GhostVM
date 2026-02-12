import AppKit
import CoreGraphics

/// Service for simulating keyboard input in the guest
final class KeyboardService {
    static let shared = KeyboardService()
    private init() {}

    private let eventSource = CGEventSource(stateID: .combinedSessionState)

    struct KeyboardRequest: Codable {
        let text: String?
        let keys: [String]?
        let modifiers: [String]?
        let rate: Int?  // ms between keystrokes, 0 = instant
        let wait: Bool?
    }

    enum KeyboardError: Error, LocalizedError {
        case permissionDenied
        case invalidInput

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Accessibility permission required"
            case .invalidInput: return "No text or keys provided"
            }
        }
    }

    /// Send keyboard input
    func sendInput(text: String?, keys: [String]?, modifiers: [String]?, rate: Int?) throws {
        // Check Accessibility permission — CGEvent.post silently fails without it
        guard AXIsProcessTrusted() else {
            throw KeyboardError.permissionDenied
        }

        let modifierFlags = parseModifiers(modifiers ?? [])
        let delay = UInt32((rate ?? 0) * 1000) // convert ms to microseconds

        if let text = text {
            TextInputOverlay.shared.showTyping(text: text, rate: rate ?? 0)
            try typeText(text, modifiers: modifierFlags, delay: delay)
        } else if let keys = keys {
            TextInputOverlay.shared.showKeyCombo(keys: keys, modifiers: modifiers ?? [])
            try sendKeys(keys, modifiers: modifierFlags, delay: delay)
        } else {
            throw KeyboardError.invalidInput
        }
    }

    // MARK: - Private

    private func typeText(_ text: String, modifiers: CGEventFlags, delay: UInt32) throws {
        for char in text {
            let utf16 = Array(String(char).utf16)

            guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else {
                throw KeyboardError.permissionDenied
            }

            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            // Always set flags explicitly to avoid inheriting stale modifier
            // state from combinedSessionState event source
            down.flags = modifiers
            up.flags = modifiers

            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)

            if delay > 0 { usleep(delay) }
        }
    }

    private func sendKeys(_ keys: [String], modifiers: CGEventFlags, delay: UInt32) throws {
        for key in keys {
            guard let keyCode = virtualKeyCode(for: key) else {
                continue // Skip unknown keys
            }

            guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false) else {
                throw KeyboardError.permissionDenied
            }

            // Always set flags explicitly to avoid inheriting stale modifier
            // state from combinedSessionState event source
            down.flags = modifiers
            up.flags = modifiers

            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)

            if delay > 0 { usleep(delay) }
        }
    }

    private func parseModifiers(_ names: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        for name in names {
            switch name.lowercased() {
            case "command", "cmd":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "option", "alt":
                flags.insert(.maskAlternate)
            case "control", "ctrl":
                flags.insert(.maskControl)
            default:
                break
            }
        }
        return flags
    }

    private func virtualKeyCode(for name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "return", "enter":     return 0x24
        case "tab":                 return 0x30
        case "space":               return 0x31
        case "delete", "backspace": return 0x33
        case "escape", "esc":       return 0x35
        case "left":                return 0x7B
        case "right":               return 0x7C
        case "down":                return 0x7D
        case "up":                  return 0x7E
        case "home":                return 0x73
        case "end":                 return 0x77
        case "pageup":              return 0x74
        case "pagedown":            return 0x79
        case "forwarddelete":       return 0x75
        case "f1":                  return 0x7A
        case "f2":                  return 0x78
        case "f3":                  return 0x63
        case "f4":                  return 0x76
        case "f5":                  return 0x60
        case "f6":                  return 0x61
        case "f7":                  return 0x62
        case "f8":                  return 0x64
        case "f9":                  return 0x65
        case "f10":                 return 0x6D
        case "f11":                 return 0x67
        case "f12":                 return 0x6F
        case "a":                   return 0x00
        case "b":                   return 0x0B
        case "c":                   return 0x08
        case "d":                   return 0x02
        case "e":                   return 0x0E
        case "f":                   return 0x03
        case "g":                   return 0x05
        case "h":                   return 0x04
        case "i":                   return 0x22
        case "j":                   return 0x26
        case "k":                   return 0x28
        case "l":                   return 0x25
        case "m":                   return 0x2E
        case "n":                   return 0x2D
        case "o":                   return 0x1F
        case "p":                   return 0x23
        case "q":                   return 0x0C
        case "r":                   return 0x0F
        case "s":                   return 0x01
        case "t":                   return 0x11
        case "u":                   return 0x20
        case "v":                   return 0x09
        case "w":                   return 0x0D
        case "x":                   return 0x07
        case "y":                   return 0x10
        case "z":                   return 0x06
        default:                    return nil
        }
    }
}
