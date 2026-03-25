---
name: SwiftUI
description: Index of SwiftUI skills. Use to find skills about views, navigation, drag-and-drop, app lifecycle, and window management. (project)
---

# SwiftUI Skills

Skills for SwiftUI development on macOS.

## Skills in This Group

| Skill | When to Use |
|-------|-------------|
| **SwiftUI** | MVVM architecture, @Observable, views, state management |
| **Navigation** | Window scenes, WindowGroup, programmatic window management |
| **Draggable** | Drag and drop, list reordering, Transferable protocol |
| **AppLifecycle** | Scene phases, NSApplicationDelegate, app termination |
| **DeepLinking** | URL schemes, onOpenURL, file associations |

## macOS-Specific Patterns

### Window Scenes
```swift
@main
struct MyApp: App {
    var body: some Scene {
        Window("Main", id: "main") {
            ContentView()
        }

        WindowGroup("Detail", id: "detail", for: UUID.self) { $id in
            DetailView(id: id)
        }

        Settings {
            SettingsView()
        }
    }
}
```

### Opening Windows
```swift
@Environment(\.openWindow) private var openWindow

Button("Open Detail") {
    openWindow(id: "detail", value: item.id)
}
```

### AppKit Isolation
All AppKit code belongs in dedicated `*Adapter.swift` files:
- `FinderAdapter` - Reveal in Finder, file operations
- `SavePanelAdapter` - NSSavePanel for file creation
- `AppIconAdapter` - Dynamic app icon switching

## Quick Reference

- **Building views**: See SwiftUI skill
- **Window management**: See Navigation skill
- **Reorderable lists**: See Draggable skill
- **URL handling**: See DeepLinking skill
- **Background/foreground**: See AppLifecycle skill
