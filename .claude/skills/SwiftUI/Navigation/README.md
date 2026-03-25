---
name: Navigation
description: Implement macOS window management with Window scenes and WindowGroup. Use when building multi-window apps, opening detail windows, or managing window lifecycle. (project)
---

# Navigation (macOS)

## Window Scenes

```swift
@main
struct GhostVMApp: App {
    var body: some Scene {
        // Single window
        Window("GhostVM", id: "main") {
            VMListView()
        }

        // Window per value (e.g., VM display)
        WindowGroup("VM", id: "vm", for: String.self) { $bundlePath in
            if let path = bundlePath {
                VMDisplayView(bundlePath: path)
            }
        }

        // Settings window
        Settings {
            SettingsView()
        }
    }
}
```

## Opening Windows

```swift
@Environment(\.openWindow) private var openWindow

// Open by ID
openWindow(id: "settings")

// Open with value
openWindow(id: "vm", value: vm.bundlePath)
```

## Dismissing Windows

```swift
@Environment(\.dismiss) private var dismiss

Button("Close") {
    dismiss()
}
```

## Window Modifiers

```swift
Window("Main", id: "main") {
    ContentView()
}
.defaultSize(width: 800, height: 600)
.windowResizability(.contentSize)
.windowStyle(.hiddenTitleBar)
```

## Sheet vs Window

| Use | When |
|-----|------|
| `Window`/`WindowGroup` | Independent content, can be backgrounded |
| `.sheet` | Modal task attached to parent window |
| `.popover` | Contextual UI anchored to element |
| `.alert`/`.confirmationDialog` | Simple choices |

## Don't

- Use `NavigationStack` for top-level app structure (use Window scenes)
- Create windows imperatively with AppKit unless necessary
- Forget stable `id` strings for windows
