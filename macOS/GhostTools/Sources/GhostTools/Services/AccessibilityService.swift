import AppKit
import ApplicationServices

/// Service for reading the accessibility tree of the focused application
final class AccessibilityService {
    static let shared = AccessibilityService()
    private init() {}

    struct AXNode: Codable {
        let role: String?
        let title: String?
        let label: String?
        let value: String?
        let frame: AXFrame?
        let children: [AXNode]?
    }

    struct AXFrame: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct AXTreeResponse: Codable {
        let app: String
        let bundleId: String
        let pid: Int32
        let window: String?
        let frame: AXFrame?
        let tree: AXNode?
    }

    struct ActionResult: Codable {
        let ok: Bool
        let message: String?
    }

    /// Lightweight snapshot for detecting a11y tree changes
    struct A11ySnapshot {
        let elementCount: Int
        let windowTitle: String?
        let hasWebAreaWithChildren: Bool
        let timestamp: Date

        func hasLargeChangeTo(_ other: A11ySnapshot) -> Bool {
            // Element count changed by 5+ OR
            // Web area with children appeared OR
            // Window title changed (different app/page)
            let countDelta = abs(other.elementCount - self.elementCount)
            return countDelta >= 5
                || (other.hasWebAreaWithChildren && !self.hasWebAreaWithChildren)
                || other.windowTitle != self.windowTitle
        }

        func hasAnyChangeTo(_ other: A11ySnapshot) -> Bool {
            return other.elementCount != self.elementCount
                || other.windowTitle != self.windowTitle
                || other.hasWebAreaWithChildren != self.hasWebAreaWithChildren
        }
    }

    /// Expected type of change after an action
    enum ExpectChange {
        case navigation  // Large change + stabilization (launch, navigate URL, etc.)
        case update      // Any change (type text, click button)
        case none        // No wait (queries, mouse move)
    }

    /// Specifies which process(es) to target for accessibility queries/actions.
    enum AXTarget: Equatable {
        case front
        case visible
        case all
        case pid(pid_t)
        case app(String)

        init?(queryValue: String) {
            switch queryValue {
            case "front": self = .front
            case "visible": self = .visible
            case "all": self = .all
            default:
                if queryValue.hasPrefix("pid:"), let p = Int32(queryValue.dropFirst(4)) {
                    self = .pid(p)
                } else if queryValue.hasPrefix("app:") {
                    self = .app(String(queryValue.dropFirst(4)))
                } else {
                    return nil
                }
            }
        }

        var isMulti: Bool { self == .visible || self == .all }
    }

    enum AXServiceError: Error, LocalizedError {
        case permissionDenied
        case noFocusedApp
        case noWindow
        case elementNotFound(String)
        case actionFailed(String)
        case menuNotFound(String)
        case appNotFound(String)
        case multiTargetNotAllowed

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Accessibility permission denied"
            case .noFocusedApp: return "No focused application"
            case .noWindow: return "No focused window"
            case .elementNotFound(let label): return "Element not found: \(label)"
            case .actionFailed(let msg): return "Action failed: \(msg)"
            case .menuNotFound(let path): return "Menu item not found: \(path)"
            case .appNotFound(let id): return "Application not found: \(id)"
            case .multiTargetNotAllowed: return "Multi-target (--all/--visible) not allowed for actions"
            }
        }
    }

    // MARK: - Target Resolution

    /// Resolve an AXTarget to a list of (pid, app) pairs.
    private func resolveTarget(_ target: AXTarget) throws -> [(pid: pid_t, app: NSRunningApplication?)] {
        switch target {
        case .front:
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                throw AXServiceError.noFocusedApp
            }
            return [(frontApp.processIdentifier, frontApp)]
        case .pid(let pid):
            let app = NSRunningApplication(processIdentifier: pid)
            return [(pid, app)]
        case .app(let bundleId):
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            guard !apps.isEmpty else {
                throw AXServiceError.appNotFound(bundleId)
            }
            return apps.map { ($0.processIdentifier, $0) }
        case .visible:
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                throw AXServiceError.noFocusedApp
            }
            let frontPID = frontApp.processIdentifier

            guard let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] else {
                return [(frontPID, frontApp)]
            }

            var seen = Set<pid_t>()
            var results: [(pid: pid_t, app: NSRunningApplication?)] = []
            var foundFront = false

            for info in windowList {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }

                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                // Skip high-layer system chrome (menu bar extras, notification center, etc.)
                // but keep layers 0-24 which include normal windows and system dialogs (TCC, auth)
                if layer >= 25 && pid != frontPID { continue }

                if seen.insert(pid).inserted {
                    let app = NSRunningApplication(processIdentifier: pid)
                    results.append((pid, app))
                }

                if pid == frontPID { foundFront = true; break }
            }

            // If frontmost app wasn't in the window list (rare), add it explicitly
            if !foundFront {
                if seen.insert(frontPID).inserted {
                    results.append((frontPID, frontApp))
                }
            }

            return results
        case .all:
            return NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { ($0.processIdentifier, $0) }
        }
    }

    /// Get the accessibility tree. Returns one response per resolved target.
    func getTree(maxDepth: Int = 5, target: AXTarget = .front) throws -> [AXTreeResponse] {
        guard AXIsProcessTrusted() else {
            throw AXServiceError.permissionDenied
        }

        let targets = try resolveTarget(target)
        var results: [AXTreeResponse] = []

        for (pid, app) in targets {
            let appElement = AXUIElementCreateApplication(pid)

            var windowValue: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)

            if windowResult == .success, let windowElement = windowValue {
                results.append(buildResponse(pid: pid, app: app, windowElement: windowElement as! AXUIElement, maxDepth: maxDepth))
            } else {
                let mainResult = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowValue)
                if mainResult == .success, let mainWindow = windowValue {
                    results.append(buildResponse(pid: pid, app: app, windowElement: mainWindow as! AXUIElement, maxDepth: maxDepth))
                } else if !target.isMulti {
                    // For single-target, no window is an error
                    throw AXServiceError.noWindow
                } else {
                    // For multi-target, include app element even if no window
                    results.append(buildResponse(pid: pid, app: app, windowElement: appElement, maxDepth: maxDepth))
                }
            }
        }

        return results
    }

    /// Find an element by its accessibility label and return its center point (screen-absolute)
    func findElementCenter(label: String, target: AXTarget = .front) throws -> (x: Double, y: Double)? {
        guard AXIsProcessTrusted() else {
            throw AXServiceError.permissionDenied
        }

        guard !target.isMulti else {
            throw AXServiceError.multiTargetNotAllowed
        }

        let targets = try resolveTarget(target)
        guard let (pid, _) = targets.first else {
            throw AXServiceError.noFocusedApp
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard windowResult == .success, let windowElement = windowValue else {
            throw AXServiceError.noWindow
        }

        var foundElement: AXUIElement? = findElement(in: windowElement as! AXUIElement, label: label, depth: 0, maxDepth: 10)

        // If not found in window, also search app-level elements (catches popup menus)
        if foundElement == nil {
            foundElement = findElement(in: appElement, label: label, depth: 0, maxDepth: 10)
        }

        if let element = foundElement, let frame = getFrame(element) {
            let centerX = frame.x + frame.width / 2.0
            let centerY = frame.y + frame.height / 2.0
            return (centerX, centerY)
        }

        return nil
    }

    // MARK: - Private

    private func buildResponse(pid: pid_t, app: NSRunningApplication?, windowElement: AXUIElement, maxDepth: Int) -> AXTreeResponse {
        let windowTitle = getStringAttribute(windowElement, kAXTitleAttribute)
        let windowFrame = getFrame(windowElement)

        let tree = buildNode(element: windowElement, depth: 0, maxDepth: maxDepth)

        return AXTreeResponse(
            app: app?.localizedName ?? app?.bundleIdentifier ?? "PID \(pid)",
            bundleId: app?.bundleIdentifier ?? "",
            pid: pid,
            window: windowTitle,
            frame: windowFrame,
            tree: tree
        )
    }

    private func buildNode(element: AXUIElement, depth: Int, maxDepth: Int) -> AXNode {
        let role = getStringAttribute(element, kAXRoleAttribute)
        let title = getStringAttribute(element, kAXTitleAttribute)
        let label = getStringAttribute(element, kAXDescriptionAttribute)
        let value = getValueString(element)
        let frame = getFrame(element)

        var children: [AXNode]? = nil
        if depth < maxDepth {
            var childrenValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
            if result == .success, let childElements = childrenValue as? [AXUIElement] {
                children = childElements.map {
                    buildNode(element: $0, depth: depth + 1, maxDepth: maxDepth)
                }
                if children?.isEmpty == true { children = nil }
            }
        }

        return AXNode(role: role, title: title, label: label, value: value, frame: frame, children: children)
    }

    private func findElement(in element: AXUIElement, label: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        // Check this element
        let title = getStringAttribute(element, kAXTitleAttribute)
        let desc = getStringAttribute(element, kAXDescriptionAttribute)
        let value = getValueString(element)

        if title == label || desc == label || value == label {
            return element
        }

        guard depth < maxDepth else { return nil }

        // Search children
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if result == .success, let children = childrenValue as? [AXUIElement] {
            for child in children {
                if let found = findElement(in: child, label: label, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }

        return nil
    }

    private func getStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let str = value as? String, !str.isEmpty else { return nil }
        return str
    }

    private func getValueString(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success else { return nil }
        if let str = value as? String, !str.isEmpty { return str }
        if let num = value as? NSNumber { return num.stringValue }
        return nil
    }

    private func getFrame(_ element: AXUIElement) -> AXFrame? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return AXFrame(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height))
    }

    private func getWindowTitle(target: AXTarget) -> String? {
        guard case .front = target,
              let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowValue: CFTypeRef?

        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success
            || AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowValue) == .success {
            let windowElement = windowValue as! AXUIElement
            return getStringAttribute(windowElement, kAXTitleAttribute)
        }

        return nil
    }

    private func treeHasWebAreaWithChildren(_ node: AXNode?) -> Bool {
        guard let node = node else { return false }

        if node.role == "AXWebArea",
           let children = node.children,
           !children.isEmpty {
            return true
        }

        if let children = node.children {
            for child in children {
                if treeHasWebAreaWithChildren(child) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Interactive Elements

    /// Roles considered interactive (buttons, fields, links, etc.)
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXPopUpButton", "AXMenuButton", "AXComboBox",
        "AXTextField", "AXTextArea", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXLink",
        "AXSlider", "AXMenuItem", "AXTab"
    ]

    struct InteractiveElement {
        let id: Int
        let role: String
        let label: String?
        let title: String?
        let value: String?
        let frame: AXFrame  // screen-absolute, in points
    }

    struct ScrollState: Codable {
        let canScrollUp: Bool
        let canScrollDown: Bool
        let canScrollLeft: Bool
        let canScrollRight: Bool
    }

    /// Detect scroll state of the frontmost scroll area in a window.
    func detectScrollState(window: AXUIElement) -> ScrollState {
        guard let scrollArea = findScrollArea(in: window, depth: 0, maxDepth: 5) else {
            return ScrollState(canScrollUp: false, canScrollDown: false, canScrollLeft: false, canScrollRight: false)
        }

        var canScrollUp = false
        var canScrollDown = false
        var canScrollLeft = false
        var canScrollRight = false

        // Check vertical scroll bar
        var vScrollValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(scrollArea, "AXVerticalScrollBar" as CFString, &vScrollValue) == .success,
           let vScrollBar = vScrollValue {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(vScrollBar as! AXUIElement, kAXValueAttribute as CFString, &val) == .success,
               let num = val as? NSNumber {
                let v = num.doubleValue
                canScrollUp = v > 0.001
                canScrollDown = v < 0.999
            }
        }

        // Check horizontal scroll bar
        var hScrollValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(scrollArea, "AXHorizontalScrollBar" as CFString, &hScrollValue) == .success,
           let hScrollBar = hScrollValue {
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(hScrollBar as! AXUIElement, kAXValueAttribute as CFString, &val) == .success,
               let num = val as? NSNumber {
                let v = num.doubleValue
                canScrollLeft = v > 0.001
                canScrollRight = v < 0.999
            }
        }

        return ScrollState(canScrollUp: canScrollUp, canScrollDown: canScrollDown, canScrollLeft: canScrollLeft, canScrollRight: canScrollRight)
    }

    private func findScrollArea(in element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
        let role = getStringAttribute(element, kAXRoleAttribute)
        if role == "AXScrollArea" { return element }
        guard depth < maxDepth else { return nil }

        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if result == .success, let children = childrenValue as? [AXUIElement] {
            for child in children {
                if let found = findScrollArea(in: child, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }
        return nil
    }

    /// Returns a flat list of interactive elements from visible windows.
    /// Frames are screen-absolute in points.
    struct InteractiveElementsResult {
        let elements: [InteractiveElement]
        let scrollState: ScrollState
    }

    func getInteractiveElements(maxDepth: Int = 15, target: AXTarget = .visible) -> InteractiveElementsResult {
        let noResult = InteractiveElementsResult(
            elements: [],
            scrollState: ScrollState(canScrollUp: false, canScrollDown: false, canScrollLeft: false, canScrollRight: false)
        )
        guard AXIsProcessTrusted() else {
            return noResult
        }

        // Get screen bounds for clipping
        let screenBounds: (width: Double, height: Double)?
        if let screen = NSScreen.main {
            screenBounds = (width: Double(screen.frame.width), height: Double(screen.frame.height))
        } else {
            screenBounds = nil
        }

        var elements: [InteractiveElement] = []
        var nextId = 1

        // Resolve target PIDs
        let targets: [(pid: pid_t, app: NSRunningApplication?)]
        do {
            targets = try resolveTarget(target)
        } catch {
            return noResult
        }

        // Collect elements from each target's focused/main window
        for (pid, _) in targets {
            let appElement = AXUIElementCreateApplication(pid)

            var windowValue: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
            if windowResult != .success {
                let mainResult = AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &windowValue)
                if mainResult != .success || windowValue == nil {
                    continue
                }
            }

            let windowElement = windowValue as! AXUIElement
            collectInteractiveElements(
                element: windowElement,
                depth: 0,
                maxDepth: maxDepth,
                screenBounds: screenBounds,
                clipRect: nil,
                elements: &elements,
                nextId: &nextId
            )
        }

        // Scroll state always queries frontmost window
        let scrollState: ScrollState
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            let frontAppElement = AXUIElementCreateApplication(frontApp.processIdentifier)
            var frontWindowValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(frontAppElement, kAXFocusedWindowAttribute as CFString, &frontWindowValue) == .success
                || AXUIElementCopyAttributeValue(frontAppElement, kAXMainWindowAttribute as CFString, &frontWindowValue) == .success,
               let fw = frontWindowValue {
                scrollState = detectScrollState(window: fw as! AXUIElement)
            } else {
                scrollState = ScrollState(canScrollUp: false, canScrollDown: false, canScrollLeft: false, canScrollRight: false)
            }
        } else {
            scrollState = ScrollState(canScrollUp: false, canScrollDown: false, canScrollLeft: false, canScrollRight: false)
        }

        return InteractiveElementsResult(elements: elements, scrollState: scrollState)
    }

    private func collectInteractiveElements(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        screenBounds: (width: Double, height: Double)?,
        clipRect: AXFrame?,
        elements: inout [InteractiveElement],
        nextId: inout Int
    ) {
        let role = getStringAttribute(element, kAXRoleAttribute)

        // Narrow clip rect when entering a scroll area
        var childClipRect = clipRect
        if role == "AXScrollArea", let frame = getFrame(element) {
            childClipRect = intersectFrames(clipRect, frame)
        }

        if let role = role, AccessibilityService.interactiveRoles.contains(role) {
            if let frame = getFrame(element) {
                // Skip zero-size elements
                guard frame.width > 0 && frame.height > 0 else {
                    return collectInteractiveElementsChildren(
                        element: element, depth: depth, maxDepth: maxDepth,
                        screenBounds: screenBounds, clipRect: childClipRect,
                        elements: &elements, nextId: &nextId
                    )
                }
                // Skip elements entirely outside the visible screen area
                if let sb = screenBounds {
                    let outOfBounds =
                        frame.x + frame.width < 0 ||
                        frame.y + frame.height < 0 ||
                        frame.x > sb.width ||
                        frame.y > sb.height
                    if outOfBounds {
                        return collectInteractiveElementsChildren(
                            element: element, depth: depth, maxDepth: maxDepth,
                            screenBounds: screenBounds, clipRect: childClipRect,
                            elements: &elements, nextId: &nextId
                        )
                    }
                }
                // Skip elements outside the scroll viewport
                if !frameIntersectsClip(frame, clipRect: clipRect) {
                    return collectInteractiveElementsChildren(
                        element: element, depth: depth, maxDepth: maxDepth,
                        screenBounds: screenBounds, clipRect: childClipRect,
                        elements: &elements, nextId: &nextId
                    )
                }
                let elem = InteractiveElement(
                    id: nextId,
                    role: role,
                    label: getStringAttribute(element, kAXDescriptionAttribute),
                    title: getStringAttribute(element, kAXTitleAttribute),
                    value: getValueString(element),
                    frame: frame
                )
                elements.append(elem)
                nextId += 1
            }
        }

        collectInteractiveElementsChildren(
            element: element, depth: depth, maxDepth: maxDepth,
            screenBounds: screenBounds, clipRect: childClipRect,
            elements: &elements, nextId: &nextId
        )
    }

    private func collectInteractiveElementsChildren(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        screenBounds: (width: Double, height: Double)?,
        clipRect: AXFrame?,
        elements: inout [InteractiveElement],
        nextId: inout Int
    ) {
        guard depth < maxDepth else { return }

        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if result == .success, let children = childrenValue as? [AXUIElement] {
            // Check if any child is an overlay (popover, sheet, dialog)
            let overlayRoles: Set<String> = ["AXPopover", "AXSheet", "AXDialog"]
            var overlay: AXUIElement?
            var toolbars: [AXUIElement] = []

            for child in children {
                if let role = getStringAttribute(child, kAXRoleAttribute) {
                    if overlayRoles.contains(role) {
                        overlay = child
                    } else if role == "AXToolbar" {
                        toolbars.append(child)
                    }
                }
            }

            if let overlay = overlay {
                // Overlay present: only walk overlay + toolbars
                collectInteractiveElements(
                    element: overlay, depth: depth + 1, maxDepth: maxDepth,
                    screenBounds: screenBounds, clipRect: clipRect, elements: &elements, nextId: &nextId
                )
                for toolbar in toolbars {
                    collectInteractiveElements(
                        element: toolbar, depth: depth + 1, maxDepth: maxDepth,
                        screenBounds: screenBounds, clipRect: clipRect, elements: &elements, nextId: &nextId
                    )
                }
            } else {
                // No overlay: walk all children normally
                for child in children {
                    collectInteractiveElements(
                        element: child, depth: depth + 1, maxDepth: maxDepth,
                        screenBounds: screenBounds, clipRect: clipRect, elements: &elements, nextId: &nextId
                    )
                }
            }
        }
    }

    // MARK: - Clip Rect Helpers

    /// Intersect two frames, or return the non-nil one if only one is provided.
    private func intersectFrames(_ a: AXFrame?, _ b: AXFrame) -> AXFrame {
        guard let a = a else { return b }
        let x1 = max(a.x, b.x)
        let y1 = max(a.y, b.y)
        let x2 = min(a.x + a.width, b.x + b.width)
        let y2 = min(a.y + a.height, b.y + b.height)
        let w = max(0, x2 - x1)
        let h = max(0, y2 - y1)
        return AXFrame(x: x1, y: y1, width: w, height: h)
    }

    /// Check if an element frame intersects the clip rect. Returns true when clipRect is nil.
    private func frameIntersectsClip(_ frame: AXFrame, clipRect: AXFrame?) -> Bool {
        guard let clip = clipRect else { return true }
        return frame.x + frame.width > clip.x
            && frame.y + frame.height > clip.y
            && frame.x < clip.x + clip.width
            && frame.y < clip.y + clip.height
    }

    // MARK: - Change Detection & Waiting

    /// Create a lightweight snapshot of current a11y state for change detection
    func createSnapshot(target: AXTarget = .front) -> A11ySnapshot {
        let elements = getInteractiveElements(target: target)

        // Check for AXWebArea with children
        var hasWebArea = false
        if case .front = target {
            let trees = (try? getTree(maxDepth: 8, target: target)) ?? []
            hasWebArea = trees.contains { treeHasWebAreaWithChildren($0.tree) }
        }

        return A11ySnapshot(
            elementCount: elements.elements.count,
            windowTitle: getWindowTitle(target: target),
            hasWebAreaWithChildren: hasWebArea,
            timestamp: Date()
        )
    }

    /// Wait for a large change in the a11y tree (navigation)
    /// Returns true if large change detected, false if timeout
    @discardableResult
    func waitForLargeChange(before: A11ySnapshot, timeout: TimeInterval = 5.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let current = createSnapshot()

            if before.hasLargeChangeTo(current) {
                NSLog("✓ Large change detected: \(before.elementCount) → \(current.elementCount) elements")
                return true
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        NSLog("⚠️ No large change detected within \(timeout)s timeout")
        return false
    }

    /// Wait for a11y tree to stabilize (no changes for N consecutive polls)
    func waitForStabilization(polls: Int = 2, interval: TimeInterval = 0.5, timeout: TimeInterval = 5.0) {
        var stableCount = 0
        var prev = createSnapshot()
        let deadline = Date().addingTimeInterval(timeout)

        while stableCount < polls && Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            let current = createSnapshot()

            if current.elementCount == prev.elementCount {
                stableCount += 1
            } else {
                stableCount = 0
                NSLog("🔄 Tree changed: \(prev.elementCount) → \(current.elementCount) elements")
            }

            prev = current
        }

        if stableCount >= polls {
            NSLog("✓ Tree stabilized at \(prev.elementCount) elements")
        } else {
            NSLog("⚠️ Tree did not stabilize within timeout")
        }
    }

    /// Wait for any change in the a11y tree (update)
    /// Returns true if change detected, false if timeout
    @discardableResult
    func waitForAnyChange(before: A11ySnapshot, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let current = createSnapshot()

            if before.hasAnyChangeTo(current) {
                NSLog("✓ Change detected: \(before.elementCount) → \(current.elementCount) elements")
                return true
            }

            Thread.sleep(forTimeInterval: 0.25)
        }

        NSLog("⚠️ No change detected within \(timeout)s timeout (might be ok)")
        return false
    }

    // MARK: - Actions

    /// Perform an AX action on an element found by label or role+title
    func performAction(label: String? = nil, role: String? = nil, action: String = "AXPress", target: AXTarget = .front) throws {
        guard AXIsProcessTrusted() else { throw AXServiceError.permissionDenied }
        guard !target.isMulti else { throw AXServiceError.multiTargetNotAllowed }

        let targets = try resolveTarget(target)
        guard let (pid, _) = targets.first else { throw AXServiceError.noFocusedApp }

        let appElement = AXUIElementCreateApplication(pid)

        var windowValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)

        let searchRoot: AXUIElement = (windowValue as! AXUIElement?) ?? appElement

        var element = findElementFlexible(in: searchRoot, label: label, role: role, depth: 0, maxDepth: 15)

        // If not found in window, also search app-level elements (catches popup menus)
        if element == nil, windowValue != nil {
            element = findElementFlexible(in: appElement, label: label, role: role, depth: 0, maxDepth: 15)
        }

        guard let element = element else {
            throw AXServiceError.elementNotFound(label ?? role ?? "unknown")
        }

        // Move pointer + show overlay at element center before performing action
        if let frame = getFrame(element) {
            let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
                moveEvent.post(tap: .cgSessionEventTap)
            }
            ClickOverlayService.shared.animateClick(at: center)
            usleep(50_000)
        }

        let result = AXUIElementPerformAction(element, action as CFString)
        if result == .success { return }

        // AXPress can return errors like -25205 (cannotComplete) when the action
        // actually succeeded but the element was destroyed (e.g. closing a tab).
        // Check if the element is now invalid — if so, the action worked.
        if action == "AXPress" {
            var roleCheck: CFTypeRef?
            let check = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleCheck)
            if check == .invalidUIElement || check == .cannotComplete {
                return // element gone — action succeeded
            }

            // Element still exists but AXPress failed — fall back to pointer click
            if let frame = getFrame(element) {
                let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
                    moveEvent.post(tap: .cgSessionEventTap)
                }
                ClickOverlayService.shared.animateClick(at: center)
                usleep(50_000) // 50ms for hover state
                if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left),
                   let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left) {
                    down.post(tap: .cgSessionEventTap)
                    up.post(tap: .cgSessionEventTap)
                    return
                }
            }
        }

        throw AXServiceError.actionFailed("\(action) returned \(result.rawValue)")
    }

    /// Set the value of an element found by label/role, or the focused element if no target specified
    func setValue(_ value: String, label: String? = nil, role: String? = nil, target: AXTarget = .front) throws {
        guard AXIsProcessTrusted() else { throw AXServiceError.permissionDenied }
        guard !target.isMulti else { throw AXServiceError.multiTargetNotAllowed }

        let targets = try resolveTarget(target)
        guard let (pid, _) = targets.first else { throw AXServiceError.noFocusedApp }

        let appElement = AXUIElementCreateApplication(pid)

        let element: AXUIElement
        if label != nil || role != nil {
            var windowValue: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
            let searchRoot: AXUIElement = (windowValue as! AXUIElement?) ?? appElement
            var found = findElementFlexible(in: searchRoot, label: label, role: role, depth: 0, maxDepth: 15)
            // If not found in window, also search app-level elements (catches popup menus)
            if found == nil, windowValue != nil {
                found = findElementFlexible(in: appElement, label: label, role: role, depth: 0, maxDepth: 15)
            }
            guard let found = found else {
                throw AXServiceError.elementNotFound(label ?? role ?? "unknown")
            }
            element = found
        } else {
            // Use the focused UI element
            var focusedValue: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
            guard result == .success, let focused = focusedValue else {
                throw AXServiceError.elementNotFound("focused element")
            }
            element = focused as! AXUIElement
        }

        // Focus the element first
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)

        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFTypeRef)
        guard setResult == .success else {
            throw AXServiceError.actionFailed("AXSetValue returned \(setResult.rawValue)")
        }
    }

    /// Trigger a menu item by path. E.g. ["File", "New Window"]
    func triggerMenuItem(path: [String], target: AXTarget = .front) throws {
        guard AXIsProcessTrusted() else { throw AXServiceError.permissionDenied }
        guard !target.isMulti else { throw AXServiceError.multiTargetNotAllowed }
        guard !path.isEmpty else { throw AXServiceError.menuNotFound("empty path") }

        let targets = try resolveTarget(target)
        guard let (pid, _) = targets.first else { throw AXServiceError.noFocusedApp }

        let appElement = AXUIElementCreateApplication(pid)

        // Get the menu bar
        var menuBarValue: CFTypeRef?
        let mbResult = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue)
        guard mbResult == .success, let menuBar = menuBarValue else {
            throw AXServiceError.menuNotFound("menu bar not accessible")
        }

        // Walk the menu path
        var current: AXUIElement = menuBar as! AXUIElement
        for (i, name) in path.enumerated() {
            guard let child = findChildByTitle(in: current, title: name) else {
                let soFar = path[0...i].joined(separator: " > ")
                throw AXServiceError.menuNotFound(soFar)
            }

            if i < path.count - 1 {
                // Open submenu: move pointer to menu item, then press to open
                if let frame = getFrame(child) {
                    let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
                        moveEvent.post(tap: .cgSessionEventTap)
                    }
                    ClickOverlayService.shared.animateClick(at: center)
                    usleep(50_000)
                }
                AXUIElementPerformAction(child, kAXPressAction as CFString)
                usleep(100_000) // 100ms for menu to open

                // Now the submenu children should be available
                // Navigate into the submenu by looking at children
                var submenuValue: CFTypeRef?
                let subResult = AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &submenuValue)
                if subResult == .success, let submenus = submenuValue as? [AXUIElement], let submenu = submenus.first {
                    current = submenu
                } else {
                    current = child
                }
            } else {
                // Final item — move pointer to it, then press
                if let frame = getFrame(child) {
                    let center = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: center, mouseButton: .left) {
                        moveEvent.post(tap: .cgSessionEventTap)
                    }
                    ClickOverlayService.shared.animateClick(at: center)
                    usleep(50_000)
                }
                let pressResult = AXUIElementPerformAction(child, kAXPressAction as CFString)
                guard pressResult == .success else {
                    throw AXServiceError.actionFailed("AXPress on '\(name)' returned \(pressResult.rawValue)")
                }
            }
        }
    }

    /// Get the focused UI element's role, value, and available actions
    func getFocusedElement(target: AXTarget = .front) throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw AXServiceError.permissionDenied }
        guard !target.isMulti else { throw AXServiceError.multiTargetNotAllowed }

        let targets = try resolveTarget(target)
        guard let (pid, _) = targets.first else { throw AXServiceError.noFocusedApp }

        let appElement = AXUIElementCreateApplication(pid)

        var focusedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let focused = focusedValue else {
            // No focused element is a valid state, not an error
            return ["role": "none", "focused": false]
        }

        let element = focused as! AXUIElement
        var info: [String: Any] = [:]
        info["role"] = getStringAttribute(element, kAXRoleAttribute) ?? "unknown"
        info["title"] = getStringAttribute(element, kAXTitleAttribute)
        info["label"] = getStringAttribute(element, kAXDescriptionAttribute)
        info["value"] = getValueString(element)
        info["focused"] = true

        // Get available actions
        var actionsValue: CFArray?
        if AXUIElementCopyActionNames(element, &actionsValue) == .success, let actions = actionsValue as? [String] {
            info["actions"] = actions
        }

        return info
    }

    // MARK: - Flexible element finding

    private func findElementFlexible(in element: AXUIElement, label: String?, role: String?, depth: Int, maxDepth: Int) -> AXUIElement? {
        let elRole = getStringAttribute(element, kAXRoleAttribute)
        let elTitle = getStringAttribute(element, kAXTitleAttribute)
        let elDesc = getStringAttribute(element, kAXDescriptionAttribute)
        let elValue = getValueString(element)
        let elIdentifier = getStringAttribute(element, kAXIdentifierAttribute)

        var matches = true
        if let label = label {
            matches = (elTitle == label || elDesc == label || elValue == label || elIdentifier == label)
        }
        if let role = role, matches {
            matches = (elRole == role)
        }
        if matches && (label != nil || role != nil) {
            return element
        }

        guard depth < maxDepth else { return nil }

        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        if result == .success, let children = childrenValue as? [AXUIElement] {
            for child in children {
                if let found = findElementFlexible(in: child, label: label, role: role, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }

        return nil
    }

    private func findChildByTitle(in element: AXUIElement, title: String) -> AXUIElement? {
        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard result == .success, let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children {
            let childTitle = getStringAttribute(child, kAXTitleAttribute)
            if childTitle == title { return child }
        }
        return nil
    }
}
