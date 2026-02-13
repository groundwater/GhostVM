import AppKit
import CoreGraphics

/// Service for simulating mouse/pointer events in the guest
final class PointerService {
    static let shared = PointerService()
    private init() {}

    private let eventSource = CGEventSource(stateID: .combinedSessionState)

    enum PointerAction: String, Codable {
        case click
        case doubleClick
        case rightClick
        case middleClick
        case move
        case drag
        case scroll
    }

    enum PointerButton: String, Codable {
        case left
        case right
    }

    enum PointerError: Error {
        case permissionDenied
        case labelNotFound(String)
        case invalidAction
    }

    struct PointerRequest: Codable {
        let action: String
        let x: Double?
        let y: Double?
        let button: String?
        let label: String?
        let endX: Double?
        let endY: Double?
        let deltaX: Double?
        let deltaY: Double?
        let wait: Bool?
    }

    struct PointerDiagnostics {
        let absPoint: CGPoint
        let screenFrame: CGRect?
        let frontApp: String?

        var dict: [String: Any] {
            var d: [String: Any] = [
                "ok": true,
                "absX": absPoint.x,
                "absY": absPoint.y
            ]
            if let sf = screenFrame {
                d["screenWidth"] = sf.width
                d["screenHeight"] = sf.height
            }
            if let fa = frontApp {
                d["frontApp"] = fa
            }
            return d
        }
    }

    /// Send a pointer event. Coordinates are screen-absolute.
    /// Returns diagnostics about the coordinates.
    func sendEvent(action: String, x: Double?, y: Double?, button: String?, label: String?, endX: Double?, endY: Double?, deltaX: Double? = nil, deltaY: Double? = nil) throws -> PointerDiagnostics {
        // Check Accessibility permission — CGEvent.post silently fails without it
        guard AXIsProcessTrusted() else {
            throw PointerError.permissionDenied
        }

        var targetX: Double
        var targetY: Double

        // If label is provided, use accessibility to find the element (returns screen-absolute)
        if let label = label {
            guard let center = try AccessibilityService.shared.findElementCenter(label: label) else {
                throw PointerError.labelNotFound(label)
            }
            targetX = center.x
            targetY = center.y
        } else {
            guard let x = x, let y = y else {
                throw PointerError.invalidAction
            }
            targetX = x
            targetY = y
        }

        let absPoint = CGPoint(x: targetX, y: targetY)
        let screenFrame = NSScreen.main?.frame
        let frontAppName = NSWorkspace.shared.frontmostApplication?.localizedName

        let diag = PointerDiagnostics(
            absPoint: absPoint,
            screenFrame: screenFrame,
            frontApp: frontAppName
        )

        guard let parsedAction = PointerAction(rawValue: action) else {
            throw PointerError.invalidAction
        }

        switch parsedAction {
        case .click:
            postMove(to: absPoint)
            ClickOverlayService.shared.animateClick(at: absPoint)
            usleep(50_000)
            postClick(at: absPoint, button: .left)
        case .doubleClick:
            postMove(to: absPoint)
            ClickOverlayService.shared.animateClick(at: absPoint)
            usleep(50_000)
            postDoubleClick(at: absPoint)
        case .rightClick:
            postMove(to: absPoint)
            ClickOverlayService.shared.animateClick(at: absPoint)
            usleep(50_000)
            postClick(at: absPoint, button: .right)
        case .middleClick:
            postMove(to: absPoint)
            ClickOverlayService.shared.animateClick(at: absPoint)
            usleep(50_000)
            postClick(at: absPoint, button: .center)
        case .move:
            postMove(to: absPoint)
            ClickOverlayService.shared.animateClick(at: absPoint)
        case .drag:
            let dragEnd: CGPoint
            if let ex = endX, let ey = endY {
                dragEnd = CGPoint(x: ex, y: ey)
            } else {
                dragEnd = absPoint
            }
            DragPathOverlay.shared.showDrag(from: absPoint, to: dragEnd)
            postMove(to: absPoint)
            ClickOverlayService.shared.animateClick(at: absPoint)
            usleep(50_000)
            postDrag(from: absPoint, to: dragEnd)
            ClickOverlayService.shared.animateClick(at: dragEnd)
        case .scroll:
            let dx = Int32(deltaX ?? 0)
            let dy = Int32(deltaY ?? 0)
            ScrollDirectionOverlay.shared.showScroll(at: absPoint, deltaX: deltaX ?? 0, deltaY: deltaY ?? 0)
            ClickOverlayService.shared.animateClick(at: absPoint)
            usleep(50_000)
            postScroll(at: absPoint, deltaX: dx, deltaY: dy)
        }

        return diag
    }

    // MARK: - Private

    private func postClick(at point: CGPoint, button: CGMouseButton) {
        let mouseType: CGEventType
        let mouseUpType: CGEventType
        switch button {
        case .left:
            mouseType = .leftMouseDown
            mouseUpType = .leftMouseUp
        case .right:
            mouseType = .rightMouseDown
            mouseUpType = .rightMouseUp
        case .center:
            mouseType = .otherMouseDown
            mouseUpType = .otherMouseUp
        @unknown default:
            mouseType = .leftMouseDown
            mouseUpType = .leftMouseUp
        }

        if let down = CGEvent(mouseEventSource: eventSource, mouseType: mouseType, mouseCursorPosition: point, mouseButton: button) {
            down.post(tap: .cgSessionEventTap)
        }
        usleep(10_000) // 10ms between down and up
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: mouseUpType, mouseCursorPosition: point, mouseButton: button) {
            up.post(tap: .cgSessionEventTap)
        }
    }

    private func postDoubleClick(at point: CGPoint) {
        if let down1 = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down1.setIntegerValueField(.mouseEventClickState, value: 1)
            down1.post(tap: .cgSessionEventTap)
        }
        usleep(10_000)
        if let up1 = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up1.setIntegerValueField(.mouseEventClickState, value: 1)
            up1.post(tap: .cgSessionEventTap)
        }
        usleep(50_000)
        if let down2 = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left) {
            down2.setIntegerValueField(.mouseEventClickState, value: 2)
            down2.post(tap: .cgSessionEventTap)
        }
        usleep(10_000)
        if let up2 = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) {
            up2.setIntegerValueField(.mouseEventClickState, value: 2)
            up2.post(tap: .cgSessionEventTap)
        }
    }

    private func postMove(to point: CGPoint) {
        if let event = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func postScroll(at point: CGPoint, deltaX: Int32, deltaY: Int32) {
        // Click at position first to ensure focus and cursor placement
        postClick(at: point, button: .left)
        usleep(50_000)

        // macOS clamps large scroll deltas in a single event, so break into
        // chunks of at most 3 lines per event for reliable scrolling
        let maxPerEvent: Int32 = 3
        var remainX = deltaX
        var remainY = deltaY

        while remainX != 0 || remainY != 0 {
            let chunkX = max(-maxPerEvent, min(maxPerEvent, remainX))
            let chunkY = max(-maxPerEvent, min(maxPerEvent, remainY))

            // Use CGEvent with scrollWheel type and set fields manually,
            // as scrollWheelEvent2Source may not work in VZ VMs
            if let event = CGEvent(source: eventSource) {
                event.type = .scrollWheel
                event.location = point
                event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(chunkY))
                if chunkX != 0 {
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(chunkX))
                }
                event.post(tap: .cgSessionEventTap)
            }

            remainX -= chunkX
            remainY -= chunkY

            if remainX != 0 || remainY != 0 {
                usleep(16_000) // ~60fps pacing
            }
        }
    }

    private func postDrag(from start: CGPoint, to end: CGPoint) {
        // Mouse down at start
        if let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left) {
            down.post(tap: .cgSessionEventTap)
        }
        usleep(10_000)

        // Interpolate move events
        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = Double(start.x) + (Double(end.x) - Double(start.x)) * t
            let y = Double(start.y) + (Double(end.y) - Double(start.y)) * t
            let point = CGPoint(x: x, y: y)
            if let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left) {
                drag.post(tap: .cgSessionEventTap)
            }
            usleep(5_000)
        }

        // Mouse up at end
        if let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) {
            up.post(tap: .cgSessionEventTap)
        }
    }
}
