import AppKit
import ApplicationServices

/// UserDefaults key for auto-start preference (must match App.swift)
private let kAutoStartEnabledKey = "org.ghostvm.ghosttools.autoStartEnabled"
/// UserDefaults key for auto-update preference
private let kAutoUpdateEnabledKey = "org.ghostvm.ghosttools.autoUpdateEnabled"

/// Permissions window that shows required permissions and their status.
/// Can be opened from the menu bar.
@MainActor
final class PermissionsWindow: NSObject {
    static let shared = PermissionsWindow()
    private override init() { super.init() }

    private var window: NSWindow?
    private var pollTimer: Timer?
    private var permissionRows: [PermissionRow] = []
    private var autoStartObserver: Any?
    private var didCopyToApplications = false
    private var lastCopyError: String?
    private weak var appDelegate: AppDelegate?

    // Install action UI elements
    private var installDot: NSView?
    private var installButton: NSButton?
    // Auto Start toggle
    private var autoStartToggle: GreenToggle?
    private var autoStartDot: NSView?
    // Auto Update toggle
    private var autoUpdateToggle: GreenToggle?
    private var autoUpdateDot: NSView?

    struct Permission {
        let name: String
        let description: String
        let check: () -> Bool
        let request: () -> Void
        /// When false, the button is shown but disabled (grayed out)
        let enabled: Bool

        init(name: String, description: String, check: @escaping () -> Bool, request: @escaping () -> Void, enabled: Bool = true) {
            self.name = name
            self.description = description
            self.check = check
            self.request = request
            self.enabled = enabled
        }
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

    private static func isInstalledInApplications() -> Bool {
        Bundle.main.bundlePath == kApplicationsPath
    }

    private var needsInstall: Bool {
        !Self.isInstalledInApplications() && !didCopyToApplications
    }

    /// Copied but not yet running from /Applications — needs restart
    private var needsRestart: Bool {
        didCopyToApplications && !Self.isInstalledInApplications()
    }

    private var inApplications: Bool {
        Self.isInstalledInApplications() || didCopyToApplications
    }

    private func permissions() -> [Permission] {
        var perms: [Permission] = []
        let ad = self.appDelegate

        perms.append(Permission(
            name: "Accessibility",
            description: "Pointer clicks, keyboard input, and UI element reading",
            check: { AXIsProcessTrusted() },
            request: {
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
            },
            enabled: inApplications
        ))

        perms.append(Permission(
            name: "Default Web Browser",
            description: "Forward URLs from guest to host",
            check: { ad?.isDefaultBrowser() ?? false },
            request: { ad?.registerAsDefaultBrowser() },
            enabled: inApplications
        ))

        return perms
    }

    /// Check if all green dots are on.
    func allGranted(from delegate: AppDelegate) -> Bool {
        self.appDelegate = delegate
        if !Self.isInstalledInApplications() { return false }
        if !(delegate.isLaunchAgentInstalled()) { return false }
        if !Self.isAutoUpdateEnabled { return false }
        return permissions().allSatisfy { $0.check() }
    }

    private static var isAutoUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: kAutoUpdateEnabledKey) as? Bool ?? false
    }

    /// Show the permissions window.
    func show(from delegate: AppDelegate) {
        self.appDelegate = delegate
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w: CGFloat = 460
        let rowH: CGFloat = 78
        let headerH: CGFloat = 76
        let footerH: CGFloat = 48
        let perms = permissions()
        let installRowH: CGFloat = rowH
        let toggleRowsH: CGFloat = rowH * 2
        let h = headerH + installRowH + CGFloat(perms.count) * rowH + toggleRowsH + footerH
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
        let title = NSTextField(labelWithString: "GhostTools Setup")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: pad, y: h - 38, width: w - pad * 2, height: 22)
        cv.addSubview(title)

        let sub = NSTextField(labelWithString: "GhostTools needs these permissions to work properly.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: pad, y: h - 58, width: w - pad * 2, height: 16)
        cv.addSubview(sub)

        var nextRowTop = h - headerH

        // -- Install row (always shown) --
        do {
            let rowY = nextRowTop - rowH + 8
            let installed = Self.isInstalledInApplications()

            let dot = NSView(frame: NSRect(x: pad, y: rowY + 42, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = (installed || needsRestart) ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
            cv.addSubview(dot)
            installDot = dot

            let name = NSTextField(labelWithString: "Copy to /Applications")
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.frame = NSRect(x: pad + 20, y: rowY + 40, width: 260, height: 18)
            cv.addSubview(name)

            let desc = NSTextField(labelWithString: "Install GhostTools for auto-start and persistence")
            desc.font = .systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor
            desc.lineBreakMode = .byWordWrapping
            desc.maximumNumberOfLines = 2
            desc.frame = NSRect(x: pad + 20, y: rowY + 4, width: w - pad * 2 - 20, height: 30)
            cv.addSubview(desc)

            if installed {
                let gl = NSTextField(labelWithString: "\u{2714}  Installed")
                gl.font = .systemFont(ofSize: 12, weight: .medium)
                gl.textColor = .systemGreen
                gl.alignment = .right
                gl.frame = NSRect(x: w - pad - 90, y: rowY + 38, width: 90, height: 18)
                cv.addSubview(gl)
            } else if needsRestart {
                let btn = NSButton(title: "Restart", target: self, action: #selector(restartClicked))
                btn.bezelStyle = .rounded
                btn.controlSize = .regular
                btn.keyEquivalent = "\r"
                btn.frame = NSRect(x: w - pad - 80, y: rowY + 34, width: 80, height: 28)
                cv.addSubview(btn)
                installButton = btn
            } else {
                let btn = NSButton(title: "Install", target: self, action: #selector(installClicked(_:)))
                btn.bezelStyle = .rounded
                btn.controlSize = .regular
                btn.frame = NSRect(x: w - pad - 80, y: rowY + 34, width: 80, height: 28)
                cv.addSubview(btn)
                installButton = btn
            }

            let sep = NSBox()
            sep.boxType = .separator
            sep.frame = NSRect(x: pad, y: rowY + 2, width: w - pad * 2, height: 1)
            cv.addSubview(sep)

            nextRowTop -= rowH
        }

        // -- Permission rows --
        permissionRows = []
        for (i, perm) in perms.enumerated() {
            let rowY = nextRowTop - CGFloat(i + 1) * rowH + 8
            let granted = perm.check()

            let dot = NSView(frame: NSRect(x: pad, y: rowY + 42, width: 10, height: 10))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 5
            dot.layer?.backgroundColor = granted ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
            cv.addSubview(dot)

            let name = NSTextField(labelWithString: perm.name)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.frame = NSRect(x: pad + 20, y: rowY + 40, width: 260, height: 18)
            cv.addSubview(name)

            let desc = NSTextField(labelWithString: perm.description)
            desc.font = .systemFont(ofSize: 11)
            desc.textColor = .secondaryLabelColor
            desc.lineBreakMode = .byWordWrapping
            desc.maximumNumberOfLines = 2
            desc.frame = NSRect(x: pad + 20, y: rowY + 4, width: w - pad * 2 - 20, height: 30)
            cv.addSubview(desc)

            let btn = NSButton(title: "Enable", target: self, action: #selector(enableClicked(_:)))
            btn.bezelStyle = .rounded
            btn.controlSize = .regular
            btn.frame = NSRect(x: w - pad - 80, y: rowY + 34, width: 80, height: 28)
            btn.tag = i
            btn.isHidden = granted
            if !perm.enabled {
                btn.isEnabled = false
                btn.toolTip = "Requires Copy to /Applications first"
            }
            cv.addSubview(btn)

            let gl = NSTextField(labelWithString: "\u{2714}  Granted")
            gl.font = .systemFont(ofSize: 12, weight: .medium)
            gl.textColor = .systemGreen
            gl.alignment = .right
            gl.frame = NSRect(x: w - pad - 90, y: rowY + 38, width: 90, height: 18)
            gl.isHidden = !granted
            cv.addSubview(gl)

            permissionRows.append(PermissionRow(index: i, dot: dot, button: btn, grantedLabel: gl))

            if i < perms.count - 1 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.frame = NSRect(x: pad, y: rowY + 2, width: w - pad * 2, height: 1)
                cv.addSubview(sep)
            }
        }

        // -- Auto Start toggle --
        let autoStartY = footerH + rowH + 8
        let autoStartOn = appDelegate?.isLaunchAgentInstalled() ?? false

        let autoStartSep = NSBox()
        autoStartSep.boxType = .separator
        autoStartSep.frame = NSRect(x: pad, y: autoStartY + rowH - 6, width: w - pad * 2, height: 1)
        cv.addSubview(autoStartSep)

        let autoStartDot = NSView(frame: NSRect(x: pad, y: autoStartY + 42, width: 10, height: 10))
        autoStartDot.wantsLayer = true
        autoStartDot.layer?.cornerRadius = 5
        autoStartDot.layer?.backgroundColor = autoStartOn ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
        cv.addSubview(autoStartDot)
        self.autoStartDot = autoStartDot

        let autoStartName = NSTextField(labelWithString: "Auto Start")
        autoStartName.font = .systemFont(ofSize: 13, weight: .medium)
        autoStartName.frame = NSRect(x: pad + 20, y: autoStartY + 40, width: 260, height: 18)
        cv.addSubview(autoStartName)

        let autoStartDesc = NSTextField(labelWithString: "Launch GhostTools automatically at login")
        autoStartDesc.font = .systemFont(ofSize: 11)
        autoStartDesc.textColor = .secondaryLabelColor
        autoStartDesc.lineBreakMode = .byWordWrapping
        autoStartDesc.maximumNumberOfLines = 2
        autoStartDesc.frame = NSRect(x: pad + 20, y: autoStartY + 4, width: w - pad * 2 - 20, height: 30)
        cv.addSubview(autoStartDesc)

        let startToggle = GreenToggle(isOn: autoStartOn, target: self, action: #selector(autoStartToggled(_:)))
        startToggle.frame = NSRect(x: w - pad - 38, y: autoStartY + 34, width: 38, height: 22)
        if !inApplications { startToggle.isEnabled = false }
        cv.addSubview(startToggle)
        autoStartToggle = startToggle

        // -- Auto Update toggle --
        let autoUpdateY = footerH + 8
        let autoUpdateOn = Self.isAutoUpdateEnabled

        let autoUpdateSep = NSBox()
        autoUpdateSep.boxType = .separator
        autoUpdateSep.frame = NSRect(x: pad, y: autoUpdateY + rowH - 6, width: w - pad * 2, height: 1)
        cv.addSubview(autoUpdateSep)

        let autoUpdateDot = NSView(frame: NSRect(x: pad, y: autoUpdateY + 42, width: 10, height: 10))
        autoUpdateDot.wantsLayer = true
        autoUpdateDot.layer?.cornerRadius = 5
        autoUpdateDot.layer?.backgroundColor = autoUpdateOn ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
        cv.addSubview(autoUpdateDot)
        self.autoUpdateDot = autoUpdateDot

        let autoUpdateName = NSTextField(labelWithString: "Auto Update")
        autoUpdateName.font = .systemFont(ofSize: 13, weight: .medium)
        autoUpdateName.frame = NSRect(x: pad + 20, y: autoUpdateY + 40, width: 260, height: 18)
        cv.addSubview(autoUpdateName)

        let autoUpdateDesc = NSTextField(labelWithString: "Automatically update GhostTools when a new version is available")
        autoUpdateDesc.font = .systemFont(ofSize: 11)
        autoUpdateDesc.textColor = .secondaryLabelColor
        autoUpdateDesc.lineBreakMode = .byWordWrapping
        autoUpdateDesc.maximumNumberOfLines = 2
        autoUpdateDesc.frame = NSRect(x: pad + 20, y: autoUpdateY + 4, width: w - pad * 2 - 20, height: 30)
        cv.addSubview(autoUpdateDesc)

        let updateToggle = GreenToggle(isOn: autoUpdateOn, target: self, action: #selector(autoUpdateToggled(_:)))
        updateToggle.frame = NSRect(x: w - pad - 38, y: autoUpdateY + 34, width: 38, height: 22)
        if !inApplications { updateToggle.isEnabled = false }
        cv.addSubview(updateToggle)
        autoUpdateToggle = updateToggle

        // Footer
        let done = NSButton(title: "Done", target: self, action: #selector(dismissWindow))
        done.bezelStyle = .inline
        done.font = .systemFont(ofSize: 11)
        done.frame = NSRect(x: w / 2 - 40, y: 14, width: 80, height: 22)
        cv.addSubview(done)

        win.contentView = cv
        window = win

        updateStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        autoStartObserver = NotificationCenter.default.addObserver(forName: .autoStartPreferenceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Install action

    @objc private func installClicked(_ sender: NSButton) {
        guard let ad = appDelegate else {
            showCopyError("No app delegate")
            return
        }

        if didCopyToApplications {
            // Already copied — restart into /Applications
            restartApp()
            return
        }

        let err = ad.performCopyToApplications()
        if let err = err {
            showCopyError(err)
            return
        }

        // Success — rebuild to show primary Restart button
        didCopyToApplications = true
        rebuild()
    }

    @objc private func restartClicked() {
        restartApp()
    }

    private func showCopyError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Copy Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Auto Start toggle

    @objc private func autoStartToggled(_ sender: GreenToggle) {
        let on = sender.isOn
        autoStartDot?.layer?.backgroundColor = on ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
        if on {
            NotificationCenter.default.post(name: .autoStartEnableRequested, object: nil)
        } else {
            NotificationCenter.default.post(name: .autoStartDisableRequested, object: nil)
        }
    }

    // MARK: - Auto Update toggle

    @objc private func autoUpdateToggled(_ sender: GreenToggle) {
        let on = sender.isOn
        UserDefaults.standard.set(on, forKey: kAutoUpdateEnabledKey)
        autoUpdateDot?.layer?.backgroundColor = on ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor
    }

    // MARK: - Permission actions

    @objc private func enableClicked(_ sender: NSButton) {
        let i = sender.tag
        let perms = permissions()
        guard i >= 0 && i < perms.count else { return }
        guard let row = permissionRows.first(where: { $0.index == i }) else { return }

        if row.hasClickedEnable {
            // Second click = restart
            restartApp()
        } else {
            row.hasClickedEnable = true
            perms[i].request()

            let granted = perms[i].check()
            if granted {
                row.dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
                row.button.isHidden = true
                row.grantedLabel.isHidden = false
            } else {
                // Permission not immediately granted (e.g. Accessibility opens System Settings)
                sender.title = "Restart"
            }
        }
    }

    @objc private func dismissWindow() {
        cleanup()
    }

    private func rebuild() {
        guard window != nil, let ad = appDelegate else { return }
        cleanup()
        show(from: ad)
    }

    private func updateStatus() {
        let perms = permissions()
        for row in permissionRows {
            guard row.index < perms.count else { continue }
            let granted = perms[row.index].check()
            row.dot.layer?.backgroundColor = granted ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor

            if granted {
                row.button.isHidden = true
                row.grantedLabel.isHidden = false
            }
        }
    }

    private func restartApp() {
        let appPath = didCopyToApplications ? kApplicationsPath : Bundle.main.bundlePath
        print("[GhostTools] Restarting: open \(appPath)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [appPath]
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
        permissionRows = []
        installDot = nil
        installButton = nil
        autoStartToggle = nil
        autoStartDot = nil
        autoUpdateToggle = nil
        autoUpdateDot = nil
    }
}

// MARK: - Custom green toggle (iOS-style switch with systemGreen + animation)

private class GreenToggle: NSView {
    var isOn: Bool {
        didSet {
            guard oldValue != isOn else { return }
            updateLayers(animated: true)
        }
    }
    var isEnabled: Bool = true {
        didSet { alphaValue = isEnabled ? 1.0 : 0.5 }
    }
    private weak var target: AnyObject?
    private var action: Selector?

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    init(isOn: Bool, target: AnyObject?, action: Selector?) {
        self.isOn = isOn
        self.target = target
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        setupLayers()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 38, height: 22) }

    private func setupLayers() {
        guard let root = layer else { return }

        trackLayer.cornerRadius = 10
        root.addSublayer(trackLayer)

        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.cornerRadius = 8
        knobLayer.shadowColor = NSColor.black.cgColor
        knobLayer.shadowOffset = CGSize(width: 0, height: -1)
        knobLayer.shadowRadius = 1
        knobLayer.shadowOpacity = 0.15
        trackLayer.addSublayer(knobLayer)

        updateLayers(animated: false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds.insetBy(dx: 1, dy: 1)
        let knobDiameter = trackLayer.bounds.height - 4
        let knobX = isOn ? trackLayer.bounds.width - knobDiameter - 2 : CGFloat(2)
        knobLayer.frame = CGRect(x: knobX, y: 2, width: knobDiameter, height: knobDiameter)
        CATransaction.commit()
    }

    private func updateLayers(animated: Bool) {
        if !animated {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
        }

        trackLayer.backgroundColor = isOn ? NSColor.systemGreen.cgColor : NSColor.tertiaryLabelColor.cgColor

        let knobDiameter = trackLayer.bounds.height - 4
        let knobX = isOn ? trackLayer.bounds.width - knobDiameter - 2 : CGFloat(2)
        knobLayer.frame = CGRect(x: knobX, y: 2, width: knobDiameter, height: knobDiameter)

        if !animated {
            CATransaction.commit()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        if let target = target, let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}
