import XCTest
import AppKit

// MARK: - Mock PopoverContent

/// Minimal mock that satisfies PopoverContent without real UI.
private class MockContent: NSViewController, PopoverContent {
    let dismissBehavior: PopoverDismissBehavior
    let preferredToolbarAnchor: NSToolbarItem.Identifier

    var enterKeyHandler: (() -> Bool)?
    var escapeKeyHandler: (() -> Bool)?

    init(behavior: PopoverDismissBehavior, anchor: NSToolbarItem.Identifier = NSToolbarItem.Identifier("test")) {
        self.dismissBehavior = behavior
        self.preferredToolbarAnchor = anchor
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { self.view = NSView() }

    func handleEnterKey() -> Bool { enterKeyHandler?() ?? false }
    func handleEscapeKey() -> Bool { escapeKeyHandler?() ?? false }
}

private class MockForm: MockContent {
    init() { super.init(behavior: .requiresExplicitAction) }
    required init?(coder: NSCoder) { fatalError() }
}

private class MockNotification: MockContent {
    init() { super.init(behavior: .transient) }
    required init?(coder: NSCoder) { fatalError() }
}

/// Second form type for cross-type tests.
private class MockFormB: MockContent {
    init() { super.init(behavior: .requiresExplicitAction) }
    required init?(coder: NSCoder) { fatalError() }
}

/// Second notification type.
private class MockNotificationB: MockContent {
    init() { super.init(behavior: .semiTransient) }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Test Helpers

/// Creates a PopoverManager with a stubbed anchor resolver.
private func makeManager() -> PopoverManager {
    let pm = PopoverManager()
    let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(anchor)
    pm.anchorViewResolver = { _ in anchor }
    return pm
}

// MARK: - Tests

final class PopoverManagerTests: XCTestCase {

    // MARK: - Basic show/dismiss

    func testShowSingleForm_isPresented() {
        let pm = makeManager()
        let form = MockForm()
        pm.show(form)
        XCTAssertTrue(pm.hasActive)
        XCTAssertTrue(form === pm.topContent as AnyObject)
    }

    func testDismissPresented_goesIdle() {
        let pm = makeManager()
        let form = MockForm()
        pm.show(form)
        pm.dismissPresented()
        XCTAssertFalse(pm.hasActive)
        XCTAssertNil(pm.topContent)
    }

    func testDismissByContent() {
        let pm = makeManager()
        let form = MockForm()
        pm.show(form)
        pm.dismiss(form)
        XCTAssertFalse(pm.hasActive)
    }

    // MARK: - Form blocks EVERYTHING

    func testFormBlocks_differentFormTypeQueues() {
        let pm = makeManager()
        let form1 = MockForm()
        let form2 = MockFormB()
        pm.show(form1)
        pm.show(form2)
        XCTAssertTrue(form1 === pm.topContent as AnyObject, "form1 stays presented")
        XCTAssertTrue(pm.contains(form2), "form2 is queued")
    }

    func testFormBlocks_notificationQueues() {
        let pm = makeManager()
        let form = MockForm()
        let notif = MockNotification()
        pm.show(form)
        pm.show(notif)
        XCTAssertTrue(form === pm.topContent as AnyObject, "form stays presented")
        XCTAssertTrue(pm.contains(notif), "notification is queued")
    }

    /// Same form type presented → new instance queues behind it.
    /// Forms block but multiple instances of the same type can coexist
    /// (e.g. per-URL permission prompts).
    func testFormBlocks_sameFormType_queues() {
        let pm = makeManager()
        let form1 = MockForm()
        var form1OnCloseCalled = false
        var contentDismissedCalled = false
        pm.onContentDismissed = { _ in contentDismissedCalled = true }

        pm.show(form1) { form1OnCloseCalled = true }

        let form2 = MockForm() // same type, different instance
        pm.show(form2)

        // form1 stays presented, form2 is queued.
        XCTAssertTrue(form1 === pm.topContent as AnyObject, "original form must stay presented")
        XCTAssertTrue(pm.contains(form2), "same-type form must be queued")
        XCTAssertFalse(form1OnCloseCalled, "no callbacks for the presented form")
        XCTAssertFalse(contentDismissedCalled, "no dismissal callbacks at all")
    }

    // MARK: - Notification yields to form

    func testNotificationDismissed_whenFormArrives() {
        let pm = makeManager()
        let notif = MockNotification()
        let form = MockForm()
        var notifOnCloseCalled = false

        pm.show(notif) { notifOnCloseCalled = true }
        pm.show(form)

        XCTAssertTrue(form === pm.topContent as AnyObject)
        XCTAssertTrue(notifOnCloseCalled, "notification onClose fires when bumped by form")
        XCTAssertFalse(pm.contains(notif))
    }

    // MARK: - Notification replaces notification (different types)

    func testNotificationReplaces_differentNotificationType() {
        let pm = makeManager()
        let notif1 = MockNotification()
        let notif2 = MockNotificationB()
        var notif1OnCloseCalled = false

        pm.show(notif1) { notif1OnCloseCalled = true }
        pm.show(notif2)

        XCTAssertTrue(notif2 === pm.topContent as AnyObject)
        XCTAssertTrue(notif1OnCloseCalled, "old notification fires onClose when replaced")
        XCTAssertFalse(pm.contains(notif1))
    }

    // MARK: - Same notification type: replacement fires callbacks

    func testSameNotificationType_replacementFiresCallbacks() {
        let pm = makeManager()
        let notif1 = MockNotification()
        var notif1Closed = false
        var dismissedContent: (any PopoverContent)?
        pm.onContentDismissed = { dismissedContent = $0 }

        pm.show(notif1) { notif1Closed = true }

        let notif2 = MockNotification()
        pm.show(notif2)

        XCTAssertTrue(notif2 === pm.topContent as AnyObject, "new notification is presented")
        XCTAssertTrue(notif1Closed, "replaced notification must fire onClose")
        XCTAssertTrue(dismissedContent === notif1, "replaced notification must fire onContentDismissed")
    }

    // MARK: - Queue dedup fires callbacks

    func testQueueDedup_sameType_firesCallbacks() {
        let pm = makeManager()
        let formA = MockForm()
        let notif1 = MockNotification()
        var notif1OnCloseCalled = false
        var dismissedContent: (any PopoverContent)?
        pm.onContentDismissed = { dismissedContent = $0 }

        pm.show(formA)
        pm.show(notif1) { notif1OnCloseCalled = true } // queued behind form

        let notif2 = MockNotification() // same type as notif1
        pm.show(notif2)

        XCTAssertTrue(notif1OnCloseCalled, "queue dedup must fire onClose")
        XCTAssertTrue(dismissedContent === notif1, "queue dedup must fire onContentDismissed")
        XCTAssertFalse(pm.contains(notif1), "old notif removed from queue")
        XCTAssertTrue(pm.contains(notif2), "new notif is in queue")
    }

    // MARK: - Queue promotion

    func testDismissPresented_promotesNextFromQueue() {
        let pm = makeManager()
        let form = MockForm()
        let notif = MockNotification()

        pm.show(form)
        pm.show(notif) // queued

        pm.dismissPresented()

        XCTAssertTrue(notif === pm.topContent as AnyObject)
    }

    func testQueue_formsPrioritized_overNotifications() {
        let pm = makeManager()
        let formA = MockForm()
        let notif = MockNotification()
        let formB = MockFormB()

        pm.show(formA)
        pm.show(notif)  // queued
        pm.show(formB)  // queued

        pm.dismissPresented() // dismiss formA

        XCTAssertTrue(formB === pm.topContent as AnyObject, "forms have priority in queue")
    }

    // MARK: - Keyboard routing targets presented only

    func testKeyboardRoutes_toPresented_notQueued() {
        let pm = makeManager()
        let form1 = MockForm()
        let form2 = MockFormB()
        var form1EnterCalled = false
        var form2EnterCalled = false

        form1.enterKeyHandler = { form1EnterCalled = true; return true }
        form2.enterKeyHandler = { form2EnterCalled = true; return true }

        pm.show(form1)
        pm.show(form2) // queued behind form1

        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                     timestamp: 0, windowNumber: 0, context: nil,
                                     characters: "\r", charactersIgnoringModifiers: "\r",
                                     isARepeat: false, keyCode: 36)!
        let handled = pm.handleKeyEvent(event)

        XCTAssertTrue(handled)
        XCTAssertTrue(form1EnterCalled, "Enter routes to presented form")
        XCTAssertFalse(form2EnterCalled, "Enter must NOT route to queued form")
    }

    // MARK: - onActiveStateChanged

    func testActiveStateChanged_firesCorrectly() {
        let pm = makeManager()
        var activeStates: [Bool] = []
        pm.onActiveStateChanged = { activeStates.append($0) }

        let form = MockForm()
        pm.show(form)
        pm.dismissPresented()

        XCTAssertEqual(activeStates, [true, false])
    }

    func testActiveStateChanged_notFalse_whileQueueNonEmpty() {
        let pm = makeManager()
        var activeStates: [Bool] = []
        pm.onActiveStateChanged = { activeStates.append($0) }

        let form1 = MockForm()
        let form2 = MockFormB()

        pm.show(form1)
        pm.show(form2) // queued

        pm.dismissPresented() // form1 dismissed, form2 promoted
        XCTAssertEqual(activeStates, [true], "should not fire false while queue has items")

        pm.dismissPresented() // form2 dismissed, now empty
        XCTAssertEqual(activeStates, [true, false])
    }

    // MARK: - onClose/onContentDismissed on real dismiss

    func testOnClose_fires_onRealDismiss() {
        let pm = makeManager()
        let form = MockForm()
        var onCloseCalled = false
        pm.show(form) { onCloseCalled = true }
        pm.dismissPresented()
        XCTAssertTrue(onCloseCalled)
    }

    func testOnContentDismissed_fires_onRealDismiss() {
        let pm = makeManager()
        let form = MockForm()
        var dismissedContent: (any PopoverContent)?
        pm.onContentDismissed = { dismissedContent = $0 }
        pm.show(form)
        pm.dismissPresented()
        XCTAssertTrue(dismissedContent === form)
    }

    // MARK: - dismissAll

    func testDismissAll_clearsEverything() {
        let pm = makeManager()
        let form = MockForm()
        let notif = MockNotification()
        pm.show(form)
        pm.show(notif) // queued

        var dismissedCount = 0
        pm.onContentDismissed = { _ in dismissedCount += 1 }

        pm.dismissAll()

        XCTAssertFalse(pm.hasActive)
        XCTAssertEqual(dismissedCount, 2)
    }

    // MARK: - contains

    func testContains_byInstance() {
        let pm = makeManager()
        let form = MockForm()
        let other = MockFormB()
        pm.show(form)
        XCTAssertTrue(pm.contains(form))
        XCTAssertFalse(pm.contains(other))
    }

    func testContains_byType() {
        let pm = makeManager()
        let form = MockForm()
        pm.show(form)
        XCTAssertTrue(pm.contains(ofType: MockForm.self))
        XCTAssertFalse(pm.contains(ofType: MockNotification.self))
    }

    func testContains_checksQueue() {
        let pm = makeManager()
        let form = MockForm()
        let notif = MockNotification()
        pm.show(form)
        pm.show(notif) // queued
        XCTAssertTrue(pm.contains(notif))
        XCTAssertTrue(pm.contains(ofType: MockNotification.self))
    }

    // MARK: - Dismiss queued item by content

    func testDismiss_queuedItem_byContent() {
        let pm = makeManager()
        let form = MockForm()
        let notif = MockNotification()
        var notifOnCloseCalled = false

        pm.show(form)
        pm.show(notif) { notifOnCloseCalled = true }

        pm.dismiss(notif)

        XCTAssertTrue(notifOnCloseCalled, "onClose fires for explicit dismiss of queued item")
        XCTAssertFalse(pm.contains(notif))
        XCTAssertTrue(form === pm.topContent as AnyObject, "presented unaffected")
    }

    // MARK: - THE regression scenarios

    /// Scenario: `open http://google.com && open http://apple.com`
    /// URL form is showing (google). Second URL event fires (apple).
    /// The first form stays presented. The second queues behind it.
    func testSameFormType_presented_secondQueues() {
        let pm = makeManager()
        let urlForm1 = MockForm()
        pm.show(urlForm1)

        let urlForm2 = MockForm()
        pm.show(urlForm2)

        XCTAssertTrue(urlForm1 === pm.topContent as AnyObject,
                       "first URL form must remain presented")
        XCTAssertTrue(pm.contains(urlForm2),
                       "second URL form must be queued behind the first")
    }

    /// URL form showing, clipboard form queued. Second URL event fires.
    /// URL form stays. Clipboard stays queued. New URL form also queues.
    func testSameFormType_queuesAlongside() {
        let pm = makeManager()
        let urlForm1 = MockForm()
        let clipForm = MockFormB()

        pm.show(urlForm1)
        pm.show(clipForm) // queued

        let urlForm2 = MockForm()
        pm.show(urlForm2)

        XCTAssertTrue(urlForm1 === pm.topContent as AnyObject,
                       "original URL form stays presented")
        XCTAssertTrue(pm.contains(clipForm),
                       "clipboard stays queued")
        XCTAssertTrue(pm.contains(urlForm2),
                       "second URL form is queued")
    }

    /// Port forward notification showing, then port forward permission form arrives.
    /// Notification gets dismissed, form presents.
    func testNotificationYieldsToForm_differentType() {
        let pm = makeManager()
        let notif = MockNotification()
        let form = MockForm()
        var notifClosed = false

        pm.show(notif) { notifClosed = true }
        pm.show(form)

        XCTAssertTrue(form === pm.topContent as AnyObject, "form is presented")
        XCTAssertTrue(notifClosed, "notification dismissed with callback")
    }

    /// Two rapid port forward notifications (same type).
    /// Second replaces first — callbacks fire, no blank popover.
    func testSameNotificationType_noBlankPopover() {
        let pm = makeManager()
        let n1 = MockNotification()
        let n2 = MockNotification()
        var n1Closed = false

        pm.show(n1) { n1Closed = true }
        pm.show(n2)

        XCTAssertTrue(n2 === pm.topContent as AnyObject)
        XCTAssertTrue(n1Closed, "callbacks fire when notification replaced by same type")
        XCTAssertFalse(pm.contains(n1))
    }

    /// Per-URL flow: google shows first, user acts, then apple shows.
    func testPerURL_firstDismiss_secondPromotes() {
        let pm = makeManager()
        let google = MockForm()
        let apple = MockForm()

        pm.show(google)
        pm.show(apple) // queued

        XCTAssertTrue(google === pm.topContent as AnyObject, "google presented first")
        XCTAssertTrue(pm.contains(apple), "apple queued")

        pm.dismissPresented() // user acts on google

        XCTAssertTrue(apple === pm.topContent as AnyObject, "apple promoted after google dismissed")

        pm.dismissPresented() // user acts on apple
        XCTAssertFalse(pm.hasActive, "all cleared")
    }

    /// Full flow: form dismissed → queued items promote correctly.
    func testFullFlow_formDismiss_thenQueuePromotes() {
        let pm = makeManager()
        let urlForm = MockForm()
        let clipForm = MockFormB()
        let notif = MockNotification()

        pm.show(urlForm)
        pm.show(notif)     // queued
        pm.show(clipForm)  // queued

        // Dismiss URL form
        pm.dismissPresented()

        // clipForm should promote (forms have priority)
        XCTAssertTrue(clipForm === pm.topContent as AnyObject, "clipboard form promoted")
        XCTAssertTrue(pm.contains(notif), "notification still queued")

        // Dismiss clipboard form
        pm.dismissPresented()

        // notification promotes
        XCTAssertTrue(notif === pm.topContent as AnyObject, "notification promoted")

        // Dismiss notification
        pm.dismissPresented()
        XCTAssertFalse(pm.hasActive, "all cleared")
    }
}
