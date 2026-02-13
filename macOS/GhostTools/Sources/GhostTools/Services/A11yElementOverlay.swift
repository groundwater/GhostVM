import AppKit
import QuartzCore

/// Red bounding boxes + numbered badges over interactive accessibility elements.
final class A11yElementOverlay {
    static let shared = A11yElementOverlay()
    private init() {}

    private var containerLayer: CALayer?
    private var fadeWorkItem: DispatchWorkItem?

    /// Show element bounding boxes. Element frames are screen-absolute points.
    /// When `changeAges` is provided, elements are colored by recency tier.
    func showElements(
        _ elements: [AccessibilityService.InteractiveElement],
        changeAges: [Int: Int]? = nil
    ) {
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
                let (strokeColor, fillColor, badgeColor) = ScreenshotService.colorsForAge(
                    changeAges?[elem.id]
                )

                // Elements are already screen-absolute (top-left origin)
                let absRect = CGRect(
                    x: elem.frame.x,
                    y: elem.frame.y,
                    width: elem.frame.width,
                    height: elem.frame.height
                )

                // Convert to view coords (bottom-left origin)
                let viewRect = OverlayWindowManager.shared.screenRectToView(absRect)

                // Bounding box
                let box = CAShapeLayer()
                box.path = CGPath(rect: viewRect, transform: nil)
                box.strokeColor = strokeColor
                box.fillColor = fillColor
                box.lineWidth = 1.5
                container.addSublayer(box)

                // Numbered badge at top-left corner
                let badgeSize: CGFloat = 16
                let badge = CALayer()
                badge.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
                badge.cornerRadius = badgeSize / 2
                badge.backgroundColor = badgeColor
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
