import AppKit
import CoreGraphics

/// UserDefaults key for auto-start preference (must match App.swift)
private let kAutoStartEnabledKey = "com.ghostvm.ghosttools.autoStartEnabled"

/// Onboarding window that shows required permissions and their status.
/// Shown on startup if any permission is missing. Auto-dismisses when all granted.
///
/// macOS preflight APIs (CGPreflightScreenCaptureAccess) return
/// stale results — they don't update until the process restarts. So after the user
/// clicks "Enable" and grants the permission in System Settings, we offer a "Restart"
/// button to relaunch GhostTools and pick up the change.
final class PermissionsWindow {
    static let shared = PermissionsWindow()
    private init() {}

    private var window: NSWindow?
    private var pollTimer: Timer?
    private var rows: [PermissionRow] = []
    private var autoStartObserver: Any?

    struct Permission {
        let name: String
        let description: String
        let check: () -> Bool
        let request: () -> Void
    }

    private class PermissionRow {
        let index: Int
        let dot: NSView
        let button: NSButton
        let grantedLabel: NSTextField
        var hasClickedEnable = false

        init(index: Int, dot: NSView, button: NSButton, grantedLabel: NSTextField) {
            self.index = index
            self.dot = dot
            self.button = button
            self.grantedLabel = grantedLabel
        }
    }

    /// Open System Settings to a specific Privacy pane.
    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Check Full Disk Access by testing root directory read
    private static func checkFullDiskAccess() -> Bool {
        let fm = FileManager.default
        do {
            _ = try fm.contentsOfDirectory(atPath: "/")
            return true
        } catch {
            return false
        }
    }

    /// Check if launch agent is installed
    private static func isLaunchAgentInstalled() -> Bool {
        // Access AppDelegate through the shared NSApplication
        // Use MainActor.assumeIsolated since we're always on main thread for UI
        return MainActor.assumeIsolated {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
                return false
            }
            return appDelegate.isLaunchAgentInstalled()
        }
    }

    /// Enable auto-start by posting notification to AppDelegate
    private static func enableAutoStart() {
        NotificationCenter.default.post(name: .autoStartEnableRequested, object: nil)
    }

    private static func permissions() -> [Permission] {
        var perms: [Permission] = []

        // Accessibility (always shown)
        perms.append(Permission(
            name: "Accessibility",
            description: "Pointer clicks, keyboard input, and UI element reading",
            check: { AXIsProcessTrusted() },
            request: {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
            }
        ))

        // Screen Recording (always shown)
        perms.append(Permission(
            name: "Screen Recording",
            description: "Screenshots and screen stability detection",
            check: { CGPreflightScreenCaptureAccess() },
            request: { openPrivacyPane("Privacy_ScreenCapture") }
        ))

        // Full Disk Access (always shown)
        perms.append(Permission(
            name: "Full Disk Access",
            description: "Access protected files for complete VM automation",
            check: { checkFullDiskAccess() },
            request: { openPrivacyPane("Privacy_AllFiles") }
        ))

        // Auto Start (only if not explicitly disabled)
        if UserDefaults.standard.object(forKey: kAutoStartEnabledKey) as? Bool != false {
            perms.append(Permission(
                name: "Auto Start",
                description: "Launch GhostTools automatically at login",
                check: { isLaunchAgentInstalled() },
                request: { enableAutoStart() }
            ))
        }

        return perms
    }

    /// Show the permissions window if any permission is missing.
    @discardableResult
    func showIfNeeded() -> Bool {
        let allGranted = Self.permissions().allSatisfy { $0.check() }
        if allGranted {
            print("[GhostTools] All permissions granted")
            return false
        }
        print("[GhostTools] Missing permissions, showing onboarding window")
        DispatchQueue.main.async { [self] in show() }
        return true
    }

    private func show() {
        if window != nil { return }

        let w: CGFloat = 420
        let rowH: CGFloat = 64
        let headerH: CGFloat = 76
        let footerH: CGFloat = 48
        let perms = Self.permissions()
        let h = headerH + CGFloat(perms.count) * rowH + footerH
        let pad: CGFloat = 28

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "GhostTools Setup"
        win.center()
        win.isReleasedWhenClosed = false

        let cv = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Header
        let title = NSTextField(labelWithString: "Permissions Required")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: pad, y: h - 38, width: w - pad * 2, height: 22)
        cv.addSubview(title)

        let sub = NSTextField(labelWithString: "GhostTools needs these permissions for VM automation.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: pad, y: h - 58, width: w - pad * 2, height: 16)
        cv.addSubview(sub)

        // Rows
        rows = []
        for (i, perm) in perms.enumerated() {
            let rowY = h - headerH - CGFloat(i + 1) * rowH + 8
            let granted = perm.check()

            // Status dot
            let dot = NSView(frame: NSRect(x: pad, y: rowY + 30, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = granted ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
            cv.addSubview(dot)

            // Name
            let name = NSTextField(labelWithString: perm.name)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.frame = NSRect(x: pad + 20, y: rowY + 28, width: 220, height: 18)
            cv.addSubview(name)

            // Description
            let desc = NSTextField(labelWithString: perm.description)
            desc.font = .systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor
            desc.frame = NSRect(x: pad + 20, y: rowY + 10, width: 240, height: 16)
            cv.addSubview(desc)

            // Button (Enable → Restart after first click)
            let btn = NSButton(title: "Enable", target: self, action: #selector(enableClicked(_:)))
            btn.bezelStyle = .rounded
            btn.controlSize = .regular
            btn.frame = NSRect(x: w - pad - 80, y: rowY + 22, width: 80, height: 28)
            btn.tag = i
            btn.isHidden = granted
            cv.addSubview(btn)

            // Granted label (shown when granted)
            let gl = NSTextField(labelWithString: "\u{2714}  Granted")
            gl.font = .systemFont(ofSize: 12, weight: .medium)
            gl.textColor = .systemGreen
            gl.alignment = .right
            gl.frame = NSRect(x: w - pad - 90, y: rowY + 26, width: 90, height: 18)
            gl.isHidden = !granted
            cv.addSubview(gl)

            rows.append(PermissionRow(index: i, dot: dot, button: btn, grantedLabel: gl))

            // Separator
            if i < perms.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.frame = NSRect(x: pad, y: rowY + 2, width: w - pad * 2, height: 1)
                cv.addSubview(sep)
            }
        }

        // Footer
        let skip = NSButton(title: "Continue Without All Permissions", target: self, action: #selector(dismissWindow))
        skip.bezelStyle = .inline
        skip.font = .systemFont(ofSize: 11)
        skip.frame = NSRect(x: w / 2 - 120, y: 14, width: 240, height: 22)
        cv.addSubview(skip)

        win.contentView = cv
        window = win

        updateStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        // Observe auto-start preference changes
        autoStartObserver = NotificationCenter.default.addObserver(forName: .autoStartPreferenceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func enableClicked(_ sender: NSButton) {
        let i = sender.tag
        let perms = Self.permissions()
        guard i >= 0 && i < perms.count else { return }

        guard let row = rows.first(where: { $0.index == i }) else { return }

        if row.hasClickedEnable {
            // Second click = restart GhostTools to pick up permission changes
            restartApp()
        } else {
            // First click = open Settings
            row.hasClickedEnable = true
            perms[i].request()
            // Change button to "Restart" for next click
            sender.title = "Restart"
        }
    }

    @objc private func dismissWindow() {
        cleanup()
    }

    /// Rebuild the window when permissions list changes (e.g., auto-start disabled)
    private func rebuild() {
        guard window != nil else { return }
        cleanup()
        show()
    }

    private func updateStatus() {
        let perms = Self.permissions()
        var allGranted = true
        for row in rows {
            guard row.index < perms.count else { continue }
            let granted = perms[row.index].check()
            row.dot.layer?.backgroundColor = granted ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
            row.button.isHidden = granted
            row.grantedLabel.isHidden = !granted
            if !granted { allGranted = false }
        }
        if allGranted {
            print("[GhostTools] All permissions granted, dismissing onboarding window")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in cleanup() }
        }
    }

    private func restartApp() {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return }
        let execPath = bundlePath + "/Contents/MacOS/GhostTools"
        print("[GhostTools] Restarting to pick up permission changes...")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private func cleanup() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = autoStartObserver {
            NotificationCenter.default.removeObserver(observer)
            autoStartObserver = nil
        }
        window?.close()
        window = nil
        rows = []
    }
}
