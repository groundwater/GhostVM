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
    var preferredToolbarAnchor: NSToolbarItem.Identifier { get }

    /// Return `true` if the key was handled.
    func handleEnterKey() -> Bool
    /// Return `true` if the key was handled.
    func handleEscapeKey() -> Bool
}

// Default implementations
extension PopoverContent {
    func handleEnterKey() -> Bool { false }
    func handleEscapeKey() -> Bool { false }
}

// MARK: - PopoverManager

final class PopoverManager: NSObject, NSPopoverDelegate {

    /// Resolves a toolbar item identifier to its anchor view.
    /// Must be set before calling show(). Crashes if the identifier cannot be resolved.
    var anchorViewResolver: ((NSToolbarItem.Identifier) -> NSView)!

    /// Fires when the manager goes idle→active or active→idle.
    var onActiveStateChanged: ((Bool) -> Void)?

    /// Fires when a specific content VC is dismissed.
    /// The content VC is passed so callers can identify which popover closed.
    var onContentDismissed: ((any PopoverContent) -> Void)?

    // MARK: - State

    private struct StackEntry {
        let content: any PopoverContent
        var popover: NSPopover?
        var onClose: (() -> Void)?
    }

    /// The ONE visible popover (if any).
    private var presented: StackEntry?

    /// Waiting items (FIFO). These have no popover — they wait until presented is dismissed.
    private var queue: [StackEntry] = []

    /// The currently visible content, if any.
    var topContent: (any PopoverContent)? {
        presented?.content
    }

    /// Whether any popover is currently managed (presented or queued).
    var hasActive: Bool { presented != nil || !queue.isEmpty }

    /// Check if a content VC of a specific type is presented or queued.
    func contains<T: PopoverContent>(ofType type: T.Type) -> Bool {
        if presented?.content is T { return true }
        return queue.contains { $0.content is T }
    }

    /// Check if a specific content VC instance is presented or queued.
    func contains(_ content: any PopoverContent) -> Bool {
        if presented?.content === content { return true }
        return queue.contains { $0.content === content }
    }

    // MARK: - Show

    /// Show a popover. All priority logic lives here — callers just call show().
    ///
    /// Rules (in order):
    /// 1. Same instance already presented or queued → no-op.
    /// 2. Same notification type already presented → silently close old, present new.
    /// 3. Form presented → new content queues behind it (FIFO).
    /// 4. Notification presented + anything → dismiss notification (with callbacks), present new.
    /// 5. Nothing presented → present immediately.
    func show(_ content: any PopoverContent, onClose: (() -> Void)? = nil) {
        let wasActive = hasActive

        // --- Rule 1: Same instance already managed → no-op ---
        if contains(content) { return }

        // --- Rule 2: Same notification type presented → silent close ---
        if let p = presented,
           p.content.dismissBehavior != .requiresExplicitAction,
           type(of: p.content) == type(of: content) {
            closePresentation(p)
            presented = nil
            p.onClose?()
            onContentDismissed?(p.content)
        }

        // --- Rule 3: Queue dedup — same notification type replaced ---
        if content.dismissBehavior != .requiresExplicitAction {
            if let idx = queue.firstIndex(where: {
                $0.content.dismissBehavior != .requiresExplicitAction &&
                type(of: $0.content) == type(of: content)
            }) {
                let removed = queue.remove(at: idx)
                removed.onClose?()
                onContentDismissed?(removed.content)
            }
        }

        // --- Rules 4/5/6: Priority logic ---
        if let p = presented {
            if p.content.dismissBehavior == .requiresExplicitAction {
                // Rule 4: Form on top blocks — queue new content.
                queue.append(StackEntry(content: content, onClose: onClose))
                if !wasActive { onActiveStateChanged?(true) }
                return
            }

            // Rule 4: Notification on top — dismiss it (fires callbacks).
            dismissPresentedInternal()
        }

        // Rule 5: Present.
        var entry = StackEntry(content: content, onClose: onClose)
        present(&entry)
        presented = entry

        if !wasActive {
            onActiveStateChanged?(true)
        }
    }

    // MARK: - Dismiss

    /// Dismiss the currently presented popover and present the next queued item.
    func dismissPresented() {
        guard let entry = presented else { return }
        presented = nil
        closePresentation(entry)
        entry.onClose?()
        onContentDismissed?(entry.content)

        presentNextFromQueue()

        if !hasActive {
            onActiveStateChanged?(false)
        }
    }

    /// Dismiss a specific content VC (whether presented or queued).
    func dismiss(_ content: any PopoverContent) {
        if presented?.content === content {
            dismissPresented()
            return
        }

        // Remove from queue
        guard let index = queue.firstIndex(where: { $0.content === content }) else { return }
        let entry = queue.remove(at: index)
        entry.onClose?()
        onContentDismissed?(entry.content)

        if !hasActive {
            onActiveStateChanged?(false)
        }
    }

    /// Dismiss all — presented and queued.
    func dismissAll() {
        let wasActive = hasActive

        if let entry = presented {
            presented = nil
            closePresentation(entry)
            entry.onClose?()
            onContentDismissed?(entry.content)
        }

        let queueCopy = queue
        queue.removeAll()
        for entry in queueCopy {
            entry.onClose?()
            onContentDismissed?(entry.content)
        }

        if wasActive {
            onActiveStateChanged?(false)
        }
    }

    // MARK: - Keyboard Routing

    /// Routes a keyDown event to the presented content.
    /// Returns `true` if the event was consumed.
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let top = presented?.content else { return false }

        switch event.keyCode {
        case 36, 76:  // Return, Numpad Enter
            if top.handleEnterKey() { return true }
        case 53:      // Escape
            if top.handleEscapeKey() { return true }
        default:
            break
        }

        // Any unhandled input dismisses forms
        if top.dismissBehavior == .requiresExplicitAction {
            dismissPresented()
            return true
        }

        return false
    }

    /// Dismisses the presented popover when the user clicks outside it (e.g. into the VM view).
    /// Clicks inside the popover's own window are ignored.
    func handleMouseEvent(_ event: NSEvent) {
        guard let entry = presented else { return }
        guard entry.content.dismissBehavior == .requiresExplicitAction else { return }

        // Don't dismiss if the click landed inside the popover's window.
        if let popoverWindow = entry.popover?.contentViewController?.view.window,
           event.window === popoverWindow {
            return
        }

        dismissPresented()
    }

    // MARK: - Internal Helpers

    /// Dismiss the presented entry without firing presentNextFromQueue or onActiveStateChanged.
    /// Used by show() when replacing a notification.
    private func dismissPresentedInternal() {
        guard let entry = presented else { return }
        presented = nil
        closePresentation(entry)
        entry.onClose?()
        onContentDismissed?(entry.content)
    }

    /// Present the next item from the queue. Forms have priority over notifications.
    private func presentNextFromQueue() {
        guard !queue.isEmpty else { return }

        // Prefer the first form in the queue
        let index: Int
        if let formIndex = queue.firstIndex(where: { $0.content.dismissBehavior == .requiresExplicitAction }) {
            index = formIndex
        } else {
            index = 0
        }

        var entry = queue.remove(at: index)
        present(&entry)
        presented = entry
    }

    // MARK: - Presentation

    private func present(_ entry: inout StackEntry) {
        let content = entry.content
        let anchorView = anchorViewResolver(content.preferredToolbarAnchor)

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
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        entry.popover = popover
    }

    private func closePresentation(_ entry: StackEntry) {
        if let popover = entry.popover, popover.isShown {
            // Temporarily nil delegate to prevent re-entrancy
            popover.delegate = nil
            popover.close()
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover else { return }

        // Only the presented entry has a popover
        guard let entry = presented, entry.popover === closedPopover else { return }

        presented = nil
        entry.onClose?()
        onContentDismissed?(entry.content)

        presentNextFromQueue()

        if !hasActive {
            onActiveStateChanged?(false)
        }
    }
}
