import AppKit
import CoreGraphics

/// Configuration for a keyboard shortcut
struct ShortcutConfig: Codable, Equatable {
    var keyCode: UInt16
    var modifierFlags: UInt

    /// Default shortcut: Ctrl+Opt+Cmd+U
    static let defaultShortcut = ShortcutConfig(
        keyCode: 32, // "U" key
        modifierFlags: NSEvent.ModifierFlags([.control, .option, .command]).rawValue
    )

    /// Human-readable display string like "⌃⌥⌘U"
    var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.command) { parts.append("⌘") }
        if flags.contains(.shift) { parts.append("⇧") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    /// Lowercase character for NSMenuItem.keyEquivalent
    var keyEquivalentCharacter: String {
        keyCodeToString(keyCode).lowercased()
    }

    /// Modifier flags for NSMenuItem.keyEquivalentModifierMask
    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection([.control, .option, .command, .shift])
    }

    /// Convert modifier flags to CGEventFlags for matching
    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        let nsFlags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        if nsFlags.contains(.control) { flags.insert(.maskControl) }
        if nsFlags.contains(.option) { flags.insert(.maskAlternate) }
        if nsFlags.contains(.command) { flags.insert(.maskCommand) }
        if nsFlags.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }
}

/// Maps a virtual key code to a human-readable string
private func keyCodeToString(_ keyCode: UInt16) -> String {
    let keyMap: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        49: "Space", 50: "`",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
        118: "F4", 120: "F2", 122: "F1",
        36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    return keyMap[keyCode] ?? "Key\(keyCode)"
}

/// Global keyboard shortcut service using CGEventTap for reliable cross-app hotkeys
final class GlobalShortcutService {
    static let shared = GlobalShortcutService()

    /// Called when the configured shortcut is triggered
    var onShortcutTriggered: (() -> Void)?

    /// Whether the global shortcut is enabled
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "globalShortcutEnabled")
            stop()
            if newValue { start() }
        }
    }

    /// The current shortcut configuration
    var currentShortcut: ShortcutConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: "globalShortcut_sendToHost"),
                  let config = try? JSONDecoder().decode(ShortcutConfig.self, from: data) else {
                return .defaultShortcut
            }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "globalShortcut_sendToHost")
            }
        }
    }

    /// Whether Input Monitoring permission has been granted.
    var isInputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    /// Start listening for the global shortcut (if enabled)
    func start() {
        guard isEnabled else { return }
        guard eventTap == nil else { return }

        if !isInputMonitoringGranted {
            print("[GlobalShortcut] Input Monitoring not granted, prompting...")
            requestInputMonitoringPermission()
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Store self in an Unmanaged pointer to pass through the C callback
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                // Re-enable tap if macOS disabled it due to timeout
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let userInfo {
                        let service = Unmanaged<GlobalShortcutService>.fromOpaque(userInfo).takeUnretainedValue()
                        if let tap = service.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<GlobalShortcutService>.fromOpaque(userInfo).takeUnretainedValue()
                let config = service.currentShortcut

                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                let eventFlags = event.flags
                let maskedFlags = eventFlags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])

                if keyCode == config.keyCode && maskedFlags == config.cgEventFlags {
                    DispatchQueue.main.async {
                        service.onShortcutTriggered?()
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            print("[GlobalShortcut] Failed to create event tap (permission not granted?)")
            return
        }

        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source

        CGEvent.tapEnable(tap: tap, enable: true)
        print("[GlobalShortcut] Event tap installed (shortcut: \(currentShortcut.displayString), inputMonitoring: \(isInputMonitoringGranted))")
    }

    /// Stop listening for the global shortcut
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            // CFMachPort doesn't need explicit close — invalidating removes it
            CFMachPortInvalidate(tap)
            eventTap = nil
            runLoopSource = nil
            print("[GlobalShortcut] Event tap removed")
        }
    }

    /// Prompt user for Input Monitoring permission
    func requestInputMonitoringPermission() {
        CGRequestListenEventAccess()
    }

    /// Reset shortcut to default
    func resetToDefault() {
        currentShortcut = .defaultShortcut
    }
}
