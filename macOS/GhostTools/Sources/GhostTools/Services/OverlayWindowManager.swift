import AppKit
import QuartzCore

/// Shared full-screen transparent NSWindow for all overlay renderers.
/// Each renderer adds/removes its own CALayer sublayers on the shared root layer.
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()
    private init() {}

    private var overlayWindow: NSWindow?

    /// Ensure the overlay window exists and return the root CALayer to draw into.
    func ensureRootLayer() -> CALayer? {
        let window = ensureOverlayWindow()
        return window.contentView?.layer
    }

    /// Convert CGEvent absolute coords (top-left origin) to CALayer/NSView coords (bottom-left origin).
    func screenToView(_ point: CGPoint) -> CGPoint {
        guard let f = overlayWindow?.frame ?? NSScreen.main?.frame else {
            return point
        }
        return CGPoint(x: point.x - f.origin.x,
                       y: f.height - (point.y - f.origin.y))
    }

    /// Convert a screen-coordinate rect (top-left origin) to view-coordinate rect (bottom-left origin).
    func screenRectToView(_ rect: CGRect) -> CGRect {
        guard let f = overlayWindow?.frame ?? NSScreen.main?.frame else {
            return rect
        }
        let flippedY = f.height - (rect.origin.y - f.origin.y) - rect.height
        return CGRect(x: rect.origin.x - f.origin.x,
                      y: flippedY,
                      width: rect.width,
                      height: rect.height)
    }

    // MARK: - Window

    private func ensureOverlayWindow() -> NSWindow {
        if let window = overlayWindow {
            if let screen = NSScreen.main {
                window.setFrame(screen.frame, display: false)
            }
            window.orderFrontRegardless()
            return window
        }

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = NSView(frame: screenFrame)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = view

        window.orderFrontRegardless()
        overlayWindow = window
        return window
    }
}

/// Removes the CALayer from its parent when the animation finishes.
/// Used by multiple overlay renderers for one-shot animations.
final class RemoveLayerDelegate: NSObject, CAAnimationDelegate {
    private weak var layer: CALayer?

    init(layer: CALayer) {
        self.layer = layer
        super.init()
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        layer?.removeFromSuperlayer()
    }
}
