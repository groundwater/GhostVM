import AppKit
import QuartzCore

/// Dashed line trail overlay from drag start to end with colored dots.
final class DragPathOverlay {
    static let shared = DragPathOverlay()
    private init() {}

    private var containerLayer: CALayer?
    private var fadeWorkItem: DispatchWorkItem?

    /// Show a drag path. Both points are absolute screen coords (top-left origin).
    func showDrag(from start: CGPoint, to end: CGPoint) {
        DispatchQueue.main.async { [self] in
            guard let root = OverlayWindowManager.shared.ensureRootLayer() else { return }

            // Cancel previous fade
            fadeWorkItem?.cancel()
            containerLayer?.removeFromSuperlayer()

            let viewStart = OverlayWindowManager.shared.screenToView(start)
            let viewEnd = OverlayWindowManager.shared.screenToView(end)

            let container = CALayer()
            container.frame = root.bounds

            // Dashed line
            let line = CAShapeLayer()
            line.frame = root.bounds
            let path = CGMutablePath()
            path.move(to: viewStart)
            path.addLine(to: viewEnd)
            line.path = path
            line.strokeColor = NSColor.systemBlue.withAlphaComponent(0.7).cgColor
            line.fillColor = nil
            line.lineWidth = 2.5
            line.lineDashPattern = [8, 4]
            line.lineCap = .round
            container.addSublayer(line)

            // Stroke-draw animation
            let drawAnim = CABasicAnimation(keyPath: "strokeEnd")
            drawAnim.fromValue = 0
            drawAnim.toValue = 1
            drawAnim.duration = 0.3
            drawAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            line.add(drawAnim, forKey: "draw")

            // Green dot at start
            let startDot = makeDot(at: viewStart, color: NSColor.systemGreen)
            container.addSublayer(startDot)

            // Blue dot at end
            let endDot = makeDot(at: viewEnd, color: NSColor.systemBlue)
            container.addSublayer(endDot)

            root.addSublayer(container)
            containerLayer = container

            // Schedule fade-out
            let work = DispatchWorkItem { [weak self] in
                self?.fadeOut()
            }
            fadeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    // MARK: - Private

    private func makeDot(at point: CGPoint, color: NSColor) -> CALayer {
        let size: CGFloat = 10
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.cornerRadius = size / 2
        dot.backgroundColor = color.withAlphaComponent(0.8).cgColor
        dot.borderWidth = 1.5
        dot.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.position = point
        return dot
    }

    private func fadeOut() {
        guard let container = containerLayer else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        fade.delegate = RemoveLayerDelegate(layer: container)
        container.add(fade, forKey: "fadeOut")

        containerLayer = nil
    }
}
