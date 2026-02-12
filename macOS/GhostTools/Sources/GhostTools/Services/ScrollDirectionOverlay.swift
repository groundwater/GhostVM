import AppKit
import QuartzCore

/// Orange chevron arrows showing scroll direction at scroll position.
final class ScrollDirectionOverlay {
    static let shared = ScrollDirectionOverlay()
    private init() {}

    private var containerLayer: CALayer?
    private var fadeWorkItem: DispatchWorkItem?

    /// Show scroll direction arrows. Position is absolute screen coords (top-left origin).
    func showScroll(at point: CGPoint, deltaX: Double, deltaY: Double) {
        DispatchQueue.main.async { [self] in
            guard let root = OverlayWindowManager.shared.ensureRootLayer() else { return }

            // Cancel previous fade
            fadeWorkItem?.cancel()
            containerLayer?.removeFromSuperlayer()

            let viewPoint = OverlayWindowManager.shared.screenToView(point)

            let container = CALayer()
            container.frame = root.bounds

            // Determine direction and magnitude
            // Note: negative deltaY = scroll up (content moves down)
            if deltaY != 0 {
                let isUp = deltaY < 0
                let count = min(Int(abs(deltaY)), 5)
                for i in 0..<count {
                    let offset = CGFloat(i) * 18
                    let y = isUp ? viewPoint.y + 20 + offset : viewPoint.y - 20 - offset
                    let chevron = makeChevron(at: CGPoint(x: viewPoint.x, y: y), pointingUp: isUp)
                    addPopIn(to: chevron, delay: Double(i) * 0.05)
                    container.addSublayer(chevron)
                }
            }

            if deltaX != 0 {
                let isLeft = deltaX < 0
                let count = min(Int(abs(deltaX)), 5)
                for i in 0..<count {
                    let offset = CGFloat(i) * 18
                    let x = isLeft ? viewPoint.x - 20 - offset : viewPoint.x + 20 + offset
                    let chevron = makeChevron(at: CGPoint(x: x, y: viewPoint.y), pointingLeft: isLeft)
                    addPopIn(to: chevron, delay: Double(i) * 0.05)
                    container.addSublayer(chevron)
                }
            }

            root.addSublayer(container)
            containerLayer = container

            // Schedule fade-out
            let work = DispatchWorkItem { [weak self] in
                self?.fadeOut()
            }
            fadeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    // MARK: - Private

    private func makeChevron(at point: CGPoint, pointingUp: Bool) -> CAShapeLayer {
        let size: CGFloat = 14
        let shape = CAShapeLayer()
        shape.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        shape.position = point

        let path = CGMutablePath()
        if pointingUp {
            path.move(to: CGPoint(x: 2, y: 4))
            path.addLine(to: CGPoint(x: size / 2, y: size - 2))
            path.addLine(to: CGPoint(x: size - 2, y: 4))
        } else {
            path.move(to: CGPoint(x: 2, y: size - 4))
            path.addLine(to: CGPoint(x: size / 2, y: 2))
            path.addLine(to: CGPoint(x: size - 2, y: size - 4))
        }

        shape.path = path
        shape.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        shape.fillColor = nil
        shape.lineWidth = 2.5
        shape.lineCap = .round
        shape.lineJoin = .round
        return shape
    }

    private func makeChevron(at point: CGPoint, pointingLeft: Bool) -> CAShapeLayer {
        let size: CGFloat = 14
        let shape = CAShapeLayer()
        shape.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        shape.position = point

        let path = CGMutablePath()
        if pointingLeft {
            path.move(to: CGPoint(x: size - 4, y: 2))
            path.addLine(to: CGPoint(x: 2, y: size / 2))
            path.addLine(to: CGPoint(x: size - 4, y: size - 2))
        } else {
            path.move(to: CGPoint(x: 4, y: 2))
            path.addLine(to: CGPoint(x: size - 2, y: size / 2))
            path.addLine(to: CGPoint(x: 4, y: size - 2))
        }

        shape.path = path
        shape.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        shape.fillColor = nil
        shape.lineWidth = 2.5
        shape.lineCap = .round
        shape.lineJoin = .round
        return shape
    }

    private func addPopIn(to layer: CALayer, delay: TimeInterval) {
        let popIn = CABasicAnimation(keyPath: "transform.scale")
        popIn.fromValue = 0.3
        popIn.toValue = 1.0
        popIn.duration = 0.2
        popIn.beginTime = CACurrentMediaTime() + delay
        popIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        popIn.fillMode = .backwards
        layer.add(popIn, forKey: "popIn")
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
