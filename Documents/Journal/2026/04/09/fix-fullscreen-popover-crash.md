# Fix Full Screen Popover Crash

Date: 2026-04-09
Agents: Claude Opus 4.6
Scope: HelperToolbar.swift, PopoverManager.swift — fix crash when showing popover with toolbar hidden

## Intent

Investigate and fix GitHub issue #176: VM crashes when copying in full screen mode.

## Actions

- Traced crash from `NSWindow.didBecomeKeyNotification` through `handleClipboardOnFocus()` to `anchorView(for:)` fatalError
- Root cause: `windowWillEnterFullScreen` sets `toolbar.isVisible = false`, which removes toolbar views from the window hierarchy (`view.window` becomes nil). When the clipboard handler tries to show a popover, no anchor view can be found.
- Changed `HelperToolbar.anchorView(for:)` return type from `NSView` to `NSView?`, replacing `fatalError` with `return nil`
- Updated `PopoverManager.present()` to guard on nil anchor and skip presentation
- Updated `PopoverManager.anchorViewResolver` type signature to match

## Verification

- `make -C GhostVM debug` — build succeeded
- Manual test: enter full screen, copy text in another app, switch back to VM — should not crash

## Outcome

PR opened: groundwater/GhostVM#177. Awaiting manual verification and review.

## Next Questions

- Should the popover be queued and shown after exiting full screen, rather than silently dropped?
