import AppKit

/// Preferences window for configuring GhostTools global shortcut
final class PreferencesWindowController: NSWindowController {

    private var enableCheckbox: NSButton!
    private var shortcutRecorder: ShortcutRecorderView!
    private var resetButton: NSButton!
    /// Called when the shortcut or enabled state changes so the menu can update
    var onSettingsChanged: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GhostTools Preferences"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)
        setupUI()
        loadState()
    }

    // MARK: - UI Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let padding: CGFloat = 20
        let rowHeight: CGFloat = 28
        var y = contentView.bounds.height - padding

        // -- Section: Global Shortcut --
        y -= 18
        let sectionLabel = makeLabel("Send to Host Shortcut", bold: true)
        sectionLabel.frame = NSRect(x: padding, y: y, width: 300, height: 18)
        contentView.addSubview(sectionLabel)

        // Enable checkbox
        y -= rowHeight + 8
        enableCheckbox = NSButton(checkboxWithTitle: "Enable global shortcut", target: self, action: #selector(enableToggled))
        enableCheckbox.frame = NSRect(x: padding, y: y, width: 250, height: rowHeight)
        contentView.addSubview(enableCheckbox)

        // Shortcut label + recorder
        y -= rowHeight + 8
        let shortcutLabel = makeLabel("Shortcut:")
        shortcutLabel.frame = NSRect(x: padding, y: y + 4, width: 65, height: 18)
        contentView.addSubview(shortcutLabel)

        shortcutRecorder = ShortcutRecorderView(shortcut: GlobalShortcutService.shared.currentShortcut)
        shortcutRecorder.frame = NSRect(x: padding + 70, y: y, width: 180, height: rowHeight)
        shortcutRecorder.onShortcutRecorded = { [weak self] config in
            GlobalShortcutService.shared.currentShortcut = config
            self?.updateResetButtonState()
            self?.onSettingsChanged?()
        }
        contentView.addSubview(shortcutRecorder)

        // Reset button
        resetButton = NSButton(title: "Reset", target: self, action: #selector(resetShortcut))
        resetButton.bezelStyle = .rounded
        resetButton.frame = NSRect(x: padding + 260, y: y, width: 80, height: rowHeight)
        contentView.addSubview(resetButton)

    }

    private func loadState() {
        let service = GlobalShortcutService.shared
        enableCheckbox.state = service.isEnabled ? .on : .off
        shortcutRecorder.updateShortcut(service.currentShortcut)
        updateControlStates()
        updateResetButtonState()
    }

    // MARK: - Actions

    @objc private func enableToggled() {
        let enabled = enableCheckbox.state == .on
        GlobalShortcutService.shared.isEnabled = enabled
        updateControlStates()
        onSettingsChanged?()
    }

    @objc private func resetShortcut() {
        GlobalShortcutService.shared.resetToDefault()
        shortcutRecorder.updateShortcut(.defaultShortcut)
        updateResetButtonState()
    }

    // MARK: - State Updates

    private func updateControlStates() {
        let enabled = enableCheckbox.state == .on
        shortcutRecorder.setEnabled(enabled)
        resetButton.isEnabled = enabled
    }

    private func updateResetButtonState() {
        let isDefault = GlobalShortcutService.shared.currentShortcut == .defaultShortcut
        resetButton.isEnabled = !isDefault && enableCheckbox.state == .on
    }

    // MARK: - Window Lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        loadState()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        return label
    }
}
