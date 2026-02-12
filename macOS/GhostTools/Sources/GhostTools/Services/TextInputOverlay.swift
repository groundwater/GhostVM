import AppKit
import QuartzCore

/// Floating pill banner at top-center showing typed text or key combos.
final class TextInputOverlay {
    static let shared = TextInputOverlay()
    private init() {}

    private var pillLayer: CALayer?
    private var fadeWorkItem: DispatchWorkItem?

    /// Show typed text. For `type` actions.
    func showTyping(text: String, rate: Int = 0) {
        DispatchQueue.main.async { [self] in
            showPill(text: text, fadeDelay: 1.0)
        }
    }

    /// Show key combo. For `key` actions. Formats modifiers as Unicode symbols.
    func showKeyCombo(keys: [String], modifiers: [String]) {
        let modSymbols = modifiers.compactMap { modifierSymbol($0) }
        let keyNames = keys.map { keyDisplayName($0) }
        let display = (modSymbols + keyNames).joined()
        DispatchQueue.main.async { [self] in
            showPill(text: display, fadeDelay: 1.5)
        }
    }

    // MARK: - Private

    private func showPill(text: String, fadeDelay: TimeInterval) {
        guard let root = OverlayWindowManager.shared.ensureRootLayer() else { return }

        // Cancel previous fade-out
        fadeWorkItem?.cancel()

        // Remove previous pill
        pillLayer?.removeFromSuperlayer()

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Create text layer to measure size
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.fontSize = 16
        textLayer.font = CTFontCreateWithName("Menlo-Bold" as CFString, 16, nil)
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.alignmentMode = .center
        textLayer.contentsScale = scale
        textLayer.truncationMode = .end

        // Measure text
        let maxWidth: CGFloat = 400
        let textSize = measureText(text, font: CTFontCreateWithName("Menlo-Bold" as CFString, 16, nil), maxWidth: maxWidth)
        let pillWidth = min(textSize.width + 32, maxWidth + 32)
        let pillHeight: CGFloat = 36

        textLayer.bounds = CGRect(x: 0, y: 0, width: pillWidth - 20, height: 20)
        textLayer.position = CGPoint(x: pillWidth / 2, y: pillHeight / 2)

        // Pill background
        let pill = CALayer()
        pill.bounds = CGRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        pill.cornerRadius = pillHeight / 2
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        pill.position = CGPoint(x: root.bounds.width / 2,
                                 y: root.bounds.height - 60)

        pill.addSublayer(textLayer)
        root.addSublayer(pill)
        pillLayer = pill

        // Pop-in animation
        let popIn = CABasicAnimation(keyPath: "transform.scale")
        popIn.fromValue = 0.8
        popIn.toValue = 1.0
        popIn.duration = 0.15
        popIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pill.add(popIn, forKey: "popIn")

        // Schedule fade-out
        let work = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        fadeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeDelay, execute: work)
    }

    private func fadeOut() {
        guard let pill = pillLayer else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        fade.delegate = RemoveLayerDelegate(layer: pill)
        pill.add(fade, forKey: "fadeOut")

        pillLayer = nil
    }

    private func measureText(_ text: String, font: CTFont, maxWidth: CGFloat) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let bounds = attrStr.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin])
        return bounds.size
    }

    private func modifierSymbol(_ name: String) -> String? {
        switch name.lowercased() {
        case "control", "ctrl": return "\u{2303}"   // ⌃
        case "option", "alt":   return "\u{2325}"   // ⌥
        case "shift":           return "\u{21E7}"   // ⇧
        case "command", "cmd":  return "\u{2318}"   // ⌘
        default:                return nil
        }
    }

    private func keyDisplayName(_ key: String) -> String {
        switch key.lowercased() {
        case "return", "enter": return "\u{21A9}"   // ↩
        case "tab":             return "\u{21E5}"   // ⇥
        case "space":           return "\u{2423}"   // ␣
        case "escape", "esc":   return "\u{238B}"   // ⎋
        case "delete", "backspace": return "\u{232B}" // ⌫
        case "left":            return "\u{2190}"   // ←
        case "right":           return "\u{2192}"   // →
        case "up":              return "\u{2191}"   // ↑
        case "down":            return "\u{2193}"   // ↓
        default:                return key.uppercased()
        }
    }
}
