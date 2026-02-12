import AppKit
import QuartzCore

/// Spinning ring overlay in bottom-right corner during stability waits.
final class WaitIndicatorOverlay {
    static let shared = WaitIndicatorOverlay()
    private init() {}

    private var containerLayer: CALayer?
    private var isVisible = false

    /// Show the wait indicator. Dispatches to main. Idempotent.
    func show() {
        DispatchQueue.main.async { [self] in
            guard !isVisible else { return }
            guard let root = OverlayWindowManager.shared.ensureRootLayer() else { return }
            isVisible = true

            let container = CALayer()
            container.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)

            // Position in bottom-right corner
            let margin: CGFloat = 30
            container.position = CGPoint(x: root.bounds.width - margin - 30,
                                          y: margin + 30)

            // Spinning arc
            let arc = CAShapeLayer()
            arc.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            arc.position = CGPoint(x: 30, y: 35)
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: 15, y: 15), radius: 12,
                        startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
            arc.path = path
            arc.strokeColor = NSColor.systemGray.withAlphaComponent(0.8).cgColor
            arc.fillColor = nil
            arc.lineWidth = 3
            arc.lineCap = .round
            container.addSublayer(arc)

            // Spin animation
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * 2
            spin.duration = 1.0
            spin.repeatCount = .infinity
            spin.timingFunction = CAMediaTimingFunction(name: .linear)
            arc.add(spin, forKey: "spin")

            // "waiting..." label
            let label = CATextLayer()
            label.string = "waiting..."
            label.fontSize = 10
            label.font = CTFontCreateWithName("Helvetica" as CFString, 10, nil)
            label.foregroundColor = NSColor.white.withAlphaComponent(0.7).cgColor
            label.alignmentMode = .center
            label.bounds = CGRect(x: 0, y: 0, width: 60, height: 14)
            label.position = CGPoint(x: 30, y: 10)
            label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            container.addSublayer(label)

            // Fade in
            container.opacity = 0
            root.addSublayer(container)
            containerLayer = container

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = 0.2
            container.opacity = 1
            container.add(fadeIn, forKey: "fadeIn")
        }
    }

    /// Hide the wait indicator. Dispatches to main. Idempotent.
    func hide() {
        DispatchQueue.main.async { [self] in
            guard isVisible, let container = containerLayer else { return }
            isVisible = false

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = 0.2
            fadeOut.isRemovedOnCompletion = false
            fadeOut.fillMode = .forwards
            fadeOut.delegate = RemoveLayerDelegate(layer: container)
            container.add(fadeOut, forKey: "fadeOut")

            containerLayer = nil
        }
    }
}
