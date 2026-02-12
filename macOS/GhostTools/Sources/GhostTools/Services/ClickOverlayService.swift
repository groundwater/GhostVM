import AppKit
import QuartzCore

/// Persistent glowing cursor overlay for visualizing automated pointer events.
/// The cursor stays visible, moves to each new click position, and pulses on click.
final class ClickOverlayService {
    static let shared = ClickOverlayService()
    private init() {}

    private var cursorLayer: CALayer?       // persistent glowing dot
    private var glowLayer: CALayer?         // outer glow behind cursor
    private let cursorSize: CGFloat = 16
    private let glowSize: CGFloat = 32

    /// Animate the cursor to the given point and pulse. Coordinates are absolute screen (top-left origin).
    func animateClick(at point: CGPoint) {
        DispatchQueue.main.async { [self] in
            guard let root = OverlayWindowManager.shared.ensureRootLayer() else { return }
            let viewPoint = OverlayWindowManager.shared.screenToView(point)

            if let cursor = cursorLayer {
                // Animate move from current position to new position
                let from = cursor.position
                animateMove(from: from, to: viewPoint)
            } else {
                // First click — create the cursor at this position
                createCursorLayers(in: root, at: viewPoint)
            }

            // Pulse ripple at click point
            animatePulse(in: root, at: viewPoint)
        }
    }

    // MARK: - Persistent Cursor

    private func createCursorLayers(in root: CALayer, at point: CGPoint) {
        // Outer glow
        let glow = CALayer()
        glow.bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        glow.cornerRadius = glowSize / 2
        glow.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.2).cgColor
        glow.position = point
        glow.shadowColor = NSColor.systemBlue.cgColor
        glow.shadowRadius = 8
        glow.shadowOpacity = 0.6
        glow.shadowOffset = .zero
        root.addSublayer(glow)
        glowLayer = glow

        // Inner cursor dot
        let cursor = CALayer()
        cursor.bounds = CGRect(x: 0, y: 0, width: cursorSize, height: cursorSize)
        cursor.cornerRadius = cursorSize / 2
        cursor.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.7).cgColor
        cursor.borderWidth = 2
        cursor.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        cursor.position = point
        cursor.shadowColor = NSColor.systemBlue.cgColor
        cursor.shadowRadius = 4
        cursor.shadowOpacity = 0.8
        cursor.shadowOffset = .zero
        root.addSublayer(cursor)
        cursorLayer = cursor

        // Gentle breathing animation on the glow
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1.0
        breathe.toValue = 1.3
        breathe.duration = 1.2
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(breathe, forKey: "breathe")
    }

    // MARK: - Move Animation

    private func animateMove(from: CGPoint, to: CGPoint) {
        guard let cursor = cursorLayer, let glow = glowLayer else { return }

        // Ensure cursor is fully visible (in case we were fading out)
        cursor.removeAnimation(forKey: "fadeOut")
        glow.removeAnimation(forKey: "fadeOut")
        cursor.opacity = 1.0
        glow.opacity = 1.0

        let duration: CFTimeInterval = 0.2

        // Animate cursor dot
        let moveC = CABasicAnimation(keyPath: "position")
        moveC.fromValue = NSValue(point: NSPoint(x: from.x, y: from.y))
        moveC.toValue = NSValue(point: NSPoint(x: to.x, y: to.y))
        moveC.duration = duration
        moveC.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        cursor.position = to
        cursor.add(moveC, forKey: "move")

        // Animate glow
        let moveG = CABasicAnimation(keyPath: "position")
        moveG.fromValue = NSValue(point: NSPoint(x: from.x, y: from.y))
        moveG.toValue = NSValue(point: NSPoint(x: to.x, y: to.y))
        moveG.duration = duration
        moveG.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.position = to
        glow.add(moveG, forKey: "move")
    }

    // MARK: - Pulse Animation

    private func animatePulse(in root: CALayer, at point: CGPoint) {
        let pulse = CALayer()
        pulse.bounds = CGRect(x: 0, y: 0, width: cursorSize, height: cursorSize)
        pulse.cornerRadius = cursorSize / 2
        pulse.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.3).cgColor
        pulse.borderWidth = 1.5
        pulse.borderColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        pulse.position = point
        root.addSublayer(pulse)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 4.0
        scale.duration = 0.4
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0.0
        fade.duration = 0.4
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.4
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        group.delegate = RemoveLayerDelegate(layer: pulse)

        pulse.add(group, forKey: "pulse")
    }

}
