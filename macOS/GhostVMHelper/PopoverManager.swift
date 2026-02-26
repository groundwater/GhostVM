import AppKit

// MARK: - Dismiss Behavior

enum PopoverDismissBehavior {
    /// No auto-dismiss; consumes all keys (for permission prompts).
    case requiresExplicitAction
    /// Dismiss on outside click.
    case transient
    /// Dismiss on click outside app.
    case semiTransient
}

// MARK: - PopoverContent Protocol

protocol PopoverContent: NSViewController {
    var dismissBehavior: PopoverDismissBehavior { get }
    var preferredToolbarAnchor: NSToolbarItem.Identifier? { get }

    /// Return `true` if the key was handled.
    func handleEnterKey() -> Bool
    /// Return `true` if the key was handled.
    func handleEscapeKey() -> Bool

    /// Called when this content is pushed down by a newer popover.
    func willSuspend()
    /// Called when this content is restored as the topmost popover.
    func willResume()
}

// Default implementations
extension PopoverContent {
    func handleEnterKey() -> Bool { false }
    func handleEscapeKey() -> Bool { false }
    func willSuspend() {}
    func willResume() {}
}

// MARK: - PopoverManager

final class PopoverManager: NSObject, NSPopoverDelegate {

    /// Resolves a toolbar item identifier to its anchor view (if visible).
    var anchorViewResolver: ((NSToolbarItem.Identifier) -> NSView?)?

    /// The window to use for fallback NSPanel presentation.
    weak var window: NSWindow?

    /// Fires when the stack goes empty→non-empty or non-empty→empty.
    var onActiveStateChanged: ((Bool) -> Void)?

    /// Fires when a specific content VC is dismissed.
    /// The content VC is passed so callers can identify which popover closed.
    var onContentDismissed: ((any PopoverContent) -> Void)?

    // MARK: - Stack

    private struct StackEntry {
        let content: any PopoverContent
        var popover: NSPopover?
        var panel: NSPanel?
        var onClose: (() -> Void)?
    }

    private var stack: [StackEntry] = []

    /// The topmost (currently visible) content, if any.
    var topContent: (any PopoverContent)? {
        stack.last?.content
    }

    /// Whether any popover is currently managed.
    var hasActive: Bool { !stack.isEmpty }

    /// Check if a specific content VC is anywhere in the stack.
    func contains(_ content: any PopoverContent) -> Bool {
        stack.contains { $0.content === content }
    }

    /// Check if a content VC of a specific type is anywhere in the stack.
    func contains<T: PopoverContent>(ofType type: T.Type) -> Bool {
        stack.contains { $0.content is T }
    }

    // MARK: - Show

    func show(_ content: any PopoverContent, onClose: (() -> Void)? = nil) {
        // If this content is already showing, don't re-push
        if contains(content) { return }

        let wasEmpty = stack.isEmpty

        // Suspend current top
        if let currentTop = stack.last {
            currentTop.content.willSuspend()
            // Close its presentation without triggering stack side-effects
            closePresentation(at: stack.count - 1, notifyDelegate: false)
        }

        // Create new entry and push
        var entry = StackEntry(content: content, onClose: onClose)
        present(&entry)
        stack.append(entry)

        if wasEmpty {
            onActiveStateChanged?(true)
        }
    }

    // MARK: - Dismiss

    func dismissTop() {
        guard !stack.isEmpty else { return }
        let entry = stack.removeLast()
        closePresentation(entry)
        entry.onClose?()
        onContentDismissed?(entry.content)

        // Restore previous
        if var newTop = stack.last {
            newTop.content.willResume()
            present(&newTop)
            stack[stack.count - 1] = newTop
        }

        if stack.isEmpty {
            onActiveStateChanged?(false)
        }
    }

    func dismiss(_ content: any PopoverContent) {
        guard let index = stack.firstIndex(where: { $0.content === content }) else { return }

        let isTop = (index == stack.count - 1)
        let entry = stack.remove(at: index)
        closePresentation(entry)
        entry.onClose?()
        onContentDismissed?(entry.content)

        // If we removed the top, restore previous
        if isTop, var newTop = stack.last {
            newTop.content.willResume()
            present(&newTop)
            stack[stack.count - 1] = newTop
        }

        if stack.isEmpty {
            onActiveStateChanged?(false)
        }
    }

    func dismissAll() {
        let entries = stack
        stack.removeAll()
        for entry in entries {
            closePresentation(entry)
            entry.onClose?()
            onContentDismissed?(entry.content)
        }
        if !entries.isEmpty {
            onActiveStateChanged?(false)
        }
    }

    // MARK: - Keyboard Routing

    /// Routes a keyDown event to the topmost content.
    /// Returns `true` if the event was consumed.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let top = stack.last?.content else { return false }

        switch event.keyCode {
        case 36, 76:  // Return, Numpad Enter
            if top.handleEnterKey() { return true }
        case 53:      // Escape
            if top.handleEscapeKey() { return true }
        default:
            break
        }

        // For requiresExplicitAction, consume all keys
        if top.dismissBehavior == .requiresExplicitAction {
            return true
        }

        return false
    }

    // MARK: - Presentation

    private func present(_ entry: inout StackEntry) {
        let content = entry.content

        // Try to resolve anchor view
        if let anchorID = content.preferredToolbarAnchor,
           let resolver = anchorViewResolver,
           let anchorView = resolver(anchorID),
           anchorView.window != nil {
            // Show as NSPopover
            let popover = NSPopover()
            switch content.dismissBehavior {
            case .requiresExplicitAction:
                popover.behavior = .applicationDefined
            case .transient:
                popover.behavior = .transient
            case .semiTransient:
                popover.behavior = .semitransient
            }
            popover.delegate = self
            popover.contentViewController = content
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
            entry.popover = popover
        } else if let window = self.window {
            // Fallback: show as floating NSPanel
            let panel = NSPanel(contentViewController: content)
            panel.styleMask = [.titled, .closable, .nonactivatingPanel]
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.isMovableByWindowBackground = true

            // Add vibrancy background
            if let contentView = panel.contentView {
                let effect = NSVisualEffectView(frame: contentView.bounds)
                effect.material = .popover
                effect.blendingMode = .behindWindow
                effect.state = .active
                effect.autoresizingMask = [.width, .height]
                contentView.addSubview(effect, positioned: .below, relativeTo: nil)
            }

            // Center on window
            panel.setContentSize(content.view.fittingSize)
            let windowFrame = window.frame
            let panelSize = panel.frame.size
            let origin = NSPoint(
                x: windowFrame.midX - panelSize.width / 2,
                y: windowFrame.midY - panelSize.height / 2
            )
            panel.setFrameOrigin(origin)
            panel.makeKeyAndOrderFront(nil)
            entry.panel = panel
        }
    }

    private func closePresentation(_ entry: StackEntry) {
        if let popover = entry.popover, popover.isShown {
            // Temporarily nil delegate to prevent re-entrancy
            popover.delegate = nil
            popover.close()
        }
        if let panel = entry.panel {
            panel.close()
        }
    }

    private func closePresentation(at index: Int, notifyDelegate: Bool) {
        guard index < stack.count else { return }
        let entry = stack[index]
        if let popover = entry.popover, popover.isShown {
            if !notifyDelegate { popover.delegate = nil }
            popover.close()
        }
        if let panel = entry.panel {
            panel.close()
        }
        stack[index].popover = nil
        stack[index].panel = nil
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover else { return }

        // Find which stack entry this popover belongs to
        guard let index = stack.firstIndex(where: { $0.popover === closedPopover }) else { return }

        let isTop = (index == stack.count - 1)
        let entry = stack.remove(at: index)
        entry.onClose?()
        onContentDismissed?(entry.content)

        // If the top was dismissed (e.g. by clicking outside for transient), restore previous
        if isTop, var newTop = stack.last {
            newTop.content.willResume()
            present(&newTop)
            stack[stack.count - 1] = newTop
        }

        if stack.isEmpty {
            onActiveStateChanged?(false)
        }
    }
}
