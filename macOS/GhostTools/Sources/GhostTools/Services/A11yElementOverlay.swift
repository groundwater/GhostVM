import AppKit
import QuartzCore

/// Red bounding boxes + numbered badges over interactive accessibility elements.
final class A11yElementOverlay {
    static let shared = A11yElementOverlay()
    private init() {}

    private var containerLayer: CALayer?
    private var fadeWorkItem: DispatchWorkItem?

    /// Show element bounding boxes. Element frames are window-relative points;
    /// windowFrame provides the window's absolute screen position for conversion.
    func showElements(_ elements: [AccessibilityService.InteractiveElement], windowFrame: AccessibilityService.AXFrame) {
        DispatchQueue.main.async { [self] in
            guard let root = OverlayWindowManager.shared.ensureRootLayer() else { return }
            guard !elements.isEmpty else { return }

            // Cancel previous fade
            fadeWorkItem?.cancel()
            containerLayer?.removeFromSuperlayer()

            let container = CALayer()
            container.frame = root.bounds
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0

            for elem in elements {
                // Convert window-relative to absolute screen coords (top-left origin)
                let absRect = CGRect(
                    x: Double(windowFrame.x) + elem.frame.x,
                    y: Double(windowFrame.y) + elem.frame.y,
                    width: elem.frame.width,
                    height: elem.frame.height
                )

                // Convert to view coords (bottom-left origin)
                let viewRect = OverlayWindowManager.shared.screenRectToView(absRect)

                // Red bounding box
                let box = CAShapeLayer()
                box.path = CGPath(rect: viewRect, transform: nil)
                box.strokeColor = CGColor(red: 1, green: 0, blue: 0, alpha: 0.8)
                box.fillColor = CGColor(red: 1, green: 0, blue: 0, alpha: 0.05)
                box.lineWidth = 1.5
                container.addSublayer(box)

                // Numbered badge at top-left corner
                let badgeSize: CGFloat = 16
                let badge = CALayer()
                badge.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
                badge.cornerRadius = badgeSize / 2
                badge.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 0.85)
                badge.position = CGPoint(x: viewRect.minX + badgeSize / 2,
                                          y: viewRect.maxY - badgeSize / 2)
                container.addSublayer(badge)

                // Number text
                let numLayer = CATextLayer()
                numLayer.string = "\(elem.id)"
                numLayer.fontSize = 10
                numLayer.font = CTFontCreateWithName("Helvetica-Bold" as CFString, 10, nil)
                numLayer.foregroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                numLayer.alignmentMode = .center
                numLayer.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: 13)
                numLayer.position = CGPoint(x: viewRect.minX + badgeSize / 2,
                                             y: viewRect.maxY - badgeSize / 2)
                numLayer.contentsScale = scale
                container.addSublayer(numLayer)
            }

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

            // Schedule fade-out after 3s
            let work = DispatchWorkItem { [weak self] in
                self?.fadeOut()
            }
            fadeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
    }

    // MARK: - Private

    private func fadeOut() {
        guard let container = containerLayer else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.5
        fade.isRemovedOnCompletion = false
        fade.fillMode = .forwards
        fade.delegate = RemoveLayerDelegate(layer: container)
        container.add(fade, forKey: "fadeOut")

        containerLayer = nil
    }
}
