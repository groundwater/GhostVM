MacOS Coding Guidelines
=======================

This project targets modern macOS and Virtualization workflows. To keep the codebase maintainable and consistent, follow these conventions when adding or changing macOS UI or app logic.

SwiftUI vs. AppKit
------------------

- Prefer **SwiftUI-first** for new views, windows, and flows.
- Reach for AppKit **only when SwiftUI cannot reasonably do the job** (e.g., highly customized window behavior, legacy-only APIs).
- When you must use AppKit:
  - Wrap all AppKit code in a **dedicated adapter file** (e.g., `LegacyWindowHost.swift`).
  - Expose a clean SwiftUI-facing API from that adapter (e.g., a `View` wrapper or a small `ObservableObject`), so the rest of the app remains pure SwiftUI.
  - Keep AppKit types (`NSWindow`, `NSPanel`, `NSViewController`, etc.) out of application-level and domain/model layers.
  - Avoid leaking AppKit references through public SwiftUI view initializers; prefer simple value/configuration parameters.

Example patterns (conceptual, not strict templates):

- A `struct LegacySettingsHost: NSViewControllerRepresentable` that wraps a complex AppKit settings panel, but is used by the rest of the app as a normal SwiftUI `View`.
- A small `final class WindowCoordinator: NSObject, ObservableObject` that configures an `NSWindow`, but is only referenced from one SwiftUI-facing file.

Window & Scene Conventions
--------------------------

- Represent user-visible windows as explicit SwiftUI scenes:
  - Main VM list window (the “home” surface).
  - Settings window (`WindowGroup("Settings", id: "settings")`).
  - Secondary tools (e.g., restore image browser) as separate `WindowGroup`s.
- Use **stable `id` strings** on scenes (`id: "main"`, `"settings"`, `"restoreImages"`) and prefer `openWindow(id:)` in commands/menus.
- Keep individual window contents focused:
  - Main window: navigation and overview (VM list, actions).
  - VM window: the VM surface only (console/screen), minimal chrome.
  - Utility windows (restore images, logs): single responsibility; avoid overloading them with settings or actions from other domains.

Data & State
------------

- Keep **UI state** in small, focused `ObservableObject`s or `@State`/`@StateObject`:
  - Separate app-wide state (e.g., `VMListViewModel`, `IPSWLibrary`) from per-window or per-sheet state.
  - Avoid letting view models depend directly on AppKit; use plain Swift types plus small adapter services.
- Persisted configuration:
  - Use a dedicated store (`VMConfigStore`, `VMLibrary`, IPSW cache helpers) for anything that crosses process boundaries or launches.
  - Keep `UserDefaults` access inside a small layer rather than scattered across views.

Commands & Menus
----------------

- Use SwiftUI `Commands` to define menu structure:
  - `CommandGroup(replacing: .appSettings)` for Settings.
  - `CommandGroup(after: .windowList)` to add Window menu items that open specific windows (e.g., “Virtual Machines”, “Restore Images”).
- Commands should call into view models or window IDs, not directly into low-level AppKit APIs.
- Keep keyboard shortcuts consistent with macOS norms (⌘, for Settings, ⌘N for new items, etc.).

Error Handling & User Feedback
------------------------------

- Convert low-level errors to user-friendly messages before presenting:
  - Avoid surfacing raw `NSError` or `localizedDescription` unless it is clearly actionable.
  - Prefer short titles and slightly longer informative text.
- Surface long-running operations with visible progress where appropriate (e.g., restore image downloads).

File & Naming Conventions
-------------------------

- Group related UI and view-model code:
  - `VMApp.swift` – app shell, app delegate, high-level wiring.
  - `SwiftUIDemoApp.swift` – pure SwiftUI playground app for experiments.
- Keep filenames aligned with the main type inside (e.g., `VMApp.swift` for `VMCTLApp`, `SwiftUIDemoApp.swift` for `GhostVMSwiftUIApp`).
- Use expressive names for view models and helpers (`CreateVMViewModel`, `SettingsViewModel`, `RestoreImageListModel`).

When in Doubt
-------------

- Default to:
  - SwiftUI views and scenes.
  - Thin AppKit adapters in their own files when necessary.
  - Reusing existing patterns from `VMApp.swift`, `vmctl.swift`, and `SwiftUIDemoApp.swift` to keep the user experience coherent.

