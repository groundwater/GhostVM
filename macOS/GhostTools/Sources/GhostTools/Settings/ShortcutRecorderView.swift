import AppKit

/// Custom NSView that records a keyboard shortcut when clicked
final class ShortcutRecorderView: NSView {
    /// Called when the user records a new shortcut
    var onShortcutRecorded: ((ShortcutConfig) -> Void)?

    private var isRecording = false
    private var displayedShortcut: ShortcutConfig
    private var trackingArea: NSTrackingArea?

    init(shortcut: ShortcutConfig) {
        self.displayedShortcut = shortcut
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateShortcut(_ shortcut: ShortcutConfig) {
        displayedShortcut = shortcut
        isRecording = false
        updateAppearance()
        needsDisplay = true
    }

    // MARK: - Drawing

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let text: String
        let color: NSColor

        if isRecording {
            text = "Press shortcut..."
            color = .secondaryLabelColor
        } else {
            text = displayedShortcut.displayString
            color = .labelColor
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: color,
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let size = attrStr.size()
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        attrStr.draw(at: point)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            isRecording = true
            updateAppearance()
            needsDisplay = true
            window?.makeFirstResponder(self)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Escape cancels recording
        if event.keyCode == 53 {
            isRecording = false
            updateAppearance()
            needsDisplay = true
            return
        }

        // Require at least one modifier key
        let modifiers = event.modifierFlags.intersection([.control, .option, .command, .shift])
        guard !modifiers.isEmpty else { return }

        let config = ShortcutConfig(
            keyCode: event.keyCode,
            modifierFlags: modifiers.rawValue
        )

        displayedShortcut = config
        isRecording = false
        updateAppearance()
        needsDisplay = true
        onShortcutRecorded?(config)
    }

    override func flagsChanged(with event: NSEvent) {
        // Consume modifier-only presses during recording
        if isRecording { return }
        super.flagsChanged(with: event)
    }

    // MARK: - Appearance

    private func updateAppearance() {
        if isRecording {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        } else if !isEnabledState {
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    private var isEnabledState: Bool = true

    func setEnabled(_ enabled: Bool) {
        isEnabledState = enabled
        alphaValue = enabled ? 1.0 : 0.5
        if !enabled && isRecording {
            isRecording = false
        }
        updateAppearance()
        needsDisplay = true
    }
}
